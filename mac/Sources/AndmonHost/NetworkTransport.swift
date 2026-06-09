import Foundation
import Network

final class NetworkTransport: AndmonTransport, @unchecked Sendable {
    private let tabletIP: String
    private let writeQueue = DispatchQueue(label: "dev.andmon.net.writer")
    private let readQueue = DispatchQueue(label: "dev.andmon.net.reader")
    private let lock = NSLock()
    
    private var tcpConnection: NWConnection?
    private var udpConnection: NWConnection?
    private var running = false
    private var sequence: UInt32 = 1
    private var queuedBytes = 0
    private var replacedVideoFrames = 0
    private var tcpParser = FrameParser()
    
    var onFrame: (@Sendable (WireFrame) -> Void)?
    var onDisconnect: (@Sendable (Error) -> Void)?
    
    var queuedByteCount: Int {
        lock.withLock { queuedBytes }
    }
    
    init(tabletIP: String) {
        self.tabletIP = tabletIP
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
        
        // TCP Connection Setup
        let tcpConn = NWConnection(host: NWEndpoint.Host(tabletIP), port: 8001, using: .tcp)
        self.tcpConnection = tcpConn
        
        tcpConn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            fputs("Network Transport: TCP State changed to \(state)\n", stderr)
            switch state {
            case .ready:
                fputs("Network Transport: TCP Connected to \(self.tabletIP):8001\n", stderr)
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
        
        // UDP Connection Setup
        let udpConn = NWConnection(host: NWEndpoint.Host(tabletIP), port: 8002, using: .udp)
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
        
        if type == .video || type == .audio {
            sendUdp(type: type, sequence: seq, bytes: bytes)
            return TransportSendResult(replacedVideo: false)
        } else {
            try sendTcp(bytes: bytes)
            return TransportSendResult(replacedVideo: false)
        }
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
        
        if type == .video || type == .audio {
            sendUdp(type: type, sequence: seq, bytes: bytes)
            return TransportSendResult(replacedVideo: false)
        } else {
            try sendTcp(bytes: bytes)
            return TransportSendResult(replacedVideo: false)
        }
    }
    
    private func sendTcp(bytes: Data) throws {
        guard let conn = tcpConnection, lock.withLock({ running }) else { return }
        conn.send(content: bytes, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.disconnect(error)
            }
        })
    }
    
    private func sendUdp(type: MessageType, sequence: UInt32, bytes: Data) {
        guard let conn = udpConnection, lock.withLock({ running }) else { return }
        
        let maxPayload = 1400
        if bytes.count <= maxPayload {
            // No fragmentation needed, but we still apply ANDU framing for consistency
            let chunk = makeChunk(frameID: sequence, chunkIndex: 0, totalChunks: 1, payload: bytes)
            conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.disconnect(error)
                }
            })
        } else {
            // Fragment large payloads
            let totalChunks = Int(ceil(Double(bytes.count) / Double(maxPayload)))
            
            writeQueue.async { [weak self] in
                guard let self else { return }
                for i in 0..<totalChunks {
                    guard self.lock.withLock({ self.running }) else { break }
                    let offset = i * maxPayload
                    let length = min(maxPayload, bytes.count - offset)
                    let subdata = bytes.subdata(in: offset..<(offset + length))
                    
                    let chunk = self.makeChunk(frameID: sequence, chunkIndex: UInt16(i), totalChunks: UInt16(totalChunks), payload: subdata)
                    
                    // We send sequentially to avoid EMSGSIZE and UDP congestion issues
                    let semaphore = DispatchSemaphore(value: 0)
                    conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
                        if let error {
                            self?.disconnect(error)
                        }
                        semaphore.signal()
                    })
                    _ = semaphore.wait(timeout: .now() + 0.05) // short delay/safety timeout
                }
            }
        }
    }
    
    private func makeChunk(frameID: UInt32, chunkIndex: UInt16, totalChunks: UInt16, payload: Data) -> Data {
        var data = Data(capacity: 12 + payload.count)
        data.append(contentsOf: "ANDU".utf8)
        
        var bigFrameID = frameID.bigEndian
        withUnsafeBytes(of: &bigFrameID) { data.append(contentsOf: $0) }
        
        var bigIndex = chunkIndex.bigEndian
        withUnsafeBytes(of: &bigIndex) { data.append(contentsOf: $0) }
        
        var bigTotal = totalChunks.bigEndian
        withUnsafeBytes(of: &bigTotal) { data.append(contentsOf: $0) }
        
        data.append(payload)
        return data
    }
    
    func close() {
        lock.withLock {
            guard running else { return }
            running = false
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
