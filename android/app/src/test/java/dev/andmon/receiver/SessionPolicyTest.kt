package dev.andmon.receiver

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionPolicyTest {
    @Test
    fun acceptsGalaxyTabHevcProfile() {
        assertEquals(
            StreamConfig(2960, 1848, 60, 80_000_000, "video/hevc", audioEnabled = false, touchEnabled = true),
            StreamConfig.validated(2960, 1848, 60, 80_000_000, "video/hevc", touchEnabled = true),
        )
        assertEquals(90, StreamConfig.validated(2960, 1848, 90, 80_000_000, "video/hevc").fps)
        assertEquals(120, StreamConfig.validated(2960, 1848, 120, 80_000_000, "video/hevc").fps)
    }

    @Test
    fun rejectsUnexpectedStreamProfile() {
        assertThrows(IllegalArgumentException::class.java) {
            StreamConfig.validated(1920, 1080, 60, 80_000_000, "video/hevc")
        }
        assertThrows(IllegalArgumentException::class.java) {
            StreamConfig.validated(2960, 1848, 60, 80_000_000, "video/avc")
        }
        assertThrows(IllegalArgumentException::class.java) {
            StreamConfig.validated(2960, 1848, 60, 0, "video/hevc")
        }
        assertThrows(IllegalArgumentException::class.java) {
            StreamConfig.validated(2960, 1848, 75, 80_000_000, "video/hevc")
        }
    }

    @Test
    fun requestsOneRecoveryKeyframeUntilAnIdrIsQueued() {
        val recovery = KeyframeRecovery()
        assertTrue(recovery.onVideoResult(queued = false, isKeyframe = false))
        assertFalse(recovery.onVideoResult(queued = false, isKeyframe = false))
        assertFalse(recovery.onVideoResult(queued = true, isKeyframe = true))
        assertTrue(recovery.onVideoResult(queued = false, isKeyframe = false))
    }

    @Test
    fun requestsRetryKeyframeOnGuardTimeout() {
        val recovery = KeyframeRecovery()
        assertTrue(recovery.onVideoResult(queued = false, isKeyframe = false))
        assertFalse(recovery.onVideoResult(queued = false, isKeyframe = false))
        assertFalse(recovery.onVideoLoss())
        
        Thread.sleep(600)
        
        // After 500ms guard timeout, it should trigger another keyframe request
        assertTrue(recovery.onVideoResult(queued = false, isKeyframe = false))
        assertFalse(recovery.onVideoResult(queued = false, isKeyframe = false))
        
        Thread.sleep(600)
        
        // Similarly for onVideoLoss
        assertTrue(recovery.onVideoLoss())
    }
}
