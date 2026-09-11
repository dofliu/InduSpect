package com.induspect.flutter_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 葉片動態層的原生抽幀（MediaMetadataRetriever）。見 BladeVideoFrames.kt。
        BladeVideoFrames.register(flutterEngine.dartExecutor.binaryMessenger)
    }
}
