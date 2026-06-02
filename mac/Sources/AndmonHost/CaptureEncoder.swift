import CoreMedia
import CoreVideo
import CoreGraphics
import Foundation
import ScreenCaptureKit
import VideoToolbox

final class CaptureEncoder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let defaultBitrate = 12_000_000
    private static let maxInFlightFrames = 2

    private let displayID: CGDirectDisplayID
    private let transport: USBTransport
    private let bitrate: Int
    private let captureQueue = DispatchQueue(label: "dev.andmon.capture")
    private var stream: SCStream?
    private var compression: VTCompressionSession?
    private let encoderStateLock = NSLock()
    private var forceKeyframe = true
    private var inFlightFrames = 0
    private var lastParameterSets: Data?
    private let metricsQueue = DispatchQueue(label: "dev.andmon.metrics")
    private let metricsLock = NSLock()
    private var metricsTimer: DispatchSourceTimer?
    private var capturedFrames = 0
    private var encodedFrames = 0
    private var encodeLatencyTotalNanoseconds: UInt64 = 0
    private var encodeLatencyMaxNanoseconds: UInt64 = 0
    private var encodeLatencySampleCount = 0
    private var encoderInputDrops = 0

    init(displayID: CGDirectDisplayID, transport: USBTransport, bitrate: Int) {
        self.displayID = displayID
        self.transport = transport
        self.bitrate = bitrate
    }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw StreamError.screenRecordingPermissionRequired
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw StreamError.virtualDisplayNotCapturable
        }
        let configuration = SCStreamConfiguration()
        configuration.width = 2960
        configuration.height = 1848
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // VideoToolbox retains capture surfaces asynchronously while encoding.
        // Keep one additional surface available so ScreenCaptureKit can continue
        // producing frames while the current frame is in flight.
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = true

        try createCompressionSession()
        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        self.stream = stream
        startMetrics()
        try await stream.startCapture()
    }

    func stop(completion: @escaping @Sendable () -> Void = {}) {
        let stream = self.stream
        self.stream = nil
        metricsTimer?.cancel()
        metricsTimer = nil
        guard let stream else {
            finishStop()
            completion()
            return
        }
        Task {
            try? await stream.stopCapture()
            finishStop()
            completion()
        }
    }

    private func finishStop() {
        if let compression {
            VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(compression)
        }
        compression = nil
    }

    func requestKeyframe() {
        encoderStateLock.withLock { forceKeyframe = true }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("ScreenCaptureKit stopped: \(error.localizedDescription)\n", stderr)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let imageBuffer = sampleBuffer.imageBuffer, let compression else { return }
        metricsLock.withLock { capturedFrames += 1 }
        let admission = encoderStateLock.withLock { () -> (accepted: Bool, properties: CFDictionary?) in
            guard inFlightFrames < Self.maxInFlightFrames else { return (false, nil) }
            inFlightFrames += 1
            guard forceKeyframe else { return (true, nil) }
            forceKeyframe = false
            return (true, [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary)
        }
        guard admission.accepted else {
            metricsLock.withLock { encoderInputDrops += 1 }
            return
        }
        let timing = Unmanaged.passRetained(
            EncodedFrameTiming(startNanoseconds: DispatchTime.now().uptimeNanoseconds)
        )
        let status = VTCompressionSessionEncodeFrame(
            compression, imageBuffer: imageBuffer,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            duration: sampleBuffer.duration, frameProperties: admission.properties,
            sourceFrameRefcon: timing.toOpaque(), infoFlagsOut: nil
        )
        if status != noErr {
            timing.release()
            encoderStateLock.withLock { inFlightFrames -= 1 }
            if admission.properties != nil { requestKeyframe() }
        }
    }

    private func createCompressionSession() throws {
        var created: VTCompressionSession?
        let encoderSpecification = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue,
        ] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: nil, width: 2960, height: 1848,
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: encoderCallback, refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created
        )
        guard status == noErr, let created else { throw StreamError.encoderCreationFailed(status) }
        compression = created
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue
        )
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_Quality, value: 0.5 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaximumRealTimeFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_ColorPrimaries,
            value: kCVImageBufferColorPrimaries_ITU_R_709_2
        )
        VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_TransferFunction,
            value: kCVImageBufferTransferFunction_ITU_R_709_2
        )
        VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_YCbCrMatrix,
            value: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        )
        VTCompressionSessionPrepareToEncodeFrames(created)
    }

    fileprivate func encoded(
        status: OSStatus, sampleBuffer: CMSampleBuffer?, encodeLatencyNanoseconds: UInt64?
    ) {
        encoderStateLock.withLock { inFlightFrames -= 1 }
        guard status == noErr, let sampleBuffer, sampleBuffer.dataReadiness == .ready,
              let blockBuffer = sampleBuffer.dataBuffer else { return }
        do {
            metricsLock.withLock {
                encodedFrames += 1
                if let encodeLatencyNanoseconds {
                    encodeLatencyTotalNanoseconds += encodeLatencyNanoseconds
                    encodeLatencyMaxNanoseconds = max(encodeLatencyMaxNanoseconds, encodeLatencyNanoseconds)
                    encodeLatencySampleCount += 1
                }
            }
            if let format = sampleBuffer.formatDescription {
                let sets = try AVCCConverter.parameterSets(from: format)
                if sets != lastParameterSets {
                    lastParameterSets = sets
                    try transport.send(type: .codecConfig, payload: sets)
                }
            }
            let avcc = try blockBuffer.contiguousData()
            let keyframe = !sampleBuffer.isNotSync
            let enqueueResult = try transport.sendAVCC(
                type: .video, flags: keyframe ? 1 : 0,
                ptsMicros: UInt64(max(0, sampleBuffer.presentationTimeStamp.seconds * 1_000_000)),
                avccPayload: avcc
            )
            if !enqueueResult.acceptedForDecoder(isKeyframe: keyframe) { requestKeyframe() }
        } catch {
            fputs("Encoded frame transport failed: \(error)\n", stderr)
        }
    }

    private func startMetrics() {
        let timer = DispatchSource.makeTimerSource(queue: metricsQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let snapshot = metricsLock.withLock {
                () -> (captured: Int, encoded: Int, average: Double, max: Double, inputDrops: Int) in
                let average = encodeLatencySampleCount == 0
                    ? 0
                    : Double(encodeLatencyTotalNanoseconds) / Double(encodeLatencySampleCount) / 1_000_000
                let max = Double(encodeLatencyMaxNanoseconds) / 1_000_000
                defer {
                    capturedFrames = 0
                    encodedFrames = 0
                    encodeLatencyTotalNanoseconds = 0
                    encodeLatencyMaxNanoseconds = 0
                    encodeLatencySampleCount = 0
                    encoderInputDrops = 0
                }
                return (capturedFrames, encodedFrames, average, max, encoderInputDrops)
            }
            let queuedBytes = transport.queuedByteCount
            let videoDrops = transport.takeReplacedVideoFrameCount()
            let averageLatency = String(format: "%.2f", snapshot.average)
            let maxLatency = String(format: "%.2f", snapshot.max)
            fputs("metrics captureFPS=\(snapshot.captured) encodedFPS=\(snapshot.encoded) bitrate=\(bitrate) encodeLatencyAvgMs=\(averageLatency) encodeLatencyMaxMs=\(maxLatency) encoderInputDrops=\(snapshot.inputDrops) usbQueueBytes=\(queuedBytes) usbVideoDrops=\(videoDrops)\n", stderr)
        }
        metricsTimer = timer
        timer.resume()
    }

}

private final class EncodedFrameTiming {
    let startNanoseconds: UInt64

    init(startNanoseconds: UInt64) {
        self.startNanoseconds = startNanoseconds
    }
}

private let encoderCallback: VTCompressionOutputCallback = { refcon, sourceFrameRefcon, status, _, sampleBuffer in
    let encodeLatencyNanoseconds = sourceFrameRefcon.map {
        let timing = Unmanaged<EncodedFrameTiming>.fromOpaque($0).takeRetainedValue()
        return DispatchTime.now().uptimeNanoseconds - timing.startNanoseconds
    }
    guard let refcon else { return }
    Unmanaged<CaptureEncoder>.fromOpaque(refcon).takeUnretainedValue().encoded(
        status: status, sampleBuffer: sampleBuffer, encodeLatencyNanoseconds: encodeLatencyNanoseconds
    )
}

enum StreamError: LocalizedError {
    case screenRecordingPermissionRequired
    case virtualDisplayNotCapturable
    case encoderCreationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionRequired:
            "Screen Recording permission is required. Grant access in System Settings and Andmon will retry."
        case .virtualDisplayNotCapturable:
            "The Andmon virtual display is not capturable by ScreenCaptureKit"
        case .encoderCreationFailed(let status):
            "Unable to create the HEVC encoder: \(status)"
        }
    }
}

private extension CMBlockBuffer {
    func contiguousData() throws -> Data {
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            self, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer
        )
        if status == kCMBlockBufferNoErr, let pointer {
            return Data(bytesNoCopy: pointer, count: length, deallocator: .none)
        }
        let dataLength = CMBlockBufferGetDataLength(self)
        var data = Data(count: dataLength)
        let copyStatus = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(self, atOffset: 0, dataLength: dataLength, destination: $0.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else { throw AVCCError.malformedAccessUnit }
        return data
    }
}

private extension CMSampleBuffer {
    var isNotSync: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first else { return false }
        return first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
    }
}
