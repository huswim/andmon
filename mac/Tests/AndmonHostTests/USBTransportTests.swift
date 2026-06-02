import Testing
@testable import AndmonHost

struct USBTransportTests {
    @Test func replacedVideoFrameOnlyNeedsRecoveryWhenNewFrameIsNotKeyframe() {
        let result = USBTransportSendResult(replacedVideo: true)
        #expect(!result.acceptedForDecoder(isKeyframe: false))
        #expect(result.acceptedForDecoder(isKeyframe: true))
    }
}
