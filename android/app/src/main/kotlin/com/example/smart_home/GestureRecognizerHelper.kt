package com.example.smart_home

import android.content.Context
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Matrix
import android.util.Log
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizer
import com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizerResult

/**
 * Wraps MediaPipe Gesture Recognizer for live camera frames from Flutter.
 * Model file: android/app/src/main/assets/gesture_recognizer.task
 */
class GestureRecognizerHelper(private val context: Context) {

    data class YuvPlane(val bytes: ByteArray, val rowStride: Int, val pixelStride: Int)

    companion object {
        private const val MODEL_ASSET = "gesture_recognizer.task"
        private const val MIN_CONFIDENCE = 0.75f

        fun isValidFrame(planes: List<YuvPlane>, width: Int, height: Int, rotation: Int): Boolean {
            if (width <= 0 || height <= 0 || width.toLong() * height > Int.MAX_VALUE ||
                planes.size != 3 || rotation !in listOf(0, 90, 180, 270)) return false
            return planes.withIndex().all { (index, plane) ->
                val columns = if (index == 0) width.toLong() else (width.toLong() + 1) / 2
                val rows = if (index == 0) height.toLong() else (height.toLong() + 1) / 2
                // The final row may omit trailing padding. Require every sampled
                // byte, rather than rowStride * rows (which rejects valid buffers).
                val rowBytes = (columns - 1) * plane.pixelStride + 1
                val requiredBytes = (rows - 1) * plane.rowStride + rowBytes
                plane.rowStride > 0 && plane.pixelStride > 0 &&
                    plane.rowStride.toLong() >= rowBytes && requiredBytes <= plane.bytes.size
            }
        }
    }

    private var gestureRecognizer: GestureRecognizer? = null
    private val debug = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    private fun debugLog(message: String) {
        if (debug) Log.d("GestureRecognizer", message)
    }

    fun initialize(): Boolean {
        return try {
            val baseOptions = BaseOptions.builder()
                .setModelAssetPath(MODEL_ASSET)
                .build()

            val options = GestureRecognizer.GestureRecognizerOptions.builder()
                .setBaseOptions(baseOptions)
                .setRunningMode(RunningMode.IMAGE)
                .setMinHandDetectionConfidence(MIN_CONFIDENCE)
                .setMinHandPresenceConfidence(MIN_CONFIDENCE)
                .setMinTrackingConfidence(MIN_CONFIDENCE)
                .build()

            gestureRecognizer = GestureRecognizer.createFromOptions(context, options)
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    /**
     * Processes a YUV420 camera frame and returns the top gesture label + score.
     */
    fun detectFromYuv420(
        planes: List<YuvPlane>,
        width: Int,
        height: Int,
        rotation: Int,
    ): Map<String, Any> {
        val recognizer = gestureRecognizer
            ?: return mapOf("gesture" to "None", "confidence" to 0.0)

        return try {
            require(isValidFrame(planes, width, height, rotation)) { "Malformed YUV420 frame" }
            val bitmap = yuv420ToBitmap(planes, width, height)
            try {
                debugLog("Bitmap before rotation=${bitmap.width}x${bitmap.height}")
                val upright = rotateBitmap(bitmap, rotation)
                try {
                    debugLog("Bitmap after rotation=${upright.width}x${upright.height}")
                    val mpImage = BitmapImageBuilder(upright).build()
                    try {
                        parseResult(recognizer.recognize(mpImage))
                    } finally {
                        mpImage.close()
                    }
                } finally {
                    if (upright !== bitmap) upright.recycle()
                }
            } finally {
                bitmap.recycle()
            }
        } catch (e: Exception) {
            if (debug) Log.d("GestureRecognizer", "Inference failed; fallback None/0.0", e)
            mapOf("gesture" to "None", "confidence" to 0.0)
        }
    }

    private fun parseResult(result: GestureRecognizerResult): Map<String, Any> {
        val gestures = result.gestures()
        if (gestures.isEmpty()) {
            debugLog("No hand/category; fallback None/0.0")
            return mapOf("gesture" to "None", "confidence" to 0.0)
        }

        val topCategory = gestures[0].firstOrNull() ?: run {
            debugLog("No category; fallback None/0.0")
            return mapOf("gesture" to "None", "confidence" to 0.0)
        }

        val label = topCategory.categoryName()
        val score = topCategory.score().toDouble()
        debugLog("MediaPipe categoryName=$label score=$score")

        return mapOf(
            "gesture" to label,
            "confidence" to score,
        )
    }

    private fun yuv420ToBitmap(
        planes: List<YuvPlane>,
        width: Int,
        height: Int,
    ): Bitmap {
        val yPlane = planes[0]
        val uPlane = planes[1]
        val vPlane = planes[2]
        val pixels = IntArray(width * height)
        for (row in 0 until height) {
            for (col in 0 until width) {
                val y = yPlane.bytes[row * yPlane.rowStride + col * yPlane.pixelStride].toInt() and 0xff
                val u = (uPlane.bytes[(row / 2) * uPlane.rowStride + (col / 2) * uPlane.pixelStride].toInt() and 0xff) - 128
                val v = (vPlane.bytes[(row / 2) * vPlane.rowStride + (col / 2) * vPlane.pixelStride].toInt() and 0xff) - 128
                // BT.601 limited-range YUV -> RGB; no JPEG compression.
                val luminance = 298 * maxOf(0, y - 16)
                val r = ((luminance + 409 * v + 128) shr 8).coerceIn(0, 255)
                val g = ((luminance - 100 * u - 208 * v + 128) shr 8).coerceIn(0, 255)
                val b = ((luminance + 516 * u + 128) shr 8).coerceIn(0, 255)
                pixels[row * width + col] = (0xff shl 24) or (r shl 16) or (g shl 8) or b
            }
        }
        return Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
    }

    private fun rotateBitmap(bitmap: Bitmap, rotation: Int): Bitmap {
        if (rotation == 0) return bitmap
        // Camera image buffers are unmirrored. Preview mirroring does not apply
        // to inference. Matrix uses clockwise degrees in Android image coordinates.
        val matrix = Matrix().apply { postRotate(rotation.toFloat()) }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, false)
    }

    fun close() {
        gestureRecognizer?.close()
        gestureRecognizer = null
    }
}
