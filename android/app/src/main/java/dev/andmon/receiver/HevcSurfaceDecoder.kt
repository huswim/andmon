package dev.andmon.receiver

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.view.Surface

class HevcSurfaceDecoder {
    private var codec: MediaCodec? = null
    private var configured = false

    @Synchronized
    fun configure(surface: Surface, width: Int, height: Int) {
        close()
        codec = createLowLatencyDecoder().also {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, TabletProfile.FPS)
            format.setFloat(MediaFormat.KEY_OPERATING_RATE, TabletProfile.FPS.toFloat())
            format.setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
            format.setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
            format.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
            it.configure(format, surface, null, 0)
            it.start()
        }
        configured = true
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
        drain(activeCodec)
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
        activeCodec.queueInputBuffer(index, 0, frame.payload.size, frame.ptsMicros, codecFlags)
        drain(activeCodec)
        return true
    }

    private fun drain(activeCodec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var newestIndex = -1
        while (true) {
            val index = activeCodec.dequeueOutputBuffer(info, 0)
            if (index < 0) break
            if (newestIndex >= 0) activeCodec.releaseOutputBuffer(newestIndex, false)
            newestIndex = index
        }
        if (newestIndex >= 0) activeCodec.releaseOutputBuffer(newestIndex, true)
    }

    @Synchronized
    fun close() {
        configured = false
        codec?.runCatching { stop() }
        codec?.runCatching { release() }
        codec = null
    }
}
