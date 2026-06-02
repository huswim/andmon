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
            StreamConfig(2960, 1848, 60, "video/hevc"),
            StreamConfig.validated(2960, 1848, 60, "video/hevc"),
        )
    }

    @Test
    fun rejectsUnexpectedStreamProfile() {
        assertThrows(IllegalArgumentException::class.java) {
            StreamConfig.validated(1920, 1080, 60, "video/hevc")
        }
        assertThrows(IllegalArgumentException::class.java) {
            StreamConfig.validated(2960, 1848, 60, "video/avc")
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
}
