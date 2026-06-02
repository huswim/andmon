package dev.andmon.receiver

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class FrameParserTest {
    private val sample = WireProtocol.encode(
        WireFrame(MessageType.VIDEO, flags = 1, sequence = 7, ptsMicros = 1234, payload = byteArrayOf(1, 2, 3)),
    )

    @Test
    fun parsesSplitHeader() {
        val parser = FrameParser()
        assertEquals(0, parser.append(sample.copyOfRange(0, 8)).size)
        val frames = parser.append(sample.copyOfRange(8, sample.size))
        assertEquals(1, frames.size)
        assertEquals(MessageType.VIDEO, frames[0].type)
    }

    @Test
    fun parsesSplitPayload() {
        val parser = FrameParser()
        assertEquals(0, parser.append(sample.copyOfRange(0, 25)).size)
        assertArrayEquals(byteArrayOf(1, 2, 3), parser.append(sample.copyOfRange(25, sample.size))[0].payload)
    }

    @Test
    fun parsesMultipleFrames() {
        val parser = FrameParser()
        assertEquals(2, parser.append(sample + sample).size)
    }

    @Test
    fun parsesKeyframeRequest() {
        val request = WireProtocol.encode(WireFrame(MessageType.KEYFRAME_REQUEST))
        assertEquals(MessageType.KEYFRAME_REQUEST, FrameParser().append(request)[0].type)
    }

    @Test(expected = ProtocolException::class)
    fun rejectsInvalidMagic() {
        FrameParser().append(sample.clone().also { it[0] = 0 })
    }

    @Test(expected = ProtocolException::class)
    fun rejectsOversizedPayload() {
        FrameParser().append(sample.clone().also {
            it[8] = 0
            it[9] = 0x80.toByte()
            it[10] = 0
            it[11] = 1
        })
    }

    @Test(expected = ProtocolException::class)
    fun rejectsUnknownVersion() {
        FrameParser().append(sample.clone().also { it[4] = 2 })
    }
}
