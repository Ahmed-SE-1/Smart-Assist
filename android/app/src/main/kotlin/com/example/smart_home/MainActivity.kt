package com.example.smart_home

import android.content.pm.ApplicationInfo
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.example.smart_home/gesture_recognizer"
    }

    private var gestureHelper: GestureRecognizerHelper? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> {
                        gestureHelper?.close()
                        gestureHelper = GestureRecognizerHelper(this)
                        result.success(gestureHelper?.initialize() == true)
                    }

                    "detect" -> {
                        val helper = gestureHelper
                        if (helper == null) {
                            result.success(mapOf("gesture" to "None", "confidence" to 0.0))
                            return@setMethodCallHandler
                        }

                        // Read untrusted channel values without unchecked generic casts.
                        val args = call.arguments as? Map<*, *>
                        val width = args?.get("width") as? Int ?: 0
                        val height = args?.get("height") as? Int ?: 0
                        val rotation = args?.get("rotation") as? Int ?: -1
                        val planesRaw = args?.get("planes") as? List<*>
                        val planes = planesRaw?.mapNotNull { raw ->
                            val plane = raw as? Map<*, *> ?: return@mapNotNull null
                            val bytes = plane["bytes"] as? ByteArray ?: return@mapNotNull null
                            val rowStride = plane["bytesPerRow"] as? Int ?: return@mapNotNull null
                            val pixelStride = plane["bytesPerPixel"] as? Int ?: return@mapNotNull null
                            GestureRecognizerHelper.YuvPlane(bytes, rowStride, pixelStride)
                        }
                        val debug = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
                        if (debug) {
                            Log.d("GestureRecognizer", "Received ${width}x$height rotation=$rotation " +
                                "lens=${args?.get("lensDirection")} sensor=${args?.get("sensorOrientation")}")
                            planes?.forEachIndexed { index, plane ->
                                Log.d("GestureRecognizer", "Plane $index rowStride=${plane.rowStride} " +
                                    "pixelStride=${plane.pixelStride} bytes=${plane.bytes.size}")
                            }
                        }

                        if (args?.get("format") != "yuv420" || planesRaw?.size != 3 ||
                            planes == null || !GestureRecognizerHelper.isValidFrame(planes, width, height, rotation)) {
                            if (debug) Log.d("GestureRecognizer", "Malformed YUV420 frame; fallback None/0.0")
                            result.success(mapOf("gesture" to "None", "confidence" to 0.0))
                            return@setMethodCallHandler
                        }

                        val detection = helper.detectFromYuv420(
                            planes,
                            width,
                            height,
                            rotation,
                        )
                        result.success(detection)
                    }

                    "dispose" -> {
                        gestureHelper?.close()
                        gestureHelper = null
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        gestureHelper?.close()
        gestureHelper = null
        super.onDestroy()
    }
}
