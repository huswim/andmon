package dev.andmon.receiver

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.graphics.Point
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.view.MotionEvent
import android.widget.FrameLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.appcompat.widget.SwitchCompat

class MainActivity : AppCompatActivity(), SurfaceHolder.Callback {
    private lateinit var usbManager: UsbManager
    private lateinit var decoder: HevcSurfaceDecoder
    private lateinit var session: AccessorySession
    private lateinit var status: TextView
    private lateinit var surfaceView: SurfaceView
    private lateinit var toggleCard: android.widget.LinearLayout
    private lateinit var telemetryCard: android.widget.LinearLayout
    private lateinit var telemetryText: TextView
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private var lastRenderFrameCount = 0
    private var overlaysVisible = true

    private val telemetryRunnable = object : Runnable {
        override fun run() {
            updateTelemetry()
            handler.postDelayed(this, 1000)
        }
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                ACTION_USB_PERMISSION -> {
                    val accessory = intent.accessory()
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false) && accessory != null) {
                        open(accessory)
                    } else {
                        showStatus("USB accessory permission denied", false)
                    }
                }
                UsbManager.ACTION_USB_ACCESSORY_DETACHED -> {
                    session.close()
                    showStatus("Waiting for USB cable", false)
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        configureFullscreen()

        status = TextView(this).apply {
            text = getString(R.string.status_waiting)
            setTextColor(0xffffffff.toInt())
            textSize = 22f
            gravity = Gravity.CENTER
        }
        surfaceView = SurfaceView(this).apply {
            holder.setFixedSize(TabletProfile.PANEL_WIDTH, TabletProfile.PANEL_HEIGHT)
        }

        usbManager = getSystemService(USB_SERVICE) as UsbManager
        decoder = HevcSurfaceDecoder()
        session = AccessorySession(usbManager, decoder, ::showStatus)

        // Glassmorphism transparent VSync toggle panel
        toggleCard = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            val shape = android.graphics.drawable.GradientDrawable().apply {
                setColor(0x80000000.toInt()) // 50% opacity black
                cornerRadius = 24f // rounded corners
            }
            background = shape
            setPadding(36, 18, 36, 18)
        }

        val toggleText = TextView(this).apply {
            text = "Smooth VSync"
            setTextColor(0xffffffff.toInt())
            textSize = 14f
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            setPadding(0, 0, 20, 0)
        }

        val vsyncSwitch = SwitchCompat(this).apply {
            isChecked = true // VSync enabled by default
            setOnCheckedChangeListener { _, isChecked ->
                decoder.vsyncEnabled = isChecked
            }
        }

        toggleCard.addView(toggleText)
        toggleCard.addView(vsyncSwitch)

        val toggleParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT
        ).apply {
            gravity = Gravity.TOP or Gravity.END
            topMargin = 40
            rightMargin = 40
        }

        // Glassmorphism Telemetry Overlay Panel (Top-Left)
        telemetryCard = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            val shape = android.graphics.drawable.GradientDrawable().apply {
                setColor(0x80000000.toInt()) // 50% opacity black
                cornerRadius = 24f // rounded corners
            }
            background = shape
            setPadding(36, 24, 36, 24)
        }

        telemetryText = TextView(this).apply {
            setTextColor(0xffffffff.toInt())
            textSize = 12f
            typeface = android.graphics.Typeface.MONOSPACE
            text = "Telemetry Loading..."
        }
        telemetryCard.addView(telemetryText)

        val telemetryParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            topMargin = 40
            leftMargin = 40
        }

        surfaceView.setOnTouchListener { v, event ->
            val config = session.activeConfig
            val action = event.actionMasked

            if (config == null || !config.touchEnabled) {
                // When touch is disabled, tap to toggle overlay visibility
                if (action == MotionEvent.ACTION_UP) {
                    overlaysVisible = !overlaysVisible
                    updateOverlayVisibility()
                }
                return@setOnTouchListener true
            }

            // Toggle overlay if two fingers touch the screen
            if (event.pointerCount >= 2 && action == MotionEvent.ACTION_POINTER_DOWN) {
                overlaysVisible = !overlaysVisible
                updateOverlayVisibility()
                return@setOnTouchListener true
            }

            // Only track primary pointer (pointer ID 0)
            val pointerId = event.getPointerId(event.actionIndex)
            if (pointerId != 0) {
                return@setOnTouchListener true
            }

            val x = event.x
            val y = event.y
            val width = v.width.toFloat()
            val height = v.height.toFloat()

            if (width > 0 && height > 0) {
                val normalizedX = (x / width).coerceIn(0f, 1f)
                val normalizedY = (y / height).coerceIn(0f, 1f)

                val protoAction = when (action) {
                    MotionEvent.ACTION_DOWN -> 0
                    MotionEvent.ACTION_MOVE -> 1
                    MotionEvent.ACTION_UP -> 2
                    MotionEvent.ACTION_CANCEL -> 2
                    else -> -1
                }

                if (protoAction >= 0) {
                    session.sendTouchEvent(protoAction, normalizedX, normalizedY)
                }
            }
            true
        }

        setContentView(FrameLayout(this).apply {
            setBackgroundColor(0xff000000.toInt())
            addView(surfaceView, FrameLayout.LayoutParams(-1, -1))
            addView(status, FrameLayout.LayoutParams(-1, -1))
            addView(toggleCard, toggleParams)
            addView(telemetryCard, telemetryParams)
        })

        surfaceView.holder.addCallback(this)
        registerAccessoryReceiver()
        intent.accessory()?.let(::requestOrOpen) ?: usbManager.accessoryList?.firstOrNull()?.let(::requestOrOpen)
    }

    override fun onResume() {
        super.onResume()
        reconnectAttachedAccessory()
        handler.post(telemetryRunnable)
    }

    override fun onPause() {
        handler.removeCallbacks(telemetryRunnable)
        super.onPause()
    }

    private fun updateTelemetry() {
        val currentRendered = decoder.renderFrameCount
        val fps = currentRendered - lastRenderFrameCount
        lastRenderFrameCount = currentRendered

        val decoderName = decoder.activeDecoderName
        val decodeLatency = String.format("%.2f", decoder.averageDecodeTimeMs)
        val decoderDrops = decoder.droppedFrameCount
        val usbDrops = session.usbVideoDrops
        val vsync = if (decoder.vsyncEnabled) "ON (Smooth)" else "OFF (Immediate)"
        val videoResolution = session.videoResolution
        val videoBitrate = session.videoBitrate
        val decoderOutput = decoder.outputResolution
        val surfaceResolution = "${surfaceView.width} x ${surfaceView.height}"

        val content = """
            [ telemetry HUD ]
            • Decoder: $decoderName
            • Video Resolution: $videoResolution
            • Video Bitrate: $videoBitrate
            • Decoder Output: $decoderOutput
            • Surface Size: $surfaceResolution
            • VSync Sync: $vsync
            • Render FPS: $fps fps
            • Decoded Frames: $currentRendered
            • Decoder Drops: $decoderDrops
            • USB Queue Drops: $usbDrops
            • Decode Latency: $decodeLatency ms
        """.trimIndent()

        telemetryText.text = content
        updateOverlayVisibility()
    }

    private fun updateOverlayVisibility() {
        toggleCard.visibility = if (overlaysVisible) View.VISIBLE else View.GONE
        telemetryCard.visibility =
            if (overlaysVisible && status.visibility == View.GONE) View.VISIBLE else View.GONE
    }

    private fun reconnectAttachedAccessory() {
        if (!session.isOpen) usbManager.accessoryList?.firstOrNull()?.let(::requestOrOpen)
    }

    private fun requestOrOpen(accessory: UsbAccessory) {
        if (usbManager.hasPermission(accessory)) {
            open(accessory)
        } else {
            showStatus("Waiting for USB accessory permission", false)
            val permissionIntent = PendingIntent.getBroadcast(
                this, 0, Intent(ACTION_USB_PERMISSION).setPackage(packageName), PendingIntent.FLAG_IMMUTABLE,
            )
            usbManager.requestPermission(accessory, permissionIntent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.accessory()?.let(::requestOrOpen)
    }

    private fun open(accessory: UsbAccessory) {
        if (session.isOpen) return
        val bounds = screenBounds()
        session.open(accessory, maxOf(bounds.width(), bounds.height()), minOf(bounds.width(), bounds.height()))
    }

    @Suppress("DEPRECATION")
    private fun configureFullscreen() {
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
    }

    private fun registerAccessoryReceiver() {
        ContextCompat.registerReceiver(
            this,
            receiver,
            IntentFilter(ACTION_USB_PERMISSION),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        ContextCompat.registerReceiver(
            this,
            receiver,
            IntentFilter(UsbManager.ACTION_USB_ACCESSORY_DETACHED),
            ContextCompat.RECEIVER_EXPORTED,
        )
    }

    private fun screenBounds(): Rect =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            windowManager.currentWindowMetrics.bounds
        } else {
            @Suppress("DEPRECATION")
            val size = Point().also(windowManager.defaultDisplay::getRealSize)
            Rect(0, 0, size.x, size.y)
        }

    private fun showStatus(message: String, isStreaming: Boolean) = runOnUiThread {
        if (message == "Waiting for display surface" && surfaceView.holder.surface.isValid) {
            return@runOnUiThread
        }
        status.text = message
        status.visibility = if (isStreaming) View.GONE else View.VISIBLE
        updateOverlayVisibility()
        if (isStreaming) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setTurnScreenOn(true)
            } else {
                @Suppress("DEPRECATION")
                window.addFlags(WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
            }
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setTurnScreenOn(false)
            } else {
                @Suppress("DEPRECATION")
                window.clearFlags(WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
            }
        }
        if (message == "Waiting for USB cable" || message == "Connection timeout") {
            handler.postDelayed({
                reconnectAttachedAccessory()
            }, 1000)
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        session.updateSurface(holder.surface)
        reconnectAttachedAccessory()
    }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) =
        session.updateSurface(holder.surface)
    override fun surfaceDestroyed(holder: SurfaceHolder) {
        session.updateSurface(null)
        session.close()
        showStatus("Waiting for display surface", false)
    }

    override fun onDestroy() {
        unregisterReceiver(receiver)
        session.close()
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun Intent.accessory(): UsbAccessory? =
        getParcelableExtra(UsbManager.EXTRA_ACCESSORY) as? UsbAccessory

    companion object {
        private const val ACTION_USB_PERMISSION = "dev.andmon.receiver.USB_PERMISSION"
    }
}
