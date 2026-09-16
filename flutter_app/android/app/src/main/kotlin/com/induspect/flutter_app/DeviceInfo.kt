package com.induspect.flutter_app

import android.app.ActivityManager
import android.content.Context
import android.os.StatFs
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 裝置資訊給 Tier 1b 端側模型的門檻判斷用：總記憶體、私有目錄剩餘空間。
 * Dart 端在 `lib/services/device_info_channel.dart`；查不到一律回 null，不丟。
 * 與 BladeVideoFrames.kt 一樣：CI 不建 APK，第一次實機要確認它 build 得起來。
 */
object DeviceInfo {
    private const val CHANNEL = "com.induspect/device"

    fun register(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "totalMemMb" -> result.success(totalMemMb(context))
                "freeBytes" -> result.success(freeBytes(context))
                else -> result.notImplemented()
            }
        }
    }

    private fun totalMemMb(context: Context): Long? = try {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        info.totalMem / (1024L * 1024L)
    } catch (_: Throwable) {
        null
    }

    private fun freeBytes(context: Context): Long? = try {
        StatFs(context.filesDir.absolutePath).availableBytes
    } catch (_: Throwable) {
        null
    }
}
