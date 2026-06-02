import CoreMedia
import Foundation

enum AVCCError: Error, Equatable {
    case malformedAccessUnit
    case missingParameterSets
}

enum AVCCConverter {
    private static let startCode = Data([0, 0, 0, 1])

    static func annexB(fromAVCC data: Data, nalLengthSize: Int = 4) throws -> Data {
        guard (1...4).contains(nalLengthSize) else { throw AVCCError.malformedAccessUnit }
        var result = Data(capacity: data.count)
        var offset = 0
        while offset < data.count {
            guard offset + nalLengthSize <= data.count else { throw AVCCError.malformedAccessUnit }
            var length = 0
            for byte in data[offset..<(offset + nalLengthSize)] {
                length = (length << 8) | Int(byte)
            }
            offset += nalLengthSize
            guard length > 0, offset + length <= data.count else { throw AVCCError.malformedAccessUnit }
            result.append(startCode)
            result.append(data[offset..<(offset + length)])
            offset += length
        }
        return result
    }

    static func parameterSets(from format: CMFormatDescription) throws -> Data {
        let codec = CMFormatDescriptionGetMediaSubType(format)
        var count = 0
        var nalLength: Int32 = 0
        let status: OSStatus
        if codec == kCMVideoCodecType_H264 {
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength
            )
        } else if codec == kCMVideoCodecType_HEVC {
            status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength
            )
        } else {
            throw AVCCError.missingParameterSets
        }

        guard status == noErr, count > 0 else { throw AVCCError.missingParameterSets }
        var result = Data(capacity: 128)
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let setStatus: OSStatus
            if codec == kCMVideoCodecType_H264 {
                setStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
            } else {
                setStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
            }
            guard setStatus == noErr, let pointer else { throw AVCCError.missingParameterSets }
            result.append(startCode)
            result.append(pointer, count: size)
        }
        return result
    }
}
