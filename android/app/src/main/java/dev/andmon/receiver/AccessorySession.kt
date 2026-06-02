package dev.andmon.receiver

import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.ParcelFileDescriptor
import android.view.Surface
import org.json.JSONObject
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

class AccessorySession(
    private val usbManager: UsbManager,
    private val decoder: HevcSurfaceDecoder,
    private val onStatus: (String) -> Unit,
) {
    private var descriptor: ParcelFileDescriptor? = null
    private var input: FileInputStream? = null
    private var output: FileOutputStream? = null
    private val running = AtomicBoolean(false)
    private var surface: Surface? = null
    private var configured = false
    private var streamConfig: StreamConfig? = null
    private val pendingPongs = mutableListOf<ByteArray>()
    private val keyframeRecovery = KeyframeRecovery()
    private val decodeQueue = ArrayBlockingQueue<WireFrame>(2)
    private var decodeThread: Thread? = null
    private var nextSequence = 1L
    var usbVideoDrops = 0

    val isOpen: Boolean
        get() = running.get()

    @Synchronized
    fun updateSurface(surface: Surface?) {
        this.surface = surface
        if (surface == null) {
            configured = false
            decoder.close()
        } else {
            configureDecoderIfReady()
        }
    }

    fun open(accessory: UsbAccessory, panelWidth: Int, panelHeight: Int) {
        close()
        usbVideoDrops = 0
        if (panelWidth != TabletProfile.PANEL_WIDTH || panelHeight != TabletProfile.PANEL_HEIGHT) {
            onStatus(
                "Unsupported panel: ${panelWidth} x ${panelHeight}; expected " +
                    "${TabletProfile.PANEL_WIDTH} x ${TabletProfile.PANEL_HEIGHT}",
            )
            return
        }
        val fd = usbManager.openAccessory(accessory)
        if (fd == null) {
            onStatus("Unable to open USB accessory")
            return
        }
        descriptor = fd
        input = FileInputStream(fd.fileDescriptor)
        output = FileOutputStream(fd.fileDescriptor)
        running.set(true)
        sendHello(panelWidth, panelHeight)
        onStatus("Negotiating with Mac")
        Thread({ helloLoop(panelWidth, panelHeight) }, "andmon-hello-retry").start()
        Thread({ readLoop() }, "andmon-usb-reader").start()
        decodeThread = Thread({ decodeLoop() }, "andmon-decoder").also { it.start() }
    }

    private fun sendHello(panelWidth: Int, panelHeight: Int) {
        send(
            MessageType.HELLO,
            JSONObject()
                .put("panelWidth", panelWidth)
                .put("panelHeight", panelHeight)
                .put("landscape", true)
                .put("decoder", TabletProfile.MIME_TYPE)
                .toString()
                .toByteArray(),
        )
    }

    private fun helloLoop(panelWidth: Int, panelHeight: Int) {
        while (running.get()) {
            Thread.sleep(1_000)
            synchronized(this) {
                if (running.get() && streamConfig == null) sendHello(panelWidth, panelHeight)
            }
        }
    }

    private fun readLoop() {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_DISPLAY)
        val parser = FrameParser()
        val buffer = ByteArray(64 * 1024)
        try {
            while (running.get()) {
                val count = input?.read(buffer) ?: break
                if (count < 0) break
                parser.append(buffer, count).forEach(::handle)
            }
        } catch (error: Exception) {
            if (running.get()) onStatus("USB session error: ${error.message}")
        } finally {
            close()
            onStatus("Waiting for USB cable")
        }
    }

    private fun decodeLoop() {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_VIDEO)
        try {
            while (running.get()) {
                val frame = try { decodeQueue.poll(100, java.util.concurrent.TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { null }
                if (frame == null) continue
                when (frame.type) {
                    MessageType.CODEC_CONFIG -> {
                        if (configured && !decoder.queue(frame, codecConfig = true)) {
                            reject("Decoder did not accept HEVC parameter sets")
                        }
                    }
                    MessageType.VIDEO -> {
                        if (configured) {
                            val queued = decoder.queue(frame)
                            if (keyframeRecovery.onVideoResult(queued, (frame.flags and 1) != 0)) send(MessageType.KEYFRAME_REQUEST)
                        }
                    }
                    else -> {}
                }
            }
        } catch (error: Exception) {
            if (running.get()) onStatus("Decode error: ${error.message}")
        }
    }

    private fun handle(frame: WireFrame) {
        when (frame.type) {
            MessageType.CONFIG -> {
                try {
                    val config = JSONObject(frame.payload.toString(Charsets.UTF_8))
                    configure(
                        StreamConfig.validated(
                            config.getInt("width"),
                            config.getInt("height"),
                            config.getInt("fps"),
                            config.getString("codec"),
                        ),
                    )
                } catch (error: Exception) {
                    reject("Unsupported stream config: ${error.message}")
                }
            }
            MessageType.CODEC_CONFIG -> {
                if (!configured) return
                decodeQueue.put(frame)
            }
            MessageType.VIDEO -> {
                if (!configured) return
                if (!decodeQueue.offer(frame)) {
                    val dropped = decodeQueue.poll()
                    if (dropped != null) {
                        usbVideoDrops++
                        if (keyframeRecovery.onVideoResult(false, (dropped.flags and 1) != 0)) send(MessageType.KEYFRAME_REQUEST)
                    }
                    decodeQueue.offer(frame)
                }
            }
            MessageType.PING -> pongWhenReady(frame.payload)
            MessageType.STOP -> {
                onStatus("Stopped by Mac")
                close()
            }
            MessageType.ERROR -> onStatus("Mac error: ${frame.payload.toString(Charsets.UTF_8)}")
            else -> Unit
        }
    }

    @Synchronized
    private fun configure(config: StreamConfig) {
        streamConfig = config
        if (surface == null) {
            configured = false
            onStatus("Waiting for display surface")
            return
        }
        configureDecoderIfReady()
    }

    private fun configureDecoderIfReady() {
        val target = surface ?: return
        val config = streamConfig ?: return
        try {
            decoder.configure(target, config.width, config.height)
        } catch (error: Exception) {
            reject("Unable to configure HEVC decoder: ${error.message}")
            return
        }
        configured = true
        onStatus("Streaming ${config.width} x ${config.height}")
        pendingPongs.forEach { send(MessageType.PONG, it) }
        pendingPongs.clear()
    }

    @Synchronized
    private fun pongWhenReady(payload: ByteArray) {
        if (streamConfig != null && !configured) {
            pendingPongs += payload
        } else {
            send(MessageType.PONG, payload)
        }
    }

    @Synchronized
    private fun send(type: MessageType, payload: ByteArray = byteArrayOf()) {
        if (!running.get()) return
        val bytes = WireProtocol.encode(WireFrame(type, sequence = nextSequence++, payload = payload))
        output?.run {
            write(bytes)
            flush()
        }
    }

    private fun reject(message: String) {
        onStatus(message)
        send(MessageType.ERROR, JSONObject().put("message", message).toString().toByteArray())
        close()
    }

    @Synchronized
    fun close() {
        running.set(false)
        configured = false
        streamConfig = null
        pendingPongs.clear()
        keyframeRecovery.reset()
        decodeQueue.clear()
        decodeThread?.interrupt()
        decodeThread = null
        decoder.close()
        input?.runCatching { close() }
        output?.runCatching { close() }
        descriptor?.runCatching { close() }
        input = null
        output = null
        descriptor = null
    }

}
