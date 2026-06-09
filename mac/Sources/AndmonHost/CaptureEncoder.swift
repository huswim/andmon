import CoreMedia
import CoreVideo
import CoreGraphics
import Foundation
import ScreenCaptureKit
import VideoToolbox
import AudioToolbox
import AVFoundation

final class CaptureEncoder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let defaultBitrate = 12_000_000
    private static let maxInFlightFrames = 2

    private let displayID: CGDirectDisplayID
    private let transport: USBTransport
    private let bitrate: Int
    private let audioEnabled: Bool
    private let captureQueue = DispatchQueue(label: "dev.andmon.capture")
    private var stream: SCStream?
    private var audioStream: SCStream?
    private var compression: VTCompressionSession?
    private let encoderStateLock = NSLock()
    private var loggedCaptureFormat = false
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
    var onMetrics: (@Sendable (SessionMetrics) -> Void)?

    private var audioConverter: AudioConverterRef?
    private var audioSamplesBuffer: [Float] = []
    private var audioStartPTS: CMTime?
    private var totalAudioFramesEncoded: Int64 = 0
    private var debugAudioCount = 0

    init(displayID: CGDirectDisplayID, transport: USBTransport, bitrate: Int, audioEnabled: Bool) {
        self.displayID = displayID
        self.transport = transport
        self.bitrate = bitrate
        self.audioEnabled = audioEnabled
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
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = true

        if audioEnabled {
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48000
        }

        try createCompressionSession()
        setupAudioConverter()
        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        if audioEnabled {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        }
        self.stream = stream
        startMetrics()
        try await stream.startCapture()
    }

    func stop(completion: @escaping @Sendable () -> Void = {}) {
        let stream = self.stream
        self.stream = nil
        metricsTimer?.cancel()
        metricsTimer = nil
        finishStop()
        cleanUpAudioConverter()
        guard let stream else {
            completion()
            return
        }
        completion()
        Task {
            try? await stream.stopCapture()
        }
    }

    private func setupAudioConverter() {
        guard audioEnabled else { return }
        var inputFormat = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960, // 20ms frame
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var converter: AudioConverterRef?
        let status = AudioConverterNew(&inputFormat, &outputFormat, &converter)
        if status == noErr {
            audioConverter = converter

            var bitrate: UInt32 = 64000
            AudioConverterSetProperty(converter!, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)
        } else {
            fputs("Failed to create AudioConverter for Opus: \(status)\n", stderr)
        }
    }

    private func cleanUpAudioConverter() {
        if let audioConverter {
            self.audioConverter = nil
            AudioConverterDispose(audioConverter)
        }
        audioSamplesBuffer.removeAll()
        audioStartPTS = nil
        totalAudioFramesEncoded = 0
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
        if type == .screen {
            guard let imageBuffer = sampleBuffer.imageBuffer, let compression else { return }
            if !loggedCaptureFormat {
                loggedCaptureFormat = true
                fputs(
                    "capture format=\(fourCC(CVPixelBufferGetPixelFormatType(imageBuffer))) " +
                        "size=\(CVPixelBufferGetWidth(imageBuffer))x\(CVPixelBufferGetHeight(imageBuffer))\n",
                    stderr
                )
            }
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
        } else if type == .audio {
            guard audioEnabled, let audioConverter else { return }
            debugAudioCount += 1
            if debugAudioCount % 100 == 1 {
                fputs("[DEBUG-MAC-AUDIO] received audio buffer from SCK, count = \(debugAudioCount)\n", stderr)
            }
            processAudioBuffer(sampleBuffer, converter: audioConverter)
        }
    }

    private func processAudioBuffer(_ sampleBuffer: CMSampleBuffer, converter: AudioConverterRef) {
        guard sampleBuffer.isValid else { return }

        try? sampleBuffer.withAudioBufferList { audioBufferList, blockBuffer in
            let bufferCount = audioBufferList.count
            guard bufferCount > 0 else { return }

            var interleaved: [Float] = []

            if bufferCount >= 2 {
                let leftBuffer = audioBufferList[0]
                let rightBuffer = audioBufferList[1]
                let sampleCount = Int(leftBuffer.mDataByteSize) / MemoryLayout<Float>.size
                guard let leftPtr = leftBuffer.mData?.assumingMemoryBound(to: Float.self),
                      let rightPtr = rightBuffer.mData?.assumingMemoryBound(to: Float.self) else { return }

                interleaved.reserveCapacity(sampleCount * 2)
                for i in 0..<sampleCount {
                    interleaved.append(leftPtr[i])
                    interleaved.append(rightPtr[i])
                }
            } else if bufferCount == 1 {
                let buffer = audioBufferList[0]
                let channels = Int(buffer.mNumberChannels)
                let sampleCount = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                guard let pcmPtr = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }

                if channels == 2 {
                    interleaved = Array(UnsafeBufferPointer(start: pcmPtr, count: sampleCount * 2))
                } else if channels == 1 {
                    interleaved.reserveCapacity(sampleCount * 2)
                    for i in 0..<sampleCount {
                        let val = pcmPtr[i]
                        interleaved.append(val)
                        interleaved.append(val)
                    }
                }
            }

            guard !interleaved.isEmpty else { return }

            audioSamplesBuffer.append(contentsOf: interleaved)

            if audioStartPTS == nil {
                audioStartPTS = sampleBuffer.presentationTimeStamp
            }

            let frameSize = 960
            while audioSamplesBuffer.count >= frameSize * 2 {
                let chunk = Array(audioSamplesBuffer[0..<(frameSize * 2)])
                audioSamplesBuffer.removeFirst(frameSize * 2)

                encodeAudioChunk(chunk, converter: converter)
            }
        }
    }

    private func encodeAudioChunk(_ pcmData: [Float], converter: AudioConverterRef) {
        class InterleavedInputState {
            var data: UnsafeRawPointer
            var byteSize: UInt32
            init(data: UnsafeRawPointer, byteSize: UInt32) {
                self.data = data
                self.byteSize = byteSize
            }
        }

        let inputState = InterleavedInputState(
            data: pcmData.withUnsafeBytes { $0.baseAddress! },
            byteSize: UInt32(pcmData.count * MemoryLayout<Float>.size)
        )

        let inputCallback: AudioConverterComplexInputDataProc = { (
            inAudioConverter: AudioConverterRef,
            ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
            ioData: UnsafeMutablePointer<AudioBufferList>,
            outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
            inUserData: UnsafeMutableRawPointer?
        ) -> OSStatus in
            let state = Unmanaged<InterleavedInputState>.fromOpaque(inUserData!).takeUnretainedValue()
            if state.byteSize == 0 {
                ioNumberDataPackets.pointee = 0
                return 1
            }

            let requestedPackets = ioNumberDataPackets.pointee
            let bytesPerPacket: UInt32 = 8
            let availablePackets = state.byteSize / bytesPerPacket
            let packetsToProvide = min(requestedPackets, availablePackets)

            ioNumberDataPackets.pointee = packetsToProvide

            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mNumberChannels = 2
            ioData.pointee.mBuffers.mDataByteSize = packetsToProvide * bytesPerPacket
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: state.data)

            state.data = state.data.advanced(by: Int(packetsToProvide * bytesPerPacket))
            state.byteSize -= packetsToProvide * bytesPerPacket

            return noErr
        }

        var outputBuffer = [UInt8](repeating: 0, count: 2048)
        var outputBufferList = AudioBufferList()
        outputBufferList.mNumberBuffers = 1
        outputBufferList.mBuffers.mNumberChannels = 2
        outputBufferList.mBuffers.mDataByteSize = UInt32(outputBuffer.count)

        outputBuffer.withUnsafeMutableBytes { rawBuf in
            outputBufferList.mBuffers.mData = rawBuf.baseAddress

            var ioOutputDataPackets: UInt32 = 1
            var packetDescriptions = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: 1)

            let userPtr = Unmanaged.passUnretained(inputState).toOpaque()
            let status = AudioConverterFillComplexBuffer(
                converter,
                inputCallback,
                userPtr,
                &ioOutputDataPackets,
                &outputBufferList,
                &packetDescriptions
            )

            if status == noErr || status == 1 {
                if ioOutputDataPackets > 0 {
                    let desc = packetDescriptions[0]
                    let encodedData = Data(bytes: rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: Int(desc.mStartOffset)), count: Int(desc.mDataByteSize))

                    let startPTSMicros = audioStartPTS.map { UInt64(max(0.0, $0.seconds * 1_000_000.0)) } ?? 0
                    let ptsMicros = startPTSMicros + UInt64((totalAudioFramesEncoded * 1_000_000) / 48000)

                    if totalAudioFramesEncoded % (960 * 100) == 0 {
                        fputs("[DEBUG-MAC-AUDIO] Encoded Opus packet size=\(encodedData.count), pts=\(ptsMicros)\n", stderr)
                    }

                    do {
                        try transport.send(type: .audio, ptsMicros: ptsMicros, payload: encodedData)
                        totalAudioFramesEncoded += 960
                    } catch {
                        fputs("Audio packet transport failed: \(error)\n", stderr)
                    }
                }
            } else {
                fputs("[DEBUG-MAC-AUDIO] AudioConverterFillComplexBuffer failed: \(status)\n", stderr)
            }
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
            created, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanFalse
        )
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_Quality, value: 1.0 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_DataRateLimits,
            value: [bitrate / 8, 1] as CFArray
        )
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

            let metrics = SessionMetrics(
                capturedFPS: snapshot.captured,
                encodedFPS: snapshot.encoded,
                encodeLatencyAvgMs: snapshot.average,
                encodeLatencyMaxMs: snapshot.max,
                encoderInputDrops: snapshot.inputDrops,
                usbQueueBytes: queuedBytes,
                usbVideoDrops: videoDrops
            )
            onMetrics?(metrics)
        }
        metricsTimer = timer
        timer.resume()
    }

}

private func fourCC(_ value: OSType) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? String(value)
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
    case mainDisplayNotFound

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionRequired:
            "Screen Recording permission is required. Grant access in System Settings and Andmon will retry."
        case .virtualDisplayNotCapturable:
            "The Andmon virtual display is not capturable by ScreenCaptureKit"
        case .encoderCreationFailed(let status):
            "Unable to create the HEVC encoder: \(status)"
        case .mainDisplayNotFound:
            "Unable to find the main display for audio capture"
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
