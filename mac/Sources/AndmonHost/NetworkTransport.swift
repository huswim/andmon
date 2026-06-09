import Foundation
import Network

final class NetworkTransport: AndmonTransport, @unchecked Sendable {
    private let tabletIP: String
    private let writeQueue = DispatchQueue(label: "dev.andmon.net.writer")
    private let readQueue = DispatchQueue(label: "dev.andmon.net.reader")
    let lock = NSLock() // accessed internally
    
    private var tcpConnection: NWConnection?
    private var udpConnection: NWConnection?
    private var running = false
    private var sequence: UInt32 = 1
    private var queuedBytes = 0
    private var replacedVideoFrames = 0
    private var sentBytes = 0
    private var tcpParser = FrameParser()
    private var pendingWrites: [PendingWrite] = []
    private var writerScheduled = false
    
    private let fecEncoder = FECEncoder()
    private var tcpTimeoutWork: DispatchWorkItem?
    
    // Configured parameters (updated dynamically by NetworkQualityMonitor or PopoverView)
    var autoOptimizationEnabled: Bool = true
    var fecType: UInt8 = 1
    var fecGroupSize: UInt8 = 5
    var pacingIntervalMicroseconds: UInt32 = 200
    
    var onFrame: (@Sendable (WireFrame) -> Void)?
    var onDisconnect: (@Sendable (Error) -> Void)?
    
    var queuedByteCount: Int {
        lock.withLock { queuedBytes }
    }
    
    init(tabletIP: String) {
        self.tabletIP = tabletIP
    }
    
    func takeSentByteCount() -> Int {
        lock.withLock {
            defer { sentBytes = 0 }
            return sentBytes
        }
    }
    
    func takeReplacedVideoFrameCount() -> Int {
        lock.withLock {
            defer { replacedVideoFrames = 0 }
            return replacedVideoFrames
        }
    }
    
    func open() throws {
        lock.withLock {
            running = true
        }
        
        // TCP Configuration
        let tcpParams = NWParameters.tcp
        if let tcpOptions = tcpParams.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 2
            tcpOptions.keepaliveInterval = 1
            tcpOptions.keepaliveCount = 3
        }
        
        let tcpConn = NWConnection(host: NWEndpoint.Host(tabletIP), port: 8001, using: tcpParams)
        self.tcpConnection = tcpConn
        
        // 5s connection timeout handler
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            var shouldDisconnect = false
            self.lock.withLock {
                if let conn = self.tcpConnection {
                    switch conn.state {
                    case .ready:
                        break
                    default:
                        shouldDisconnect = true
                    }
                }
            }
            if shouldDisconnect {
                fputs("Network Transport: TCP connection timeout after 5s\n", stderr)
                self.disconnect(NSError(domain: "NetworkTransport", code: 1, userInfo: [NSLocalizedDescriptionKey: "TCP Connection timed out after 5 seconds"]))
            }
        }
        lock.withLock {
            self.tcpTimeoutWork = timeoutWork
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0, execute: timeoutWork)
        
        tcpConn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            fputs("Network Transport: TCP State changed to \(state)\n", stderr)
            switch state {
            case .ready:
                fputs("Network Transport: TCP Connected to \(self.tabletIP):8001\n", stderr)
                self.lock.withLock {
                    self.tcpTimeoutWork?.cancel()
                    self.tcpTimeoutWork = nil
                }
                self.startTcpReadLoop()
            case .waiting(let error):
                self.disconnect(error)
            case .failed(let error):
                self.disconnect(error)
            case .cancelled:
                break
            default:
                break
            }
        }
        tcpConn.start(queue: readQueue)
        
        // UDP Configuration
        let udpParams = NWParameters.udp
        udpParams.serviceClass = .responsiveData // Prioritizes low latency & DSCP marking
        
        let udpConn = NWConnection(host: NWEndpoint.Host(tabletIP), port: 8002, using: udpParams)
        self.udpConnection = udpConn
        
        udpConn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            fputs("Network Transport: UDP State changed to \(state)\n", stderr)
            switch state {
            case .ready:
                fputs("Network Transport: UDP Socket Ready to \(self.tabletIP):8002\n", stderr)
            case .failed(let error):
                self.disconnect(error)
            case .cancelled:
                break
            default:
                break
            }
        }
        udpConn.start(queue: readQueue)
    }
    
    private func startTcpReadLoop() {
        readNextTcp()
    }
    
    private func readNextTcp() {
        guard let conn = tcpConnection, lock.withLock({ running }) else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, context, isComplete, error in
            guard let self else { return }
            if let error {
                self.disconnect(error)
                return
            }
            
            if let data = data, !data.isEmpty {
                do {
                    let frames = try self.lock.withLock {
                        try self.tcpParser.append(data)
                    }
                    for frame in frames {
                        self.onFrame?(frame)
                    }
                } catch {
                    self.disconnect(error)
                    return
                }
            }
            
            if isComplete {
                self.disconnect(NSError(domain: "NetworkTransport", code: 0, userInfo: [NSLocalizedDescriptionKey: "TCP Connection closed by remote peer"]))
                return
            }
            
            self.readNextTcp()
        }
    }
    
    func send(type: MessageType, flags: UInt16, ptsMicros: UInt64, payload: Data) throws -> TransportSendResult {
        let seq = lock.withLock { () -> UInt32 in
            defer { sequence &+= 1 }
            return sequence
        }
        let frame = WireFrame(type: type, flags: flags, sequence: seq, ptsMicros: ptsMicros, payload: payload)
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
            pendingWrites.append(PendingWrite(type: type, flags: flags, sequence: seq, bytes: bytes))
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
    
    func sendAVCC(type: MessageType, flags: UInt16, ptsMicros: UInt64, avccPayload: Data) throws -> TransportSendResult {
        let seq = lock.withLock { () -> UInt32 in
            defer { sequence &+= 1 }
            return sequence
        }
        let bytes = try WireFrame.encodeWithAVCCtoAnnexB(
            type: type,
            flags: flags,
            sequence: seq,
            ptsMicros: ptsMicros,
            avccData: avccPayload
        )
        
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
            pendingWrites.append(PendingWrite(type: type, flags: flags, sequence: seq, bytes: bytes))
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
            
            if next.type == .video || next.type == .audio {
                sendUdpSync(type: next.type, sequence: next.sequence, bytes: next.bytes)
            } else {
                sendTcpSync(bytes: next.bytes)
            }
            
            lock.withLock {
                queuedBytes = max(0, queuedBytes - next.bytes.count)
            }
        }
    }
    
    private func sendTcpSync(bytes: Data) {
        guard let conn = tcpConnection, lock.withLock({ running }) else { return }
        conn.send(content: bytes, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.disconnect(error)
            } else {
                self?.lock.withLock { self?.sentBytes += bytes.count }
            }
        })
    }
    
    private func sendUdpSync(type: MessageType, sequence: UInt32, bytes: Data) {
        guard let conn = udpConnection, lock.withLock({ running }) else { return }
        
        let maxPayload = 1400
        var dataChunks: [Data] = []
        
        if bytes.count <= maxPayload {
            dataChunks.append(bytes)
        } else {
            let totalChunks = Int(ceil(Double(bytes.count) / Double(maxPayload)))
            for i in 0..<totalChunks {
                let offset = i * maxPayload
                let length = min(maxPayload, bytes.count - offset)
                dataChunks.append(bytes.subdata(in: offset..<(offset + length)))
            }
        }
        
        let localFecType = lock.withLock { self.fecType }
        let localFecGroupSize = lock.withLock { self.fecGroupSize }
        let pacingInterval = lock.withLock { self.pacingIntervalMicroseconds }
        
        let finalChunks: [Data]
        if localFecType == 1 && localFecGroupSize > 0 {
            finalChunks = fecEncoder.encode(dataChunks: dataChunks, groupSize: Int(localFecGroupSize))
        } else {
            finalChunks = dataChunks
        }
        
        let numData = dataChunks.count
        let totalCount = finalChunks.count
        
        for i in 0..<totalCount {
            guard lock.withLock({ self.running }) else { break }
            let payload = finalChunks[i]
            let isParity = i >= numData
            
            let chunk = makeChunk(
                frameID: sequence,
                chunkIndex: UInt16(i),
                totalChunks: UInt16(totalCount),
                fecType: localFecType,
                fecGroupSize: localFecGroupSize,
                isParity: isParity,
                payload: payload
            )
            
            conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.disconnect(error)
                } else {
                    self?.lock.withLock { self?.sentBytes += chunk.count }
                }
            })
            
            // Pacing every 3 chunks
            if (i + 1) % 3 == 0 || i == totalCount - 1 {
                usleep(pacingInterval)
            }
        }
    }
    
    private func makeChunk(frameID: UInt32, chunkIndex: UInt16, totalChunks: UInt16, fecType: UInt8, fecGroupSize: UInt8, isParity: Bool, payload: Data) -> Data {
        var data = Data(capacity: 16 + payload.count)
        data.append(contentsOf: "ANDU".utf8)
        
        var bigFrameID = frameID.bigEndian
        withUnsafeBytes(of: &bigFrameID) { data.append(contentsOf: $0) }
        
        var bigIndex = chunkIndex.bigEndian
        withUnsafeBytes(of: &bigIndex) { data.append(contentsOf: $0) }
        
        var bigTotal = totalChunks.bigEndian
        withUnsafeBytes(of: &bigTotal) { data.append(contentsOf: $0) }
        
        data.append(fecType)
        data.append(fecGroupSize)
        
        let flags: UInt8 = isParity ? 1 : 0
        data.append(flags)
        
        data.append(0) // reserved alignment padding
        
        data.append(payload)
        return data
    }
    
    func purgePendingVideoFrames() {
        lock.withLock {
            var indicesToRemove: [Int] = []
            for index in pendingWrites.indices {
                let p = pendingWrites[index]
                // Only drop video non-keyframes (P-frames).
                // Audio packets and video keyframes (flags == 1) are preserved.
                if p.type == .video && p.flags == 0 {
                    indicesToRemove.append(index)
                }
            }
            for index in indicesToRemove.reversed() {
                queuedBytes -= pendingWrites[index].bytes.count
                pendingWrites.remove(at: index)
                replacedVideoFrames += 1
            }
        }
    }
    
    func updateAutoOptimization(enabled: Bool) {
        lock.withLock {
            self.autoOptimizationEnabled = enabled
            if !enabled {
                self.fecType = 1
                self.fecGroupSize = 5
                self.pacingIntervalMicroseconds = 200
            }
        }
    }
    
    func updateManualFec(size: Int) {
        lock.withLock {
            self.fecGroupSize = UInt8(size)
            if size == 0 {
                self.fecType = 0
            } else {
                self.fecType = 1
            }
        }
    }
    
    func updatePacingInterval(_ interval: UInt32) {
        lock.withLock {
            self.pacingIntervalMicroseconds = interval
        }
    }
    
    func close() {
        lock.withLock {
            guard running else { return }
            running = false
            pendingWrites.removeAll()
            queuedBytes = 0
            writerScheduled = false
            
            tcpTimeoutWork?.cancel()
            tcpTimeoutWork = nil
        }
        
        tcpConnection?.cancel()
        tcpConnection = nil
        udpConnection?.cancel()
        udpConnection = nil
    }
    
    private func disconnect(_ error: Error) {
        close()
        onDisconnect?(error)
    }
}

private struct PendingWrite {
    let type: MessageType
    let flags: UInt16
    let sequence: UInt32
    let bytes: Data
}
