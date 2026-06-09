import Foundation

protocol AndmonTransport: AnyObject, Sendable {
    var onFrame: (@Sendable (WireFrame) -> Void)? { get set }
    var onDisconnect: (@Sendable (Error) -> Void)? { get set }
    var queuedByteCount: Int { get }
    
    func takeSentByteCount() -> Int
    func takeReplacedVideoFrameCount() -> Int
    func open() throws
    func send(type: MessageType, flags: UInt16, ptsMicros: UInt64, payload: Data) throws -> TransportSendResult
    func sendAVCC(type: MessageType, flags: UInt16, ptsMicros: UInt64, avccPayload: Data) throws -> TransportSendResult
    func close()
}

struct TransportSendResult: Sendable {
    let replacedVideo: Bool
    func acceptedForDecoder(isKeyframe: Bool) -> Bool {
        return !replacedVideo || isKeyframe
    }
}

extension AndmonTransport {
    @discardableResult
    func send(type: MessageType, flags: UInt16 = 0, ptsMicros: UInt64 = 0, payload: Data = Data()) throws -> TransportSendResult {
        return try send(type: type, flags: flags, ptsMicros: ptsMicros, payload: payload)
    }
    
    @discardableResult
    func sendAVCC(type: MessageType, flags: UInt16 = 0, ptsMicros: UInt64 = 0, avccPayload: Data) throws -> TransportSendResult {
        return try sendAVCC(type: type, flags: flags, ptsMicros: ptsMicros, avccPayload: avccPayload)
    }
}
