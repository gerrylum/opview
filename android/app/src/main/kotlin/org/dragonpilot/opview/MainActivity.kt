package org.dragonpilot.opview

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.Looper
import android.util.Rational
import android.view.View
import android.view.WindowManager
import androidx.annotation.RequiresApi
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity: FlutterActivity() {
    private val CHANNEL = "org.dragonpilot.opview/wake_lock"

    // screen brightness and installing an app update
    private val SYSTEM_CHANNEL = "org.dragonpilot.opview/system"
    private var systemChannel: MethodChannel? = null

    // Record (ScreenCapture, RecorderService)
    private val RECORDER_CHANNEL = "org.dragonpilot.opview/recorder"
    private var recorderChannel: MethodChannel? = null
    private var pendingStart: MethodChannel.Result? = null
    private val REQUEST_CAPTURE = 4101
    private val main = Handler(Looper.getMainLooper())

    // shrink to a picture-in-picture window on Home; Dart turns this on while connected
    private var pipEnabled = false

    private fun pipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    @RequiresApi(Build.VERSION_CODES.O)
    private fun pipParams(): PictureInPictureParams {
        val b = PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+: the system shrinks the app itself, with a smooth animation
            b.setAutoEnterEnabled(pipEnabled)
            b.setSeamlessResizeEnabled(true)
        }
        return b.build()
    }

    // Android 8-11: going Home calls this, and we ask for the window ourselves
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pipEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S && pipSupported()) {
            try {
                enterPictureInPictureMode(pipParams())
            } catch (e: Exception) {
                // the head unit refused (PiP turned off for this app): stay as we are
            }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        systemChannel?.invokeMethod("pipChanged", isInPictureInPictureMode)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "setKeepScreenOn") {
                val enabled = call.arguments as? Boolean ?: true
                if (enabled) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }

        setUpRecorder(MethodChannel(flutterEngine.dartExecutor.binaryMessenger, RECORDER_CHANNEL))

        val system = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_CHANNEL)
        systemChannel = system
        system.setMethodCallHandler { call, result ->
            when (call.method) {
                // whether going Home shrinks the app to a floating window
                "setPipEnabled" -> {
                    pipEnabled = call.arguments as? Boolean ?: false
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && pipSupported()) {
                        try {
                            setPictureInPictureParams(pipParams())
                        } catch (e: Exception) {
                            // not allowed on this head unit
                        }
                    }
                    result.success(pipSupported())
                }
                // 0..1 for this app's window only; below 0 hands brightness back to the system
                "setBrightness" -> {
                    val value = (call.arguments as? Number)?.toFloat() ?: -1f
                    val attrs = window.attributes
                    attrs.screenBrightness = if (value < 0f) {
                        WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    } else {
                        value.coerceIn(0.01f, 1f)
                    }
                    window.attributes = attrs
                    result.success(null)
                }
                // where to save a downloaded update: the folder update_paths.xml shares with the installer
                // (Dart's own temp folder is code_cache, which the FileProvider cannot share)
                "updateDir" -> {
                    val dir = File(cacheDir, "updates")
                    dir.mkdirs()
                    result.success(dir.absolutePath)
                }
                // hand a downloaded APK to Android's installer, which asks the user to confirm
                "installApk" -> {
                    val path = call.arguments as? String
                    if (path == null || !File(path).exists()) {
                        result.error("missing", "no APK at $path", null)
                    } else {
                        try {
                            val uri = FileProvider.getUriForFile(this, "$packageName.updates", File(path))
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("install", e.message, null)
                        }
                    }
                }
                // whether Android lets this app start an install (Android 8+: "Install unknown apps")
                "canInstallApks" -> {
                    result.success(Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls())
                }
                "openInstallSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // -- Record --

    /** a rect from Dart (physical pixels inside the app's view) on the display */
    private fun cropOnScreen(args: Map<*, *>): CropRect {
        val loc = IntArray(2)
        findViewById<View>(android.R.id.content)?.getLocationOnScreen(loc)
        fun n(k: String) = (args[k] as? Number)?.toInt() ?: 0
        return CropRect(n("x") + loc[0], n("y") + loc[1], n("w"), n("h"))
    }

    private fun setUpRecorder(channel: MethodChannel) {
        recorderChannel = channel
        CaptureHub.listener = object : CaptureListener {
            override fun onClipSaved(path: String, startWallMs: Long, durationMs: Long, bufferedMs: Long) {
                main.post {
                    recorderChannel?.invokeMethod("clipSaved", mapOf(
                        "path" to path, "startMs" to startWallMs, "durationMs" to durationMs, "bufferedMs" to bufferedMs,
                    ))
                }
            }

            override fun onClipFailed(message: String) {
                main.post { recorderChannel?.invokeMethod("clipFailed", message) }
            }
        }
        CaptureHub.onEnded = { recorderChannel?.invokeMethod("captureEnded", null) }

        channel.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
            when (call.method) {
                // ask Android for the screen (once per launch), then keep [bufferMs] ready
                "start" -> {
                    CaptureHub.bufferMs = (args["bufferMs"] as? Number)?.toLong() ?: 60_000L
                    CaptureHub.crop = cropOnScreen(args)
                    val running = CaptureHub.capture
                    if (running != null) {
                        running.bufferMs = CaptureHub.bufferMs
                        running.setCrop(CaptureHub.crop)
                        result.success(true)
                    } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP || pendingStart != null) {
                        result.success(false)
                    } else {
                        pendingStart = result
                        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                        try {
                            @Suppress("DEPRECATION")
                            startActivityForResult(mpm.createScreenCaptureIntent(), REQUEST_CAPTURE)
                        } catch (e: Exception) {
                            pendingStart = null
                            result.success(false)
                        }
                    }
                }
                "stop" -> {
                    stopService(Intent(this, RecorderService::class.java))
                    result.success(null)
                }
                "isCapturing" -> result.success(CaptureHub.capture != null)
                "setBuffer" -> {
                    val ms = (call.arguments as? Number)?.toLong() ?: 60_000L
                    CaptureHub.bufferMs = ms
                    CaptureHub.capture?.bufferMs = ms
                    result.success(null)
                }
                "setCrop" -> {
                    CaptureHub.crop = cropOnScreen(args)
                    CaptureHub.capture?.setCrop(CaptureHub.crop)
                    result.success(null)
                }
                "setPaused" -> {
                    // {paused, reason}, or a bare Boolean from an older Dart side
                    val paused = (args["paused"] as? Boolean) ?: (call.arguments as? Boolean) ?: false
                    CaptureHub.capture?.setPaused(paused, args["reason"] as? String ?: "")
                    result.success(null)
                }
                // returns how much of the clip is from before the tap (ms), or null without a capture
                "startClip" -> result.success(CaptureHub.capture?.startClip())
                "stopClip" -> {
                    CaptureHub.capture?.stopClip()
                    result.success(null)
                }
                "clipDir" -> {
                    val dir = RecorderService.clipDir(this)
                    dir.mkdirs()
                    result.success(dir.absolutePath)
                }
                // hand a clip to another app (Files, a messenger...)
                "share" -> {
                    val path = call.arguments as? String
                    try {
                        val uri = FileProvider.getUriForFile(this, "$packageName.updates", File(path ?: ""))
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "video/mp4"
                            putExtra(Intent.EXTRA_STREAM, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(Intent.createChooser(send, "Share clip").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("share", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CAPTURE) return
        val pending = pendingStart ?: return
        pendingStart = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            pending.success(false)
            return
        }
        CaptureHub.onStarted = { ok -> main.post { pending.success(ok) } }
        val intent = Intent(this, RecorderService::class.java)
            .putExtra(RecorderService.EXTRA_RESULT, resultCode)
            .putExtra(RecorderService.EXTRA_DATA, data)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
        } catch (e: Exception) {
            CaptureHub.onStarted = null
            pending.success(false)
        }
    }
}
