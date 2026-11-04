package org.dragonpilot.opview

// The foreground service that holds the screen capture (Android requires one for MediaProjection,
// started before the projection is taken). MainActivity asks the user, then starts this with the
// answer; the capture itself is ScreenCapture.

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager
import java.io.File

/** what is shared between the activity and the service (one process) */
object CaptureHub {
    @Volatile var capture: ScreenCapture? = null
    @Volatile var listener: CaptureListener? = null

    /** the capture stopped without being asked (the user stopped it from Android's own controls) */
    @Volatile var onEnded: (() -> Unit)? = null

    // what the next start uses
    @Volatile var crop = CropRect(0, 0, 0, 0)
    @Volatile var bufferMs = 60_000L
    @Volatile var onStarted: ((Boolean) -> Unit)? = null
}

class RecorderService : Service() {
    private var projection: MediaProjection? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        val resultCode = intent?.getIntExtra(EXTRA_RESULT, Activity.RESULT_CANCELED) ?: Activity.RESULT_CANCELED
        @Suppress("DEPRECATION")
        val data: Intent? = intent?.getParcelableExtra(EXTRA_DATA)
        try {
            goForeground()
            val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val p = mpm.getMediaProjection(resultCode, data ?: throw IllegalStateException("no consent"))
                ?: throw IllegalStateException("no projection")
            projection = p
            // Android 14 wants this before the virtual display is made
            p.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    main.post {
                        if (CaptureHub.capture != null) {
                            CaptureHub.capture = null
                            CaptureHub.onEnded?.invoke()
                            stopSelf()
                        }
                    }
                }
            }, main)

            val metrics = DisplayMetrics()
            @Suppress("DEPRECATION")
            (getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.getRealMetrics(metrics)
            val listener = CaptureHub.listener ?: throw IllegalStateException("no listener")
            val capture = ScreenCapture(
                p, metrics.widthPixels, metrics.heightPixels, metrics.densityDpi,
                CaptureHub.crop, CaptureHub.bufferMs,
                File(cacheDir, "rec_segments"), clipDir(this), listener,
            )
            capture.start()
            CaptureHub.capture = capture
            CaptureHub.onStarted?.invoke(true)
        } catch (e: Exception) {
            Log.e("OPRivRecord", "start", e)
            CaptureHub.onStarted?.invoke(false)
            stopSelf()
        }
        CaptureHub.onStarted = null
        return START_NOT_STICKY
    }

    private fun goForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Recording", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "While OPRivView keeps the last minute or records a clip"
                },
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("OPRivView")
            .setContentText("Keeping the last minute for Record")
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onDestroy() {
        CaptureHub.capture?.stop()
        CaptureHub.capture = null
        projection = null
        super.onDestroy()
    }

    companion object {
        const val ACTION_STOP = "org.dragonpilot.opview.STOP_RECORDING"
        const val EXTRA_RESULT = "result"
        const val EXTRA_DATA = "data"
        private const val CHANNEL_ID = "recording"
        private const val NOTIFICATION_ID = 41

        fun clipDir(context: Context) = File(context.filesDir, "clips")
    }
}
