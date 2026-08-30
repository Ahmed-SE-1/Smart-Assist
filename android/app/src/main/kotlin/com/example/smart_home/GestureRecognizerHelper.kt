package com.example.smart_home

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizer
import com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizerResult
import java.io.ByteArrayOutputStream

/**
 * Wraps MediaPipe Gesture Recognizer for live camera frames from Flutter.
 * Model file: android/app/src/main/assets/gesture_recognizer.task
 */
class GestureRecognizerHelper(private val context: Context) {

    companion object {
        private const val MODEL_ASSET = "gesture_recognizer.task"
        private const val MIN_CONFIDENCE = 0.75f
    }

    private var gestureRecognizer: GestureRecognizer? = null

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
        planes: List<ByteArray>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
    ): Map<String, Any> {
        val recognizer = gestureRecognizer
            ?: return mapOf("gesture" to "None", "confidence" to 0.0)

        return try {
            val bitmap = yuv420ToBitmap(planes, width, height, bytesPerRow)
            val mpImage = BitmapImageBuilder(bitmap).build()

            val result = recognizer.recognize(mpImage)
            parseResult(result)
        } catch (e: Exception) {
            e.printStackTrace()
            mapOf("gesture" to "None", "confidence" to 0.0)
        }
    }

    private fun parseResult(result: GestureRecognizerResult): Map<String, Any> {
        val gestures = result.gestures()
        if (gestures.isEmpty()) {
            return mapOf("gesture" to "None", "confidence" to 0.0)
        }

        val topCategory = gestures[0].firstOrNull()
            ?: return mapOf("gesture" to "None", "confidence" to 0.0)

        val label = topCategory.categoryName()
        val score = topCategory.score().toDouble()

        return mapOf(
            "gesture" to label,
            "confidence" to score,
        )
    }

    private fun yuv420ToBitmap(
        planes: List<ByteArray>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
    ): Bitmap {
        if (planes.size < 3) {
            throw IllegalArgumentException("Expected 3 YUV planes")
        }

        val yBuffer = planes[0]
        val uBuffer = planes[1]
        val vBuffer = planes[2]

        // Reconstruct NV21 layout expected by YuvImage.
        val nv21 = ByteArray(width * height + (width * height / 2))
        System.arraycopy(yBuffer, 0, nv21, 0, minOf(yBuffer.size, width * height))

        var offset = width * height
        val chromaHeight = height / 2
        val chromaWidth = width / 2
        for (row in 0 until chromaHeight) {
            for (col in 0 until chromaWidth) {
                val uvIndex = row * bytesPerRow + col
                if (uvIndex < vBuffer.size && uvIndex < uBuffer.size && offset + 1 < nv21.size) {
                    nv21[offset++] = vBuffer[uvIndex]
                    nv21[offset++] = uBuffer[uvIndex]
                }
            }
        }

        val yuvImage = YuvImage(nv21, ImageFormat.NV21, width, height, null)
        val out = ByteArrayOutputStream()
        yuvImage.compressToJpeg(Rect(0, 0, width, height), 80, out)
        val jpegBytes = out.toByteArray()
        return BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.size)
    }

    fun close() {
        gestureRecognizer?.close()
        gestureRecognizer = null
    }
}
