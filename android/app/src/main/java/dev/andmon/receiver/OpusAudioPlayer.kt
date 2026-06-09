package dev.andmon.receiver

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

class OpusAudioPlayer {
    private val TAG = "OpusAudioPlayer"
    private val queue = ArrayBlockingQueue<ByteArray>(20)
    private val running = AtomicBoolean(false)
    private var thread: Thread? = null
    private var decoder: MediaCodec? = null
    private var audioTrack: AudioTrack? = null
    private var debugPacketCount = 0
    private var debugDecodedCount = 0

    fun queue(packet: ByteArray) {
        if (!running.get()) return
        debugPacketCount++
        if (debugPacketCount % 100 == 1) {
            Log.d(TAG, "[DEBUG-AND-AUDIO] Queued packet count = $debugPacketCount, size = ${packet.size}, queue size = ${queue.size}")
        }
        synchronized(queue) {
            if (queue.size >= 20) {
                queue.poll() // Drop oldest packet to prevent latency buildup
            }
            queue.offer(packet)
        }
    }

    fun start() {
        if (running.getAndSet(true)) return
        queue.clear()
        thread = Thread({ runPlayback() }, "andmon-audio-player").also { it.start() }
    }

    fun stop() {
        if (!running.getAndSet(false)) return
        thread?.interrupt()
        thread = null
        synchronized(queue) {
            queue.clear()
        }
    }

    private fun runPlayback() {
        try {
            setupDecoder()
            setupAudioTrack()

            val bufferInfo = MediaCodec.BufferInfo()
            var lastPtsUs = 0L

            while (running.get() && !Thread.currentThread().isInterrupted) {
                val packet = try {
                    queue.take()
                } catch (e: InterruptedException) {
                    break
                }

                val dec = decoder ?: break
                val track = audioTrack ?: break

                // 1. Enqueue input buffer
                var enqueued = false
                while (running.get() && !Thread.currentThread().isInterrupted && !enqueued) {
                    val inputIndex = dec.dequeueInputBuffer(10000) // 10ms timeout
                    if (inputIndex >= 0) {
                        val inputBuffer = dec.getInputBuffer(inputIndex)!!
                        inputBuffer.clear()
                        inputBuffer.put(packet)
                        
                        val ptsUs = lastPtsUs + 20000 // estimate 20ms steps
                        dec.queueInputBuffer(inputIndex, 0, packet.size, ptsUs, 0)
                        lastPtsUs = ptsUs
                        enqueued = true
                    } else {
                        // Dequeue output buffers to avoid deadlock/starvation
                        drainOutputBuffers(dec, track, bufferInfo)
                    }
                }

                // 2. Dequeue output buffers
                drainOutputBuffers(dec, track, bufferInfo)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Audio playback thread error: ${e.message}", e)
        } finally {
            cleanup()
        }
    }

    private fun drainOutputBuffers(dec: MediaCodec, track: AudioTrack, bufferInfo: MediaCodec.BufferInfo) {
        while (running.get()) {
            val outputIndex = dec.dequeueOutputBuffer(bufferInfo, 0)
            if (outputIndex >= 0) {
                val outputBuffer = dec.getOutputBuffer(outputIndex)!!
                val pcm = ByteArray(bufferInfo.size)
                outputBuffer.position(bufferInfo.offset)
                outputBuffer.get(pcm)

                track.write(pcm, 0, pcm.size)

                dec.releaseOutputBuffer(outputIndex, false)

                debugDecodedCount++
                if (debugDecodedCount % 100 == 1) {
                    Log.d(TAG, "[DEBUG-AND-AUDIO] Decoded output count = $debugDecodedCount, size = ${pcm.size}")
                }
            } else if (outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
                break
            } else if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                // MediaCodec format updated (e.g. sample rate, channels)
            }
        }
    }

    private fun setupDecoder() {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, 48000, 2)
        
        // Construct the 19-byte OpusHead CSD-0 identification header
        val opusHead = byteArrayOf(
            'O'.code.toByte(), 'p'.code.toByte(), 'u'.code.toByte(), 's'.code.toByte(),
            'H'.code.toByte(), 'e'.code.toByte(), 'a'.code.toByte(), 'd'.code.toByte(),
            1, // version
            2, // channels
            0x38.toByte(), 0x01.toByte(), // pre-skip = 312
            0x80.toByte(), 0xbb.toByte(), 0x00.toByte(), 0x00.toByte(), // sample rate = 48000
            0x00.toByte(), 0x00.toByte(), // output gain = 0
            0 // mapping family = 0
        )
        format.setByteBuffer("csd-0", ByteBuffer.wrap(opusHead))

        // csd-1: Pre-skip in nanoseconds (64-bit integer, native byte order)
        // 312 samples at 48000Hz = 6.5ms = 6,500,000 ns
        val preSkipNs = 312L * 1_000_000_000L / 48000L
        val csd1 = ByteBuffer.allocate(8).order(ByteOrder.nativeOrder()).putLong(preSkipNs)
        csd1.flip()
        format.setByteBuffer("csd-1", csd1)

        // csd-2: Seek pre-roll in nanoseconds (64-bit integer, native byte order)
        // Typically 80ms = 80,000,000 ns
        val seekPreRollNs = 80_000_000L
        val csd2 = ByteBuffer.allocate(8).order(ByteOrder.nativeOrder()).putLong(seekPreRollNs)
        csd2.flip()
        format.setByteBuffer("csd-2", csd2)

        decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS).apply {
            configure(format, null, null, 0)
            start()
        }
    }

    private fun setupAudioTrack() {
        val minBufferSize = AudioTrack.getMinBufferSize(
            48000,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        
        // Use low-latency performance mode
        audioTrack = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(48000)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build()
            )
            .setBufferSizeInBytes(minBufferSize * 2)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build().apply {
                play()
            }
    }

    private fun cleanup() {
        try {
            decoder?.run {
                stop()
                release()
            }
        } catch (e: Exception) {
            // ignore
        }
        decoder = null

        try {
            audioTrack?.run {
                stop()
                release()
            }
        } catch (e: Exception) {
            // ignore
        }
        audioTrack = null
    }
}
