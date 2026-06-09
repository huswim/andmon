import Foundation

enum MessageType: UInt8, Sendable {
    case hello = 1
    case config = 2
    case codecConfig = 3
    case video = 4
    case ping = 5
    case pong = 6
    case stop = 7
    case error = 8
    case keyframeRequest = 9
    case audio = 10
    case touch = 11
}

struct WireFrame: Equatable, Sendable {
    static let headerSize = 24
    static let maximumPayloadSize = 8 * 1024 * 1024

    let type: MessageType
    var flags: UInt16 = 0
    var sequence: UInt32 = 0
    var ptsMicros: UInt64 = 0
    var payload = Data()

    func encoded() throws -> Data {
        guard payload.count <= Self.maximumPayloadSize else {
            throw ProtocolError.payloadTooLarge(payload.count)
        }
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(contentsOf: "ANDM".utf8)
        data.append(1)
        data.append(type.rawValue)
        data.appendBigEndian(flags)
        data.appendBigEndian(UInt32(payload.count))
        data.appendBigEndian(sequence)
        data.appendBigEndian(ptsMicros)
        data.append(payload)
        return data
    }

    static func encodeWithAVCCtoAnnexB(
        type: MessageType,
        flags: UInt16,
        sequence: UInt32,
        ptsMicros: UInt64,
        avccData: Data,
        nalLengthSize: Int = 4
    ) throws -> Data {
        guard (1...4).contains(nalLengthSize) else { throw AVCCError.malformedAccessUnit }
        guard avccData.count <= Self.maximumPayloadSize else {
            throw ProtocolError.payloadTooLarge(avccData.count)
        }
        var data = Data(capacity: Self.headerSize + avccData.count)
        data.append(contentsOf: "ANDM".utf8)
        data.append(1)
        data.append(type.rawValue)
        data.appendBigEndian(flags)
        data.appendBigEndian(UInt32(avccData.count))
        data.appendBigEndian(sequence)
        data.appendBigEndian(ptsMicros)

        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        var offset = 0
        while offset < avccData.count {
            guard offset + nalLengthSize <= avccData.count else { throw AVCCError.malformedAccessUnit }
            var length = 0
            for byte in avccData[offset..<(offset + nalLengthSize)] {
                length = (length << 8) | Int(byte)
            }
            offset += nalLengthSize
            guard length > 0, offset + length <= avccData.count else { throw AVCCError.malformedAccessUnit }
            data.append(startCode)
            data.append(avccData[offset..<(offset + length)])
            offset += length
        }
        return data
    }
}

enum ProtocolError: Error, Equatable, CustomStringConvertible {
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unknownType(UInt8)
    case payloadTooLarge(Int)

    var description: String {
        switch self {
        case .invalidMagic: "Invalid frame magic"
        case .unsupportedVersion(let version): "Unsupported protocol version: \(version)"
        case .unknownType(let type): "Unknown message type: \(type)"
        case .payloadTooLarge(let size): "Payload exceeds 8 MiB: \(size)"
        }
    }
}

struct FrameParser {
    private var pending = Data()

    mutating func append(_ input: Data) throws -> [WireFrame] {
        pending.append(input)
        var frames: [WireFrame] = []
        var cursor = pending.startIndex
        while pending.distance(from: cursor, to: pending.endIndex) >= WireFrame.headerSize {
            let headerEnd = pending.index(cursor, offsetBy: WireFrame.headerSize)
            let header = pending[cursor..<headerEnd]
            guard header.prefix(4) == Data("ANDM".utf8) else { throw ProtocolError.invalidMagic }
            let version = header[header.startIndex + 4]
            guard version == 1 else { throw ProtocolError.unsupportedVersion(version) }
            let rawType = header[header.startIndex + 5]
            guard let type = MessageType(rawValue: rawType) else { throw ProtocolError.unknownType(rawType) }
            let flags: UInt16 = header.readBigEndian(at: 6)
            let payloadLength: UInt32 = header.readBigEndian(at: 8)
            guard payloadLength <= WireFrame.maximumPayloadSize else {
                throw ProtocolError.payloadTooLarge(Int(payloadLength))
            }
            let sequence: UInt32 = header.readBigEndian(at: 12)
            let ptsMicros: UInt64 = header.readBigEndian(at: 16)
            let total = WireFrame.headerSize + Int(payloadLength)
            guard pending.distance(from: cursor, to: pending.endIndex) >= total else { break }
            let payloadStart = pending.index(cursor, offsetBy: WireFrame.headerSize)
            let frameEnd = pending.index(cursor, offsetBy: total)
            frames.append(WireFrame(
                type: type,
                flags: flags,
                sequence: sequence,
                ptsMicros: ptsMicros,
                payload: pending[payloadStart..<frameEnd]
            ))
            cursor = frameEnd
        }
        if cursor > pending.startIndex { pending.removeSubrange(pending.startIndex..<cursor) }
        return frames
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

private extension Data.SubSequence {
    func readBigEndian<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        for byte in self[(startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size)] {
            value = (value << 8) | T(byte)
        }
        return value
    }
}
