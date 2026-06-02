import CoreMedia
import Foundation
import Testing
@testable import AndmonHost

struct AVCCConverterTests {
    @Test func convertsMultipleNALUnits() throws {
        let avcc = Data([0, 0, 0, 2, 0x67, 0x01, 0, 0, 0, 3, 0x68, 0x02, 0x03])
        #expect(try AVCCConverter.annexB(fromAVCC: avcc) ==
            Data([0, 0, 0, 1, 0x67, 0x01, 0, 0, 0, 1, 0x68, 0x02, 0x03]))
    }

    @Test func rejectsTruncatedNALUnit() {
        #expect(throws: AVCCError.malformedAccessUnit) {
            try AVCCConverter.annexB(fromAVCC: Data([0, 0, 0, 4, 0x67]))
        }
    }

    @Test func extractsSPSAndPPS() throws {
        let sps: [UInt8] = [0x67, 0x42, 0x00, 0x1f, 0x95, 0xa8, 0x14, 0x01, 0x6e, 0x40]
        let pps: [UInt8] = [0x68, 0xce, 0x06, 0xe2]
        var description: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { spsPointer in
            pps.withUnsafeBufferPointer { ppsPointer in
                let pointers = [spsPointer.baseAddress!, ppsPointer.baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description
                )
            }
        }
        try #require(status == noErr)
        let formatDescription = try #require(description)
        #expect(try AVCCConverter.parameterSets(from: formatDescription) ==
            Data([0, 0, 0, 1] + sps + [0, 0, 0, 1] + pps))
    }
}
