package dev.andmon.receiver

import java.nio.ByteBuffer
import java.nio.ByteOrder

enum class MessageType(val value: Int) {
    HELLO(1), CONFIG(2), CODEC_CONFIG(3), VIDEO(4),
    PING(5), PONG(6), STOP(7), ERROR(8), KEYFRAME_REQUEST(9),
    AUDIO(10), TOUCH(11);

    companion object {
        fun fromValue(value: Int): MessageType =
            entries.firstOrNull { it.value == value }
                ?: throw ProtocolException("Unknown message type: $value")
    }
}

data class WireFrame(
    val type: MessageType,
    val flags: Int = 0,
    val sequence: Long = 0,
    val ptsMicros: Long = 0,
    val payload: ByteArray = byteArrayOf(),
)

class ProtocolException(message: String) : Exception(message)

object WireProtocol {
    const val HEADER_SIZE = 24
    const val MAX_PAYLOAD_SIZE = 8 * 1024 * 1024
    private val MAGIC = byteArrayOf('A'.code.toByte(), 'N'.code.toByte(), 'D'.code.toByte(), 'M'.code.toByte())

    fun encode(frame: WireFrame): ByteArray {
        require(frame.payload.size <= MAX_PAYLOAD_SIZE) { "Payload exceeds 8 MiB" }
        return ByteBuffer.allocate(HEADER_SIZE + frame.payload.size)
            .order(ByteOrder.BIG_ENDIAN)
            .put(MAGIC)
            .put(1)
            .put(frame.type.value.toByte())
            .putShort(frame.flags.toShort())
            .putInt(frame.payload.size)
            .putInt(frame.sequence.toInt())
            .putLong(frame.ptsMicros)
            .put(frame.payload)
            .array()
    }
}

class FrameParser {
    private var buffer = ByteBuffer.allocate(256 * 1024).order(ByteOrder.BIG_ENDIAN)
    private val magic = byteArrayOf(0x41, 0x4e, 0x44, 0x4d)
    private val headerBuf = ByteArray(4)

    @Synchronized
    @Throws(ProtocolException::class)
    fun append(bytes: ByteArray, length: Int = bytes.size): List<WireFrame> {
        require(length in 0..bytes.size)
        if (buffer.remaining() < length) grow(length)
        buffer.put(bytes, 0, length)
        buffer.flip()
        val frames = mutableListOf<WireFrame>()

        while (buffer.remaining() >= WireProtocol.HEADER_SIZE) {
            val mark = buffer.position()
            buffer.get(headerBuf)
            if (!headerBuf.contentEquals(magic)) {
                throw ProtocolException("Invalid frame magic")
            }
            val version = buffer.get().toInt() and 0xff
            if (version != 1) throw ProtocolException("Unsupported protocol version: $version")
            val type = MessageType.fromValue(buffer.get().toInt() and 0xff)
            val flags = buffer.short.toInt() and 0xffff
            val payloadLength = buffer.int
            if (payloadLength < 0 || payloadLength > WireProtocol.MAX_PAYLOAD_SIZE) {
                throw ProtocolException("Invalid payload length: $payloadLength")
            }
            val sequence = buffer.int.toLong() and 0xffffffffL
            val ptsMicros = buffer.long
            val totalLength = WireProtocol.HEADER_SIZE + payloadLength
            if (buffer.remaining() < payloadLength) {
                buffer.position(mark)
                break
            }
            val payload = ByteArray(payloadLength)
            buffer.get(payload)
            frames += WireFrame(
                type = type,
                flags = flags,
                sequence = sequence,
                ptsMicros = ptsMicros,
                payload = payload,
            )
        }

        buffer.compact()
        return frames
    }

    private fun grow(needed: Int) {
        val newCapacity = maxOf(buffer.capacity() * 2, buffer.position() + needed)
        val grown = ByteBuffer.allocate(newCapacity).order(ByteOrder.BIG_ENDIAN)
        buffer.flip()
        grown.put(buffer)
        buffer = grown
    }
}
