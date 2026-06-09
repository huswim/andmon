import Foundation
import VirtualDisplayBridge

final class USBTransport: AndmonTransport, @unchecked Sendable {
    private let writeQueue = DispatchQueue(label: "dev.andmon.usb.writer")
    private let readQueue = DispatchQueue(label: "dev.andmon.usb.reader")
    private let lock = NSCondition()
    private var raw: OpaquePointer?
    private var running = false
    private var inFlightTransfers = 0
    private var sequence: UInt32 = 1
    private var queuedBytes = 0
    private var replacedVideoFrames = 0
    private var pendingWrites: [PendingWrite] = []
    private var writerScheduled = false
    var onFrame: (@Sendable (WireFrame) -> Void)?
    var onDisconnect: (@Sendable (Error) -> Void)?

    var queuedByteCount: Int {
        lock.withLock { queuedBytes }
    }

    func takeReplacedVideoFrameCount() -> Int {
        lock.withLock {
            defer { replacedVideoFrames = 0 }
            return replacedVideoFrames
        }
    }

    func open() throws {
        var error: UnsafeMutableRawPointer?
        guard let raw = AndmonUSBAccessoryOpen(&error) else {
            throw BridgeError.take(error, fallback: "Unable to open Android accessory")
        }
        lock.withLock {
            self.raw = raw
            running = true
        }
        readQueue.async { [weak self] in self?.readLoop() }
    }

    @discardableResult
    func send(
        type: MessageType, flags: UInt16 = 0, ptsMicros: UInt64 = 0, payload: Data = Data()
    ) throws -> TransportSendResult {
        let frame = lock.withLock { () -> WireFrame in
            defer { sequence &+= 1 }
            return WireFrame(type: type, flags: flags, sequence: sequence, ptsMicros: ptsMicros, payload: payload)
        }
        let bytes = try frame.encoded()
        let enqueueResult = lock.withLock { () -> (shouldScheduleWriter: Bool, replacedVideo: Bool) in
            var replacedVideo = false
            if type == .video {
                for index in pendingWrites.indices.reversed() where pendingWrites[index].type == .video {
                    queuedBytes -= pendingWrites[index].bytes.count
                    pendingWrites.remove(at: index)
                    replacedVideoFrames += 1
                    replacedVideo = true
                }
            }
            pendingWrites.append(PendingWrite(type: type, bytes: bytes))
            queuedBytes += bytes.count
            guard !writerScheduled else { return (false, replacedVideo) }
            writerScheduled = true
            return (true, replacedVideo)
        }
        if enqueueResult.shouldScheduleWriter {
            writeQueue.async { [weak self] in self?.writePending() }
        }
        return TransportSendResult(replacedVideo: enqueueResult.replacedVideo)
    }

    @discardableResult
    func sendAVCC(
        type: MessageType, flags: UInt16 = 0, ptsMicros: UInt64 = 0, avccPayload: Data
    ) throws -> TransportSendResult {
        let bytes = try lock.withLock { () -> Data in
            defer { sequence &+= 1 }
            return try WireFrame.encodeWithAVCCtoAnnexB(
                type: type,
                flags: flags,
                sequence: sequence,
                ptsMicros: ptsMicros,
                avccData: avccPayload
            )
        }
        let enqueueResult = lock.withLock { () -> (shouldScheduleWriter: Bool, replacedVideo: Bool) in
            var replacedVideo = false
            if type == .video {
                for index in pendingWrites.indices.reversed() where pendingWrites[index].type == .video {
                    queuedBytes -= pendingWrites[index].bytes.count
                    pendingWrites.remove(at: index)
                    replacedVideoFrames += 1
                    replacedVideo = true
                }
            }
            pendingWrites.append(PendingWrite(type: type, bytes: bytes))
            queuedBytes += bytes.count
            guard !writerScheduled else { return (false, replacedVideo) }
            writerScheduled = true
            return (true, replacedVideo)
        }
        if enqueueResult.shouldScheduleWriter {
            writeQueue.async { [weak self] in self?.writePending() }
        }
        return TransportSendResult(replacedVideo: enqueueResult.replacedVideo)
    }

    func close() {
        lock.lock()
        running = false
        let accessory = raw
        raw = nil
        pendingWrites.removeAll()
        queuedBytes = 0
        while inFlightTransfers > 0 { lock.wait() }
        lock.unlock()
        if let accessory { AndmonUSBAccessoryClose(accessory) }
    }

    private func readLoop() {
        var parser = FrameParser()
        var storage = [UInt8](repeating: 0, count: 64 * 1024)
        while lock.withLock({ running }) {
            var errorPointer: UnsafeMutableRawPointer?
            guard let count = withAccessory({
                AndmonUSBAccessoryRead($0, &storage, storage.count, &errorPointer)
            }) else { return }
            if count < 0 {
                guard lock.withLock({ running }) else { return }
                disconnect(BridgeError.take(errorPointer, fallback: "USB read failed"))
                return
            }
            if count == 0 { continue }
            do {
                for frame in try parser.append(Data(storage[0..<count])) {
                    onFrame?(frame)
                }
            } catch {
                disconnect(error)
                return
            }
        }
    }

    private func write(_ bytes: Data) throws {
        var offset = 0
        while offset < bytes.count {
            var errorPointer: UnsafeMutableRawPointer?
            guard let written = withAccessory({ accessory in
                bytes.withUnsafeBytes { pointer in
                    AndmonUSBAccessoryWrite(
                        accessory, pointer.baseAddress!.advanced(by: offset), bytes.count - offset, &errorPointer
                    )
                }
            }) else { return }
            guard written >= 0 else {
                throw BridgeError.take(errorPointer, fallback: "USB write failed")
            }
            offset += written
        }
    }

    private func writePending() {
        while true {
            let next = lock.withLock { () -> PendingWrite? in
                guard running, !pendingWrites.isEmpty else {
                    writerScheduled = false
                    return nil
                }
                return pendingWrites.removeFirst()
            }
            guard let next else { return }
            do {
                try write(next.bytes)
                lock.withLock { queuedBytes = max(0, queuedBytes - next.bytes.count) }
            } catch {
                disconnect(error)
                return
            }
        }
    }

    private func withAccessory<T>(_ body: (OpaquePointer) -> T) -> T? {
        let accessory = lock.withLock { () -> OpaquePointer? in
            guard running, let raw else { return nil }
            inFlightTransfers += 1
            return raw
        }
        guard let accessory else { return nil }
        defer {
            lock.withLock {
                inFlightTransfers -= 1
                if inFlightTransfers == 0 { lock.broadcast() }
            }
        }
        return body(accessory)
    }

    private func disconnect(_ error: Error) {
        close()
        onDisconnect?(error)
    }
}

private struct PendingWrite {
    let type: MessageType
    let bytes: Data
}
