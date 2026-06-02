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
import android.widget.FrameLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat

class MainActivity : AppCompatActivity(), SurfaceHolder.Callback {
    private lateinit var usbManager: UsbManager
    private lateinit var session: AccessorySession
    private lateinit var status: TextView
    private lateinit var surfaceView: SurfaceView

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                ACTION_USB_PERMISSION -> {
                    val accessory = intent.accessory()
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false) && accessory != null) {
                        open(accessory)
                    } else {
                        showStatus("USB accessory permission denied")
                    }
                }
                UsbManager.ACTION_USB_ACCESSORY_DETACHED -> {
                    session.close()
                    showStatus("Waiting for USB cable")
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        configureFullscreen()

        status = TextView(this).apply {
            text = getString(R.string.status_waiting)
            setTextColor(0xffffffff.toInt())
            textSize = 22f
            gravity = Gravity.CENTER
        }
        surfaceView = SurfaceView(this)
        setContentView(FrameLayout(this).apply {
            setBackgroundColor(0xff000000.toInt())
            addView(surfaceView, FrameLayout.LayoutParams(-1, -1))
            addView(status, FrameLayout.LayoutParams(-1, -1))
        })
        surfaceView.holder.addCallback(this)

        usbManager = getSystemService(USB_SERVICE) as UsbManager
        session = AccessorySession(usbManager, HevcSurfaceDecoder(), ::showStatus)
        registerAccessoryReceiver()
        intent.accessory()?.let(::requestOrOpen) ?: usbManager.accessoryList?.firstOrNull()?.let(::requestOrOpen)
    }

    override fun onResume() {
        super.onResume()
        reconnectAttachedAccessory()
    }

    private fun reconnectAttachedAccessory() {
        if (!session.isOpen) usbManager.accessoryList?.firstOrNull()?.let(::requestOrOpen)
    }

    private fun requestOrOpen(accessory: UsbAccessory) {
        if (usbManager.hasPermission(accessory)) {
            open(accessory)
        } else {
            showStatus("Waiting for USB accessory permission")
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

    private fun showStatus(message: String) = runOnUiThread {
        if (message == "Waiting for display surface" && surfaceView.holder.surface.isValid) {
            return@runOnUiThread
        }
        status.text = message
        status.visibility = if (message.startsWith("Streaming")) View.GONE else View.VISIBLE
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
        showStatus("Waiting for display surface")
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
