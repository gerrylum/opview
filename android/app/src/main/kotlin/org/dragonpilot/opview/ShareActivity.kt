package org.dragonpilot.opview

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Bundle

/**
 * Share › OPRivView from Google Maps (or anything sharing text): hands the shared text to the
 * running app and brings it to the front, or starts the app with it waiting.
 *
 * A separate, invisible activity because Android starts a share's target inside the sharing app's
 * task: MainActivity started there would be a second copy of the whole app (a second connection
 * to the comma). This one only passes the text on and finishes.
 */
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = sharedText(intent)
        if (text != null) {
            val deliver = ShareHub.deliver
            val task = ShareHub.taskId
            if (deliver != null && task >= 0) {
                deliver(text)
                try {
                    (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).moveTaskToFront(task, 0)
                } catch (e: Exception) {
                    open()
                }
            } else {
                ShareHub.pending = text
                open()
            }
        }
        finish()
    }

    private fun open() {
        startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun sharedText(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND) return null
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim().orEmpty()
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)?.trim().orEmpty()
        // Maps sometimes puts the place's name in the subject and only the link in the text
        val all = if (subject.isNotEmpty() && !text.contains(subject)) "$subject\n$text" else text
        return all.trim().ifEmpty { null }
    }
}

/** between ShareActivity and the running MainActivity */
object ShareHub {
    /** a share that arrived with the app not running, for Dart to take when it starts */
    @Volatile var pending: String? = null

    /** set while MainActivity's Flutter side is up: passes a share straight to Dart */
    @Volatile var deliver: ((String) -> Unit)? = null

    /** MainActivity's task, to bring it to the front */
    @Volatile var taskId: Int = -1
}
