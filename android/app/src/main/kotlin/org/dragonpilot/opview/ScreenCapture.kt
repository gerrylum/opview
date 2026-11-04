package org.dragonpilot.opview

// Record with the overlay burned in (design: claude/oprivview-record-gallery-design.md).
//
// MediaProjection mirrors the screen into a SurfaceTexture; each frame is cropped on the GPU to
// the camera area and status bar (the rect Dart sends) and drawn into a MediaCodec H.264
// encoder. Its output goes into short segment files on keyframes. While no clip is running only
// the last [bufferMs] is kept; a clip is the segments from that far back to the stop, joined into
// one mp4 without re-encoding. A clip stops by itself at [MAX_CLIP_US].

import android.graphics.SurfaceTexture
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.projection.MediaProjection
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

private const val TAG = "OPRivRecord"

const val MAX_CLIP_US = 5L * 60 * 1_000_000      // clips stop at 5:00
private const val SEGMENT_US = 10L * 1_000_000   // a new segment file at the first keyframe after 10 s
private const val MAX_WIDTH = 1280
private const val BIT_RATE = 4_000_000
private const val FRAME_RATE = 30
private const val KEYFRAME_S = 2

/** a cropped region of the display, in physical pixels */
data class CropRect(val x: Int, val y: Int, val w: Int, val h: Int)

/** what the recorder tells the app */
interface CaptureListener {
    /** a clip was written: the file, when it starts (wall clock ms), its length, how much came from before the tap */
    fun onClipSaved(path: String, startWallMs: Long, durationMs: Long, bufferedMs: Long)
    fun onClipFailed(message: String)
}

class ScreenCapture(
    private val projection: MediaProjection,
    private val displayW: Int,
    private val displayH: Int,
    private val densityDpi: Int,
    private var crop: CropRect,
    bufferMs: Long,
    private val segmentDir: File,
    private val clipDir: File,
    private val listener: CaptureListener,
) {
    private val glThread = HandlerThread("OPRivRecordGL").apply { start() }
    private val gl = Handler(glThread.looper)
    private var drainThread: Thread? = null
    @Volatile private var running = false

    // frames are dropped (nothing new encoded) while the camera view is not on screen
    @Volatile var paused = false

    private var encoder: MediaCodec? = null
    private var display: VirtualDisplay? = null
    private var texture: SurfaceTexture? = null
    private var textureSurface: Surface? = null
    private var egl: Egl? = null
    private var program = 0
    private var texId = 0
    private val texMatrix = FloatArray(16)

    private val segments = SegmentWriter(segmentDir).apply { setBuffer(bufferMs * 1000) }

    /** how much is kept from before a tap on Record */
    var bufferMs: Long = bufferMs
        set(value) {
            field = value
            segments.setBuffer(value * 1000)
        }
    private var outW = 0
    private var outH = 0

    fun start() {
        segmentDir.mkdirs()
        segmentDir.listFiles()?.forEach { it.delete() }  // left over from a crash
        clipDir.mkdirs()
        running = true
        gl.post { setUpOnGl() }
    }

    fun stop() {
        running = false
        segments.abandonClip()
        gl.post {
            try {
                display?.release()
                textureSurface?.release()
                texture?.release()
                encoder?.signalEndOfInputStream()
            } catch (e: Exception) {
                Log.w(TAG, "stop", e)
            }
        }
        drainThread?.join(2000)
        gl.post {
            try {
                encoder?.stop()
                encoder?.release()
            } catch (e: Exception) {
                Log.w(TAG, "release encoder", e)
            }
            egl?.release()
            segments.closeAll()
            segmentDir.listFiles()?.forEach { it.delete() }
            glThread.quitSafely()
        }
        try {
            projection.stop()
        } catch (e: Exception) {
            Log.w(TAG, "projection stop", e)
        }
    }

    fun setCrop(rect: CropRect) {
        gl.post { crop = clampCrop(rect) }
    }

    /** start a clip with what is buffered; returns how much from before now it includes (ms) */
    fun startClip(): Long = segments.startClip(nowUs(), bufferMs * 1000) / 1000

    fun stopClip() {
        segments.requestStop()
        requestKeyframe()
    }

    val recording: Boolean get() = segments.recording

    // -- set up --

    private fun clampCrop(r: CropRect): CropRect {
        val x = r.x.coerceIn(0, displayW - 2)
        val y = r.y.coerceIn(0, displayH - 2)
        return CropRect(x, y, r.w.coerceIn(2, displayW - x), r.h.coerceIn(2, displayH - y))
    }

    private fun setUpOnGl() {
        try {
            crop = clampCrop(crop)
            // the output keeps the first crop's shape, at most MAX_WIDTH wide, even sizes for the encoder
            val scale = minOf(1.0, MAX_WIDTH.toDouble() / crop.w)
            outW = ((crop.w * scale).toInt() / 2) * 2
            outH = ((crop.h * scale).toInt() / 2) * 2

            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, outW, outH).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
                setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, KEYFRAME_S)
                // the screen often stands still: repeat the last frame so keyframes keep coming
                setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 1_000_000L / 10)
            }
            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val input = enc.createInputSurface()
            enc.start()
            encoder = enc

            val e = Egl(input)
            egl = e
            e.makeCurrent()
            program = buildProgram()
            texId = createOesTexture()
            val st = SurfaceTexture(texId)
            st.setDefaultBufferSize(displayW, displayH)
            st.setOnFrameAvailableListener({ onFrame() }, gl)
            texture = st
            val surface = Surface(st)
            textureSurface = surface

            display = projection.createVirtualDisplay(
                "OPRivViewRecord", displayW, displayH, densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, null,
            )

            drainThread = Thread({ drain(enc) }, "OPRivRecordDrain").apply { start() }
        } catch (e: Exception) {
            Log.e(TAG, "set up", e)
            listener.onClipFailed("Could not start recording: ${e.message}")
        }
    }

    private fun requestKeyframe() {
        try {
            encoder?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (e: Exception) {
            Log.w(TAG, "keyframe", e)
        }
    }

    // -- each frame --

    private fun onFrame() {
        val st = texture ?: return
        val e = egl ?: return
        try {
            st.updateTexImage()
            if (paused || !running) return
            st.getTransformMatrix(texMatrix)
            GLES20.glViewport(0, 0, outW, outH)
            draw()
            e.setPresentationTime(st.timestamp)
            e.swapBuffers()
        } catch (ex: Exception) {
            Log.w(TAG, "frame", ex)
        }
    }

    private fun draw() {
        val c = crop
        // texture coordinates of the crop: x left to right, y bottom to top (GL), before the
        // SurfaceTexture's own transform
        val x0 = c.x.toFloat() / displayW
        val x1 = (c.x + c.w).toFloat() / displayW
        val y0 = 1f - (c.y + c.h).toFloat() / displayH
        val y1 = 1f - c.y.toFloat() / displayH
        val tex = floatArrayOf(x0, y0, x1, y0, x0, y1, x1, y1)
        GLES20.glUseProgram(program)
        val aPos = GLES20.glGetAttribLocation(program, "aPos")
        val aTex = GLES20.glGetAttribLocation(program, "aTex")
        val uMat = GLES20.glGetUniformLocation(program, "uTexMatrix")
        GLES20.glUniformMatrix4fv(uMat, 1, false, texMatrix, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texId)
        GLES20.glEnableVertexAttribArray(aPos)
        GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 0, QUAD)
        GLES20.glEnableVertexAttribArray(aTex)
        GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 0, floats(tex))
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    // -- encoder output --

    private fun drain(enc: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val index = try {
                enc.dequeueOutputBuffer(info, 50_000)
            } catch (e: Exception) {
                break
            }
            when {
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> segments.format = enc.outputFormat
                index >= 0 -> {
                    val buf = enc.getOutputBuffer(index)
                    val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (buf != null && !config && info.size > 0) {
                        val done = segments.write(buf, info)
                        if (done != null) joinClip(done)
                    }
                    enc.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
                !running && index == MediaCodec.INFO_TRY_AGAIN_LATER -> break
            }
        }
    }

    private fun joinClip(clip: FinishedClip) {
        Thread({
            try {
                val out = File(clipDir, "${clip.startWallMs}.mp4")
                val durationUs = joinSegments(clip.files, out)
                writeThumbnail(out, File(clipDir, "${clip.startWallMs}.jpg"))
                listener.onClipSaved(out.absolutePath, clip.startWallMs, durationUs / 1000, clip.bufferedUs / 1000)
            } catch (e: Exception) {
                Log.e(TAG, "join", e)
                listener.onClipFailed("Could not save the clip: ${e.message}")
            } finally {
                segments.release(clip.files)
            }
        }, "OPRivRecordJoin").start()
    }

    // -- GL helpers --

    private fun buildProgram(): Int {
        fun shader(type: Int, src: String): Int {
            val s = GLES20.glCreateShader(type)
            GLES20.glShaderSource(s, src)
            GLES20.glCompileShader(s)
            return s
        }
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, shader(GLES20.GL_VERTEX_SHADER, VERTEX))
        GLES20.glAttachShader(p, shader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT))
        GLES20.glLinkProgram(p)
        return p
    }

    private fun createOesTexture(): Int {
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, ids[0])
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        return ids[0]
    }

    companion object {
        private const val VERTEX = """
            attribute vec4 aPos;
            attribute vec4 aTex;
            uniform mat4 uTexMatrix;
            varying vec2 vTex;
            void main() {
                gl_Position = aPos;
                vTex = (uTexMatrix * aTex).xy;
            }
        """
        private const val FRAGMENT = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTex;
            uniform samplerExternalOES sTex;
            void main() {
                gl_FragColor = texture2D(sTex, vTex);
            }
        """
        private val QUAD = floats(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))

        private fun floats(a: FloatArray): FloatBuffer =
            ByteBuffer.allocateDirect(a.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
                put(a)
                position(0)
            }

        fun nowUs(): Long = System.nanoTime() / 1000
    }
}

/** an EGL context drawing into the encoder's input surface */
private class Egl(surface: Surface) {
    private val display: EGLDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    private val context: EGLContext
    private val eglSurface: EGLSurface

    init {
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1)) { "eglInitialize" }
        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        check(EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, count, 0) && count[0] > 0) { "eglChooseConfig" }
        context = EGL14.eglCreateContext(
            display, configs[0], EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        eglSurface = EGL14.eglCreateWindowSurface(display, configs[0], surface, intArrayOf(EGL14.EGL_NONE), 0)
    }

    fun makeCurrent() {
        check(EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)) { "eglMakeCurrent" }
    }

    fun setPresentationTime(ns: Long) {
        EGLExt.eglPresentationTimeANDROID(display, eglSurface, ns)
    }

    fun swapBuffers() {
        EGL14.eglSwapBuffers(display, eglSurface)
    }

    fun release() {
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        EGL14.eglDestroySurface(display, eglSurface)
        EGL14.eglDestroyContext(display, context)
        EGL14.eglTerminate(display)
    }

    companion object {
        private const val EGL_RECORDABLE_ANDROID = 0x3142
    }
}

/** a clip ready to be joined */
class FinishedClip(val files: List<File>, val startWallMs: Long, val bufferedUs: Long)

private class Segment(val file: File, val muxer: MediaMuxer, val track: Int, val firstUs: Long) {
    var lastUs = firstUs
    var samples = 0
}

private class Closed(val file: File, val firstUs: Long, val lastUs: Long)

/**
 * the encoder's output as segment files, each starting on a keyframe. Without a clip running only
 * the newest [bufferUs] is kept; with one, everything from its start is kept until it stops.
 * Called from the drain thread, except the clip calls (the app's thread): all under the lock.
 */
private class SegmentWriter(private val dir: File) {
    @Volatile var format: MediaFormat? = null
    private val lock = Object()
    private var current: Segment? = null
    private val closed = ArrayList<Closed>()
    private val held = HashSet<File>()   // being joined into a clip: not to be pruned
    private var counter = 0

    private var bufferUs = 0L
    private var clipFromUs = -1L   // first frame time of the running clip, or -1
    private var clipTapUs = 0L
    private var stopRequested = false

    val recording: Boolean get() = synchronized(lock) { clipFromUs >= 0 }

    fun setBuffer(us: Long) = synchronized(lock) {
        bufferUs = us
    }

    /** returns how much the clip includes from before now (µs) */
    fun startClip(nowUs: Long, bufferUs: Long): Long = synchronized(lock) {
        this.bufferUs = bufferUs
        if (clipFromUs >= 0) return@synchronized clipTapUs - clipFromUs
        // the oldest segment still kept covers the buffer (pruning keeps one that starts before it)
        // from the buffer's length back (the segment holding that moment is kept whole), or as far as there is
        val first = closed.firstOrNull()?.firstUs ?: current?.firstUs ?: nowUs
        clipFromUs = maxOf(first, nowUs - bufferUs).coerceAtMost(nowUs)
        clipTapUs = nowUs
        stopRequested = false
        clipTapUs - clipFromUs
    }

    fun requestStop() = synchronized(lock) {
        if (clipFromUs >= 0) stopRequested = true
    }

    fun abandonClip() = synchronized(lock) {
        clipFromUs = -1
        stopRequested = false
    }

    /** write one encoded frame; returns a clip when one has just ended */
    fun write(buf: ByteBuffer, info: MediaCodec.BufferInfo): FinishedClip? = synchronized(lock) {
        val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
        val t = info.presentationTimeUs
        var finished: FinishedClip? = null
        // the 5 minute cap
        if (clipFromUs >= 0 && t - clipFromUs >= MAX_CLIP_US) stopRequested = true
        val cur = current
        if (key && (cur == null || t - cur.firstUs >= SEGMENT_US || stopRequested)) {
            closeCurrent()
            if (stopRequested && clipFromUs >= 0) finished = takeClip()
            current = openSegment(t)
        }
        val seg = current ?: return@synchronized finished  // no keyframe yet
        buf.position(info.offset)
        buf.limit(info.offset + info.size)
        seg.muxer.writeSampleData(seg.track, buf, info)
        seg.lastUs = t
        seg.samples++
        finished
    }

    private fun openSegment(t: Long): Segment? {
        val fmt = format ?: return null
        val file = File(dir, "seg_${counter++}.mp4")
        val muxer = MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val track = muxer.addTrack(fmt)
        muxer.start()
        return Segment(file, muxer, track, t)
    }

    private fun closeCurrent() {
        val seg = current ?: return
        current = null
        try {
            if (seg.samples > 0) {
                seg.muxer.stop()
                closed.add(Closed(seg.file, seg.firstUs, seg.lastUs))
            } else {
                seg.file.delete()
            }
            seg.muxer.release()
        } catch (e: Exception) {
            Log.w(TAG, "close segment", e)
            seg.file.delete()
        }
        prune()
    }

    private fun takeClip(): FinishedClip {
        val parts = closed.filter { it.lastUs >= clipFromUs }
        held.addAll(parts.map { it.file })
        val first = parts.firstOrNull()?.firstUs ?: clipFromUs
        val nowUs = ScreenCapture.nowUs()
        val startWallMs = System.currentTimeMillis() - (nowUs - first) / 1000
        val clip = FinishedClip(parts.map { it.file }, startWallMs, (clipTapUs - first).coerceAtLeast(0))
        clipFromUs = -1
        stopRequested = false
        return clip
    }

    // keep the segments a clip could still need: all of them during a clip, else enough to cover the buffer
    private fun prune() {
        if (clipFromUs >= 0) return
        val newest = closed.lastOrNull()?.lastUs ?: return
        val keepFrom = newest - bufferUs
        while (closed.size > 1 && closed[1].firstUs <= keepFrom) {
            val old = closed.removeAt(0)
            if (old.file !in held) old.file.delete()
        }
        if (bufferUs == 0L) {
            closed.filter { it.file !in held }.forEach { it.file.delete() }
            closed.removeAll { it.file !in held }
        }
    }

    /** a joined clip no longer needs its segments */
    fun release(files: List<File>) = synchronized(lock) {
        held.removeAll(files.toSet())
        val inBuffer = closed.map { it.file }.toSet()
        files.filter { it !in inBuffer }.forEach { it.delete() }
    }

    fun closeAll() = synchronized(lock) {
        closeCurrent()
        closed.clear()
    }
}

/** copy the samples of [parts] one after the other into [out]; returns the length (µs) */
fun joinSegments(parts: List<File>, out: File): Long {
    require(parts.isNotEmpty()) { "no video" }
    val muxer = MediaMuxer(out.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    var track = -1
    var firstUs = -1L
    var lastUs = 0L
    var wrote = false
    val buf = ByteBuffer.allocateDirect(4 * 1024 * 1024)
    val info = MediaCodec.BufferInfo()
    try {
        for (part in parts) {
            val ex = MediaExtractor()
            try {
                ex.setDataSource(part.absolutePath)
                if (ex.trackCount == 0) continue
                ex.selectTrack(0)
                if (track < 0) {
                    track = muxer.addTrack(ex.getTrackFormat(0))
                    muxer.start()
                }
                while (true) {
                    val size = ex.readSampleData(buf, 0)
                    if (size < 0) break
                    val t = ex.sampleTime
                    if (firstUs < 0) firstUs = t
                    // segments come from one encoder, so their times already run on; skip any overlap
                    val rel = t - firstUs
                    if (wrote && rel <= lastUs) {
                        ex.advance()
                        continue
                    }
                    val flags = if (ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                    info.set(0, size, rel, flags)
                    muxer.writeSampleData(track, buf, info)
                    lastUs = rel
                    wrote = true
                    ex.advance()
                }
            } finally {
                ex.release()
            }
        }
    } finally {
        if (track >= 0) muxer.stop()
        muxer.release()
    }
    if (track < 0) {
        out.delete()
        throw IllegalStateException("no video")
    }
    return lastUs
}

/** a frame from 1 s in (or the first) as the Gallery's thumbnail; missing is fine */
fun writeThumbnail(video: File, out: File) {
    val r = android.media.MediaMetadataRetriever()
    try {
        r.setDataSource(video.absolutePath)
        val frame = r.getFrameAtTime(1_000_000, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            ?: r.getFrameAtTime(0) ?: return
        val w = 480
        val h = (frame.height * w / frame.width.coerceAtLeast(1)).coerceAtLeast(1)
        val small = android.graphics.Bitmap.createScaledBitmap(frame, w, h, true)
        out.outputStream().use { small.compress(android.graphics.Bitmap.CompressFormat.JPEG, 82, it) }
    } catch (e: Exception) {
        Log.w(TAG, "thumbnail", e)
    } finally {
        try { r.release() } catch (_: Exception) {}
    }
}
