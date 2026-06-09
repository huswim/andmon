package dev.andmon.receiver

object TabletProfile {
    const val PANEL_WIDTH = 2960
    const val PANEL_HEIGHT = 1848
    val SUPPORTED_FPS = setOf(60, 90, 120)
    const val MIME_TYPE = "video/hevc"
}

data class StreamConfig(
    val width: Int,
    val height: Int,
    val fps: Int,
    val bitrate: Int,
    val codec: String,
    val audioEnabled: Boolean = false,
    val touchEnabled: Boolean = false,
) {
    companion object {
        fun validated(
            width: Int,
            height: Int,
            fps: Int,
            bitrate: Int,
            codec: String,
            audioEnabled: Boolean = false,
            touchEnabled: Boolean = false,
        ): StreamConfig {
            require(width == TabletProfile.PANEL_WIDTH && height == TabletProfile.PANEL_HEIGHT) {
                "Unsupported stream size: $width x $height"
            }
            require(fps in TabletProfile.SUPPORTED_FPS) { "Unsupported frame rate: $fps" }
            require(bitrate > 0) { "Invalid bitrate: $bitrate" }
            require(codec == TabletProfile.MIME_TYPE) { "Unsupported codec: $codec" }
            return StreamConfig(width, height, fps, bitrate, codec, audioEnabled, touchEnabled)
        }
    }
}

class KeyframeRecovery {
    private val requestPending = java.util.concurrent.atomic.AtomicBoolean(false)
    private val lastRequestTime = java.util.concurrent.atomic.AtomicLong(0)

    fun onVideoResult(queued: Boolean, isKeyframe: Boolean): Boolean {
        if (queued && isKeyframe) {
            requestPending.set(false)
        }
        if (!queued) {
            val now = System.currentTimeMillis()
            val lastSent = lastRequestTime.get()
            if (requestPending.compareAndSet(false, true)) {
                lastRequestTime.set(now)
                return true
            } else if (now - lastSent > 500) {
                if (lastRequestTime.compareAndSet(lastSent, now)) {
                    return true
                }
            }
        }
        return false
    }

    fun onVideoLoss(): Boolean {
        val now = System.currentTimeMillis()
        val lastSent = lastRequestTime.get()
        if (requestPending.compareAndSet(false, true)) {
            lastRequestTime.set(now)
            return true
        } else if (now - lastSent > 500) {
            if (lastRequestTime.compareAndSet(lastSent, now)) {
                return true
            }
        }
        return false
    }

    fun reset() {
        requestPending.set(false)
        lastRequestTime.set(0L)
    }
}
