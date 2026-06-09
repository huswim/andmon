import Foundation
import Testing
@testable import AndmonHost

struct WireProtocolTests {
    private let encoded = try! WireFrame(
        type: .video, flags: 1, sequence: 7, ptsMicros: 1234, payload: Data([1, 2, 3])
    ).encoded()

    @Test func splitHeader() throws {
        var parser = FrameParser()
        #expect(try parser.append(encoded.prefix(8)).isEmpty)
        let frames = try parser.append(encoded.dropFirst(8))
        #expect(frames.count == 1)
        #expect(frames[0].type == .video)
    }

    @Test func splitPayload() throws {
        var parser = FrameParser()
        #expect(try parser.append(encoded.prefix(25)).isEmpty)
        #expect(try parser.append(encoded.dropFirst(25))[0].payload == Data([1, 2, 3]))
    }

    @Test func multipleFrames() throws {
        var parser = FrameParser()
        #expect(try parser.append(encoded + encoded).count == 2)
    }

    @Test func keyframeRequest() throws {
        var parser = FrameParser()
        let request = try WireFrame(type: .keyframeRequest).encoded()
        #expect(try parser.append(request) == [WireFrame(type: .keyframeRequest)])
    }

    @Test func retainedPartialFrameAfterConsumedFrame() throws {
        var parser = FrameParser()
        #expect(try parser.append(encoded + encoded.prefix(8)).count == 1)
        let frames = try parser.append(encoded.dropFirst(8))
        #expect(frames.count == 1)
        #expect(frames[0].payload == Data([1, 2, 3]))
    }

    @Test func invalidMagic() {
        var parser = FrameParser()
        var invalid = encoded
        invalid[0] = 0
        #expect(throws: ProtocolError.invalidMagic) { try parser.append(invalid) }
    }

    @Test func oversizedPayload() {
        var parser = FrameParser()
        var invalid = encoded
        invalid.replaceSubrange(8..<12, with: [0, 0x80, 0, 1])
        #expect(throws: ProtocolError.payloadTooLarge(8 * 1024 * 1024 + 1)) {
            try parser.append(invalid)
        }
    }

    @Test func invalidVersion() {
        var parser = FrameParser()
        var invalid = encoded
        invalid[4] = 2
        #expect(throws: ProtocolError.unsupportedVersion(2)) { try parser.append(invalid) }
    }

    @Test func touchFrame() throws {
        var parser = FrameParser()
        let payload = Data("{\"action\":0,\"x\":0.5,\"y\":0.75}".utf8)
        let touch = try WireFrame(type: .touch, payload: payload).encoded()
        let frames = try parser.append(touch)
        #expect(frames.count == 1)
        #expect(frames[0].type == .touch)
        #expect(frames[0].payload == payload)
    }

    @Test func scrollFrame() throws {
        var parser = FrameParser()
        let payload = Data("{\"action\":3,\"dx\":10.0,\"dy\":-2.5}".utf8)
        let touch = try WireFrame(type: .touch, payload: payload).encoded()
        let frames = try parser.append(touch)
        #expect(frames.count == 1)
        #expect(frames[0].type == .touch)
        #expect(frames[0].payload == payload)
    }
}
