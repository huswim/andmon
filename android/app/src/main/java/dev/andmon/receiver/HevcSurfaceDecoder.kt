package dev.andmon.receiver

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.view.Surface
import kotlin.jvm.Volatile

class HevcSurfaceDecoder {
    @Volatile
    private var codec: MediaCodec? = null
    @Volatile
    private var configured = false
    var vsyncEnabled = true

    var renderFrameCount = 0
    var droppedFrameCount = 0
    private val queueTimes = HashMap<Long, Long>()
    private var totalDecodeTimeNs = 0L
    private var decodeCount = 0L
    var averageDecodeTimeMs = 0.0
    var activeDecoderName = "HEVC"
    @Volatile
    var outputResolution = "-"

    private var renderThread: Thread? = null
    private val running = java.util.concurrent.atomic.AtomicBoolean(false)

    @Synchronized
    fun configure(surface: Surface, width: Int, height: Int) {
        close()
        codec = createLowLatencyDecoder().also {
            activeDecoderName = it.codecInfo.name
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            format.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
            format.setInteger("vendor.qti-ext-dec-picture-order.enable", 0)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, TabletProfile.FPS)
            format.setFloat(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toFloat())
            format.setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
            format.setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
            format.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
            it.configure(format, surface, null, 0)
            it.start()
        }
        configured = true
        running.set(true)
        renderThread = Thread({ renderLoop() }, "andmon-renderer").also { it.start() }
    }

    private fun createLowLatencyDecoder(): MediaCodec {
        val mimeType = MediaFormat.MIMETYPE_VIDEO_HEVC
        val lowLatencyCodec = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.firstOrNull { info ->
            !info.isEncoder &&
                info.name.endsWith(".low_latency") &&
                info.supportedTypes.any { it.equals(mimeType, ignoreCase = true) }
        }
        return if (lowLatencyCodec != null) {
            MediaCodec.createByCodecName(lowLatencyCodec.name)
        } else {
            MediaCodec.createDecoderByType(mimeType)
        }
    }

    @Synchronized
    fun queue(frame: WireFrame, codecConfig: Boolean = false): Boolean {
        val activeCodec = codec ?: return false
        if (!configured) return false
        val index = activeCodec.dequeueInputBuffer(if (codecConfig) 100_000 else 0)
        if (index < 0) return false
        val input = activeCodec.getInputBuffer(index) ?: return false
        input.clear()
        if (input.remaining() < frame.payload.size) {
            throw IllegalStateException("Decoder input buffer is smaller than access unit")
        }
        input.put(frame.payload)
        var codecFlags = if ((frame.flags and 1) != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
        if (codecConfig) codecFlags = codecFlags or MediaCodec.BUFFER_FLAG_CODEC_CONFIG

        if (!codecConfig) {
            if (queueTimes.size > 120) queueTimes.clear()
            queueTimes[frame.ptsMicros] = System.nanoTime()
        }

        activeCodec.queueInputBuffer(index, 0, frame.payload.size, frame.ptsMicros, codecFlags)
        return true
    }

    private fun renderLoop() {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_VIDEO)
        val info = MediaCodec.BufferInfo()
        try {
            while (running.get()) {
                val activeCodec = codec
                if (activeCodec == null || !configured) {
                    Thread.sleep(10)
                    continue
                }
                val index = try {
                    activeCodec.dequeueOutputBuffer(info, 50000) // Block up to 50ms waiting for decoded frame
                } catch (e: Exception) {
                    -1
                }
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    outputResolution = activeCodec.outputFormat.visibleResolution()
                    continue
                }
                if (index < 0) continue

                val pts = info.presentationTimeUs
                val queueTime = queueTimes.remove(pts)
                var latencyNs = 0L
                var hasValidLatency = false
                if (queueTime != null) {
                    latencyNs = System.nanoTime() - queueTime
                    hasValidLatency = true
                    totalDecodeTimeNs += latencyNs
                    decodeCount++
                    averageDecodeTimeMs = (totalDecodeTimeNs.toDouble() / decodeCount) / 1_000_000.0
                }

                // Drift prevention: discard frames delayed by > 100ms
                val shouldRender = renderFrameCount == 0 || !hasValidLatency || latencyNs <= 100_000_000L
                if (!shouldRender) {
                    droppedFrameCount++
                    activeCodec.releaseOutputBuffer(index, false)
                    continue
                }

                if (vsyncEnabled) {
                    activeCodec.releaseOutputBuffer(index, true)
                } else {
                    activeCodec.releaseOutputBuffer(index, System.nanoTime())
                }
                renderFrameCount++
            }
        } catch (error: Exception) {
            // Ignore thread interruption on close
        }
    }

    @Synchronized
    fun close() {
        configured = false
        running.set(false)
        renderThread?.interrupt()
        renderThread = null
        codec?.runCatching { stop() }
        codec?.runCatching { release() }
        codec = null
        queueTimes.clear()
        totalDecodeTimeNs = 0L
        decodeCount = 0L
        averageDecodeTimeMs = 0.0
        renderFrameCount = 0
        droppedFrameCount = 0
        outputResolution = "-"
    }

    private fun MediaFormat.visibleResolution(): String {
        val width = getInteger(MediaFormat.KEY_WIDTH)
        val height = getInteger(MediaFormat.KEY_HEIGHT)
        val visibleWidth = if (containsKey("crop-left") && containsKey("crop-right")) {
            getInteger("crop-right") - getInteger("crop-left") + 1
        } else {
            width
        }
        val visibleHeight = if (containsKey("crop-top") && containsKey("crop-bottom")) {
            getInteger("crop-bottom") - getInteger("crop-top") + 1
        } else {
            height
        }
        return "$visibleWidth x $visibleHeight"
    }
}
