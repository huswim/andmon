package dev.andmon.receiver

import android.util.Log
import android.os.Build
import android.view.Surface
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import org.json.JSONObject
import java.io.InputStream
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class UdpFrameAssembler(private val onVideoLoss: () -> Unit) {
    private val buffers = ConcurrentHashMap<Long, FrameBuffer>()
    private val checkTimer = java.util.Timer("andu-cleanup-timer", true)

    val totalUdpPacketsExpected = AtomicLong(0)
    val totalUdpPacketsLost = AtomicLong(0)
    private var lastLossResetTime = System.currentTimeMillis()

    init {
        checkTimer.scheduleAtFixedRate(object : java.util.TimerTask() {
            override fun run() {
                cleanupExpiredBuffers()
            }
        }, 10, 10)
    }

    class FrameBuffer(val totalChunks: Int) {
        val numData = totalChunks
        val createdAt = System.currentTimeMillis()
        val chunks = arrayOfNulls<ByteArray>(totalChunks)
        var receivedCount = 0
        var isVideo = false
    }

    fun handleChunk(packetData: ByteArray, length: Int): ByteArray? {
        if (length < 16) return null
        
        // Parse ANDU header
        if (packetData[0] != 'A'.code.toByte() || packetData[1] != 'N'.code.toByte() ||
            packetData[2] != 'D'.code.toByte() || packetData[3] != 'U'.code.toByte()) {
            return null
        }

        val buffer = ByteBuffer.wrap(packetData, 4, 12).order(ByteOrder.BIG_ENDIAN)
        val frameID = buffer.int.toLong() and 0xffffffffL
        val chunkIndex = buffer.short.toInt() and 0xffff
        val totalChunks = buffer.short.toInt() and 0xffff
        val fecType = buffer.get().toInt() and 0xff
        val fecGroupSize = buffer.get().toInt() and 0xff
        val flags = buffer.get().toInt() and 0xff
        val reserved = buffer.get().toInt() and 0xff
        
        if (chunkIndex >= totalChunks || totalChunks == 0) return null
        
        val payloadSize = length - 16
        if (payloadSize <= 0) return null
        val payload = ByteArray(payloadSize)
        System.arraycopy(packetData, 16, payload, 0, payloadSize)

        val frameBuf = buffers.computeIfAbsent(frameID) {
            totalUdpPacketsExpected.addAndGet(totalChunks.toLong())
            FrameBuffer(totalChunks)
        }

        synchronized(frameBuf) {
            if (frameBuf.chunks[chunkIndex] == null) {
                frameBuf.chunks[chunkIndex] = payload
                frameBuf.receivedCount++
                
                // Inspect message type from first chunk
                if (chunkIndex == 0 && payload.size >= 6) {
                    val msgType = payload[5].toInt() and 0xff
                    if (msgType == MessageType.VIDEO.value) {
                        frameBuf.isVideo = true
                    }
                }

                if (isComplete(frameBuf)) {
                    buffers.remove(frameID)
                    return reassemble(frameBuf)
                }
            }
        }
        return null
    }

    private fun isComplete(frameBuf: FrameBuffer): Boolean {
        for (i in 0 until frameBuf.totalChunks) {
            if (frameBuf.chunks[i] == null) return false
        }
        return true
    }

    private fun reassemble(frameBuf: FrameBuffer): ByteArray {
        var totalBytes = 0
        for (i in 0 until frameBuf.totalChunks) {
            totalBytes += frameBuf.chunks[i]?.size ?: 0
        }
        val result = ByteArray(totalBytes)
        var offset = 0
        for (i in 0 until frameBuf.numData) {
            val chunk = frameBuf.chunks[i]
            if (chunk != null) {
                System.arraycopy(chunk, 0, result, offset, chunk.size)
                offset += chunk.size
            }
        }
        return result
    }

    private fun cleanupExpiredBuffers() {
        val now = System.currentTimeMillis()
        val iterator = buffers.entries.iterator()
        var reportedLoss = false
        while (iterator.hasNext()) {
            val entry = iterator.next()
            val buf = entry.value
            if (now - buf.createdAt > 100) { // 100ms timeout
                iterator.remove()
                totalUdpPacketsLost.addAndGet((buf.totalChunks - buf.receivedCount).toLong())
                if (buf.isVideo) {
                    reportedLoss = true
                }
            }
        }
        if (reportedLoss) {
            onVideoLoss()
        }
    }
    
    fun getPacketLossRate(): Double {
        val now = System.currentTimeMillis()
        val expected = totalUdpPacketsExpected.get()
        val lost = totalUdpPacketsLost.get()
        
        // Reset every 5 seconds to keep metrics dynamic
        if (now - lastLossResetTime > 5000) {
            totalUdpPacketsExpected.set(0)
            totalUdpPacketsLost.set(0)
            lastLossResetTime = now
        }
        
        if (expected <= 0) return 0.0
        return lost.toDouble() / expected.toDouble()
    }
    
    fun reset() {
        buffers.clear()
        totalUdpPacketsExpected.set(0)
        totalUdpPacketsLost.set(0)
    }
    
    fun shutdown() {
        checkTimer.cancel()
        buffers.clear()
    }
}

class NetworkSession(
    private val context: Context,
    private val decoder: HevcSurfaceDecoder,
    private val onStatus: (String, Boolean) -> Unit,
    private val lockManager: SessionLockManager,
) {
    private val running = AtomicBoolean(false)
    private val connected = AtomicBoolean(false)
    private var tcpServer: ServerSocket? = null
    private var udpSocket: DatagramSocket? = null
    private var clientSocket: Socket? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var input: InputStream? = null
    private var output: OutputStream? = null
    private var surface: Surface? = null
    private var configured = false
    
    @Volatile
    private var streamConfig: StreamConfig? = null
    private val pendingPongs = mutableListOf<ByteArray>()
    private val keyframeRecovery = KeyframeRecovery()
    private val audioPlayer = OpusAudioPlayer()
    private val decodeQueue = ArrayBlockingQueue<WireFrame>(2)
    
    private var serverThread: Thread? = null
    private var tcpReadThread: Thread? = null
    private var udpReadThread: Thread? = null
    private var decodeThread: Thread? = null
    private var watchdogThread: Thread? = null
    private val writeQueue = java.util.concurrent.LinkedBlockingQueue<ByteArray>()
    private var writeThread: Thread? = null
    
    private val nextSequence = AtomicLong(1L)
    private val writeLock = Any()
    private val configLock = Any()
    private val lastActivityTime = AtomicLong(0)
    
    private var udpFrameAssembler: UdpFrameAssembler? = null
    var udpVideoDrops = 0
    
    @Volatile var lastHostRttMs: Double = -1.0
    @Volatile var lastHostThroughputMbps: Double = -1.0
    @Volatile var wifiRssi: Int = -127
    @Volatile var wifiLinkSpeed: Int = 0
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    class WifiDetails(val rssi: Int, val linkSpeedMbps: Int)
    
    val isOpen: Boolean
        get() = connected.get()

    val activeConfig: StreamConfig?
        get() = streamConfig

    val videoResolution: String
        get() = streamConfig?.let { "${it.width} x ${it.height}" } ?: "-"

    val videoBitrate: String
        get() = streamConfig?.let { "${it.bitrate / 1_000_000} Mbps" } ?: "-"

    fun updateSurface(surface: Surface?) {
        val needsClose = synchronized(this) {
            this.surface = surface
            if (surface == null) {
                configured = false
                true
            } else {
                false
            }
        }
        if (needsClose) {
            synchronized(configLock) {
                decoder.close()
            }
        } else {
            configureDecoderIfReady()
        }
    }

    fun start() {
        if (running.getAndSet(true)) return
        udpFrameAssembler = UdpFrameAssembler {
            Log.d("NetworkSession", "UDP Packet loss detected, requesting keyframe")
            if (keyframeRecovery.onVideoLoss()) {
                send(MessageType.KEYFRAME_REQUEST)
            }
        }
        serverThread = Thread({ serverLoop() }, "andmon-net-server").also { it.start() }
    }

    private fun serverLoop() {
        try {
            tcpServer = ServerSocket(8001, 50, java.net.InetAddress.getByName("0.0.0.0")).apply { 
                reuseAddress = true 
                receiveBufferSize = 256 * 1024
            }
            Log.i("NetworkSession", "TCP server socket bound to port 8001 with optimized receiveBufferSize")
            
            while (running.get()) {
                onStatus("Waiting for connection", false)
                Log.i("NetworkSession", "TCP server listening on port 8001...")
                val socket = tcpServer?.accept() ?: break
                
                // Optimize TCP Socket options
                socket.tcpNoDelay = true
                socket.receiveBufferSize = 256 * 1024
                socket.keepAlive = true
                
                Log.i("NetworkSession", "Accepted TCP connection from ${socket.remoteSocketAddress}")
                
                // Dynamically recreate UDP socket for the connection lifecycle
                try {
                    // Create unbound DatagramSocket first to set receiveBufferSize BEFORE bind (essential for some OS kernels)
                    udpSocket = DatagramSocket(null).apply {
                        reuseAddress = true
                        receiveBufferSize = 2 * 1024 * 1024 // 2MB receive buffer
                        bind(java.net.InetSocketAddress(java.net.InetAddress.getByName("0.0.0.0"), 8002))
                        try {
                            trafficClass = 0xB8 // DSCP EF
                        } catch (e: Exception) {
                            Log.w("NetworkSession", "Failed to set UDP trafficClass", e)
                        }
                    }
                    Log.i("NetworkSession", "UDP server socket bound to port 8002 with optimized buffer (applied before bind) & trafficClass")
                } catch (e: Exception) {
                    Log.e("NetworkSession", "Failed to bind UDP socket on port 8002", e)
                    socket.runCatching { close() }
                    continue
                }
                
                clientSocket = socket
                input = socket.getInputStream()
                output = socket.getOutputStream()
                lastActivityTime.set(System.currentTimeMillis())
                connected.set(true)
                
                // Acquire low-latency WifiLock
                try {
                    val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                    val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        4 // WifiManager.WIFI_MODE_LOW_LATENCY (introduced in API 29)
                    } else {
                        @Suppress("DEPRECATION")
                        WifiManager.WIFI_MODE_FULL_HIGH_PERF
                    }
                    wifiLock = wifiManager?.createWifiLock(mode, "andmon:wifi_lock")?.apply {
                        setReferenceCounted(false)
                        acquire()
                    }
                    Log.i("NetworkSession", "Acquired low-latency WifiLock")
                } catch (e: Exception) {
                    Log.e("NetworkSession", "Failed to acquire WifiLock", e)
                }
                
                registerWifiCallback()
                
                // Start auxiliary threads
                writeQueue.clear()
                writeThread = Thread({ writeLoop() }, "andmon-net-tcp-writer").also { it.start() }
                udpReadThread = Thread({ udpReadLoop() }, "andmon-net-udp-reader").also { it.start() }
                decodeThread = Thread({ decodeLoop() }, "andmon-net-decoder").also { it.start() }
                watchdogThread = Thread({ watchdogLoop() }, "andmon-net-watchdog").also { it.start() }
                
                sendHello(TabletProfile.PANEL_WIDTH, TabletProfile.PANEL_HEIGHT)
                onStatus("Negotiating with Mac", false)
                
                Log.i("NetworkSession", "Starting sequential TCP read loop on server thread")
                // Run TCP read loop synchronously to block server thread during connection
                tcpReadLoop()
                Log.i("NetworkSession", "TCP read loop finished on server thread")
            }
        } catch (error: Exception) {
            if (running.get()) {
                Log.e("NetworkSession", "Server loop error", error)
            }
        } finally {
            closeSession()
        }
    }

    private fun writeLoop() {
        Log.i("NetworkSession", "TCP Write loop started")
        try {
            while (connected.get() && running.get()) {
                val bytes = try {
                    writeQueue.poll(100, java.util.concurrent.TimeUnit.MILLISECONDS)
                } catch (e: InterruptedException) {
                    null
                }
                if (bytes == null) continue
                
                synchronized(writeLock) {
                    output?.run {
                        write(bytes)
                        flush()
                    }
                }
            }
        } catch (error: Exception) {
            if (connected.get()) {
                Log.e("NetworkSession", "TCP Write loop error", error)
                closeSession()
            }
        } finally {
            Log.i("NetworkSession", "TCP Write loop exiting")
        }
    }

    private fun tcpReadLoop() {
        val parser = FrameParser()
        val buffer = ByteArray(64 * 1024)
        try {
            while (connected.get() && running.get()) {
                val count = input?.read(buffer) ?: break
                if (count < 0) break
                lastActivityTime.set(System.currentTimeMillis())
                parser.append(buffer, count).forEach(::handle)
            }
        } catch (error: Exception) {
            if (connected.get()) Log.e("NetworkSession", "TCP Read error", error)
        } finally {
            Log.i("NetworkSession", "tcpReadLoop exiting, calling closeSession")
            closeSession()
        }
    }

    private fun udpReadLoop() {
        val buffer = ByteArray(2048)
        val packet = DatagramPacket(buffer, buffer.size)
        try {
            while (connected.get() && running.get()) {
                udpSocket?.receive(packet) ?: break
                lastActivityTime.set(System.currentTimeMillis())
                
                val reassembled = udpFrameAssembler?.handleChunk(packet.data, packet.length)
                if (reassembled != null) {
                    val parser = FrameParser()
                    parser.append(reassembled).forEach(::handle)
                }
            }
        } catch (error: Exception) {
            if (error !is SocketException && connected.get()) {
                Log.e("NetworkSession", "UDP Read error", error)
            }
        }
    }

    private fun decodeLoop() {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_VIDEO)
        try {
            while (connected.get()) {
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
                            if (keyframeRecovery.onVideoResult(queued, (frame.flags and 1) != 0)) {
                                send(MessageType.KEYFRAME_REQUEST)
                            }
                        }
                    }
                    else -> {}
                }
            }
        } catch (error: Exception) {
            if (connected.get()) onStatus("Decode error: ${error.message}", false)
        }
    }

    private fun handle(frame: WireFrame) {
        when (frame.type) {
            MessageType.CONFIG -> {
                try {
                    val configStr = frame.payload.toString(Charsets.UTF_8)
                    Log.d("NetworkSession", "Received CONFIG payload: $configStr")
                    val config = JSONObject(configStr)
                    configure(
                        StreamConfig.validated(
                            config.getInt("width"),
                            config.getInt("height"),
                            config.getInt("fps"),
                            config.getInt("bitrate"),
                            config.getString("codec"),
                            config.optBoolean("audioEnabled", false),
                            config.optBoolean("touchEnabled", false)
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
                        udpVideoDrops++
                        if (keyframeRecovery.onVideoResult(false, (dropped.flags and 1) != 0)) {
                            send(MessageType.KEYFRAME_REQUEST)
                        }
                    }
                    decodeQueue.offer(frame)
                }
            }
            MessageType.AUDIO -> {
                if (configured && streamConfig?.audioEnabled == true) {
                    audioPlayer.queue(frame.payload)
                }
            }
            MessageType.PING -> {
                var tokenBytes = frame.payload
                try {
                    val payloadStr = String(frame.payload, Charsets.UTF_8)
                    if (payloadStr.startsWith("{")) {
                        val json = JSONObject(payloadStr)
                        val tokenStr = json.optString("token")
                        if (tokenStr.isNotEmpty()) {
                            tokenBytes = tokenStr.toByteArray(Charsets.UTF_8)
                        }
                        val rtt = json.optDouble("rtt", -1.0)
                        val throughput = json.optDouble("throughput", -1.0)
                        if (rtt >= 0) {
                            lastHostRttMs = rtt
                        }
                        if (throughput >= 0) {
                            lastHostThroughputMbps = throughput
                        }
                    }
                } catch (e: Exception) {
                    Log.e("NetworkSession", "Failed to parse PING JSON payload", e)
                }
                pongWhenReady(tokenBytes)
            }
            MessageType.STOP -> {
                onStatus("Stopped by Mac", false)
                closeSession()
            }
            MessageType.ERROR -> onStatus("Mac error: ${frame.payload.toString(Charsets.UTF_8)}", false)
            else -> Unit
        }
    }

    private fun configure(config: StreamConfig) {
        val needsConfig = synchronized(this) {
            streamConfig = config
            if (surface == null) {
                configured = false
                onStatus("Waiting for display surface", false)
                false
            } else {
                true
            }
        }
        if (needsConfig) {
            if (!lockManager.acquireLock(this)) {
                Log.i("NetworkSession", "Lock busy, rejecting configure")
                reject("Wireless display busy (Wired active)")
                return
            }
            configureDecoderIfReady()
        }
    }

    private fun configureDecoderIfReady() {
        val target: Surface
        val config: StreamConfig
        synchronized(this) {
            target = surface ?: return
            config = streamConfig ?: return
        }
        synchronized(configLock) {
            synchronized(this) {
                if (surface != target || streamConfig != config) return
            }
            try {
                decoder.configure(target, config.width, config.height, config.fps)
            } catch (error: Exception) {
                reject("Unable to configure HEVC decoder: ${error.message}")
                return
            }
            synchronized(this) {
                configured = true
            }
        }
        onStatus("Streaming ${config.width} x ${config.height} @ ${config.fps} FPS", true)
        if (config.audioEnabled) {
            audioPlayer.start()
        } else {
            audioPlayer.stop()
        }
        val pongsToSend = synchronized(this) {
            val list = pendingPongs.toList()
            pendingPongs.clear()
            list
        }
        pongsToSend.forEach { send(MessageType.PONG, it) }
    }

    private fun pongWhenReady(payload: ByteArray) {
        val shouldSend = synchronized(this) {
            if (streamConfig != null && !configured) {
                pendingPongs += payload
                false
            } else {
                true
            }
        }
        if (shouldSend) {
            var responsePayload = payload
            try {
                val tokenStr = String(payload, Charsets.UTF_8)
                val wifiDetails = getLocalWifiDetails()
                val lossRate = udpFrameAssembler?.getPacketLossRate() ?: 0.0
                val json = JSONObject()
                    .put("token", tokenStr)
                    .put("rssi", wifiDetails.rssi)
                    .put("linkSpeed", wifiDetails.linkSpeedMbps)
                    .put("udpDrops", udpVideoDrops)
                    .put("fecRecoveries", 0L)
                    .put("packetLossRate", lossRate)
                responsePayload = json.toString().toByteArray(Charsets.UTF_8)
            } catch (e: Exception) {
                Log.e("NetworkSession", "Failed to build PONG JSON payload", e)
            }
            send(MessageType.PONG, responsePayload)
        }
    }

    fun sendTouchEvent(action: Int, x: Float, y: Float) {
        val payload = JSONObject()
            .put("action", action)
            .put("x", x.toDouble())
            .put("y", y.toDouble())
            .toString()
            .toByteArray(Charsets.UTF_8)
        send(MessageType.TOUCH, payload)
    }

    fun sendScrollEvent(dx: Float, dy: Float) {
        val payload = JSONObject()
            .put("action", 3)
            .put("dx", dx.toDouble())
            .put("dy", dy.toDouble())
            .toString()
            .toByteArray(Charsets.UTF_8)
        send(MessageType.TOUCH, payload)
    }

    private fun send(type: MessageType, payload: ByteArray = byteArrayOf()) {
        if (!connected.get()) return
        try {
            val seq = nextSequence.getAndIncrement()
            val bytes = WireProtocol.encode(WireFrame(type, sequence = seq, payload = payload))
            writeQueue.offer(bytes)
        } catch (error: Exception) {
            if (connected.get()) {
                Log.e("NetworkSession", "TCP Send error", error)
                closeSession()
            }
        }
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

    private fun reject(message: String) {
        onStatus(message, false)
        send(MessageType.ERROR, JSONObject().put("message", message).toString().toByteArray())
        closeSession()
    }

    private fun closeSession() {
        if (!connected.getAndSet(false)) return
        Log.i("NetworkSession", "closeSession() cleaning up connection resources")
        
        lockManager.releaseLock(this)
        unregisterWifiCallback()
        
        synchronized(this) {
            configured = false
            streamConfig = null
            pendingPongs.clear()
            keyframeRecovery.reset()
            decodeQueue.clear()
        }
        
        audioPlayer.stop()
        
        tcpReadThread?.interrupt()
        tcpReadThread = null
        writeThread?.interrupt()
        writeThread = null
        udpReadThread?.interrupt()
        udpReadThread = null
        decodeThread?.interrupt()
        decodeThread = null
        watchdogThread?.interrupt()
        watchdogThread = null
        
        writeQueue.clear()
        
        synchronized(configLock) {
            decoder.close()
        }
        
        input?.runCatching { close() }
        output?.runCatching { close() }
        clientSocket?.runCatching { close() }
        
        udpSocket?.runCatching {
            close()
            Log.i("NetworkSession", "UDP socket closed in closeSession()")
        }
        
        input = null
        output = null
        clientSocket = null
        udpSocket = null
        
        udpFrameAssembler?.reset()
        
        // Release WifiLock
        try {
            wifiLock?.let {
                if (it.isHeld) {
                    it.release()
                }
            }
            wifiLock = null
            Log.i("NetworkSession", "Released WifiLock")
        } catch (e: Exception) {
            Log.e("NetworkSession", "Failed to release WifiLock", e)
        }
    }

    private fun registerWifiCallback() {
        val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        
        networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                val transportInfo = capabilities.transportInfo
                if (transportInfo is android.net.wifi.WifiInfo) {
                    wifiRssi = transportInfo.rssi
                    wifiLinkSpeed = transportInfo.linkSpeed
                }
            }
        }
        try {
            connectivityManager.registerNetworkCallback(request, networkCallback!!)
        } catch (e: Exception) {
            Log.e("NetworkSession", "Failed to register network callback", e)
        }
    }

    private fun unregisterWifiCallback() {
        networkCallback?.let {
            val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            try {
                connectivityManager?.unregisterNetworkCallback(it)
            } catch (e: Exception) {}
        }
        networkCallback = null
        wifiRssi = -127
        wifiLinkSpeed = 0
    }

    fun getLocalWifiDetails(): WifiDetails {
        if (wifiRssi == -127 && wifiLinkSpeed == 0) {
            val hasFine = androidx.core.content.ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.ACCESS_FINE_LOCATION
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
            val hasCoarse = androidx.core.content.ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.ACCESS_COARSE_LOCATION
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
            
            if (hasFine || hasCoarse) {
                try {
                    val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                    val info = wifiManager?.connectionInfo
                    if (info != null) {
                        return WifiDetails(info.rssi, info.linkSpeed)
                    }
                } catch (e: Exception) {}
            }
        }
        return WifiDetails(wifiRssi, wifiLinkSpeed)
    }

    fun disconnect() {
        Log.i("NetworkSession", "disconnect() requested - closing active connection without shutting down listener")
        closeSession()
    }

    fun shutdown() {
        Log.i("NetworkSession", "shutdown() requested - shutting down server listener and active connection")
        running.set(false)
        closeSession()
        
        tcpServer?.runCatching { close() }
        udpSocket?.runCatching { close() }
        
        tcpServer = null
        udpSocket = null
        
        udpFrameAssembler?.shutdown()
        udpFrameAssembler = null
        
        serverThread?.interrupt()
        serverThread = null
    }

    private fun watchdogLoop() {
        try {
            while (connected.get()) {
                Thread.sleep(1000)
                if (!connected.get()) break
                if (System.currentTimeMillis() - lastActivityTime.get() > 8000) {
                    if (connected.get()) {
                        onStatus("Connection timeout", false)
                        closeSession()
                    }
                    break
                }
            }
        } catch (_: InterruptedException) {
        }
    }
}
