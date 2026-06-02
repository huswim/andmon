package dev.andmon.receiver

object TabletProfile {
    const val PANEL_WIDTH = 2960
    const val PANEL_HEIGHT = 1848
    const val FPS = 60
    const val MIME_TYPE = "video/hevc"
}

data class StreamConfig(
    val width: Int,
    val height: Int,
    val fps: Int,
    val codec: String,
) {
    companion object {
        fun validated(width: Int, height: Int, fps: Int, codec: String): StreamConfig {
            require(width == TabletProfile.PANEL_WIDTH && height == TabletProfile.PANEL_HEIGHT) {
                "Unsupported stream size: $width x $height"
            }
            require(fps == TabletProfile.FPS) { "Unsupported frame rate: $fps" }
            require(codec == TabletProfile.MIME_TYPE) { "Unsupported codec: $codec" }
            return StreamConfig(width, height, fps, codec)
        }
    }
}

class KeyframeRecovery {
    private var requestPending = false

    fun onVideoResult(queued: Boolean, isKeyframe: Boolean): Boolean {
        if (queued && isKeyframe) requestPending = false
        if (!queued && !requestPending) {
            requestPending = true
            return true
        }
        return false
    }

    fun reset() {
        requestPending = false
    }
}
