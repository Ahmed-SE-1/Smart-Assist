package com.example.smart_home

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

                        val width = call.argument<Int>("width") ?: 0
                        val height = call.argument<Int>("height") ?: 0
                        val bytesPerRow = call.argument<Int>("bytesPerRow") ?: width
                        @Suppress("UNCHECKED_CAST")
                        val planesRaw = call.argument<List<ByteArray>>("planes")

                        if (planesRaw == null || width <= 0 || height <= 0) {
                            result.success(mapOf("gesture" to "None", "confidence" to 0.0))
                            return@setMethodCallHandler
                        }

                        val detection = helper.detectFromYuv420(
                            planesRaw,
                            width,
                            height,
                            bytesPerRow,
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
