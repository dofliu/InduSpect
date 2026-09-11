package com.induspect.flutter_app

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/**
 * 葉片動態層的原生抽幀（Dart 端：`lib/services/blade_video_frames.dart`）。
 *
 * Flutter 沒有純 Dart 的 H.264／HEVC 解碼器，所以「在某個時刻抽一幀」一定要走原生。
 * 這裡用 `MediaMetadataRetriever`：它是 Android 內建、不需要額外相依，而且動態層
 * 只抽**少數幾幀**（每次葉片通過六點鐘各一幀，由音軌算出時刻），不是逐幀，
 * 所以不需要 MediaExtractor + MediaCodec 那套串流解碼。
 *
 * 兩個刻意的決定：
 * - `OPTION_CLOSEST` 而不是 `OPTION_CLOSEST_SYNC`：後者只回關鍵幀，可能離要求的時刻
 *   差到 1–2 秒——12 rpm 時 1 秒是 72°，六點鐘就不是六點鐘了。精確解碼慢一點可以接受。
 * - 一律在背景執行緒跑、單一 executor 串行：retriever 不是 thread-safe，
 *   而每幀解碼幾十到幾百毫秒，擋 UI thread 會掉幀。
 */
object BladeVideoFrames {
    private const val CHANNEL = "com.induspect/blade_video"
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "frameAt" -> frameAt(call, result)
                "probe" -> probe(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun pathOf(call: MethodCall, result: MethodChannel.Result): File? {
        val path = call.argument<String>("path")
        if (path.isNullOrEmpty()) {
            result.error("BAD_ARGS", "path 為空", null)
            return null
        }
        val f = File(path)
        if (!f.isFile) {
            result.error("NO_FILE", "找不到影片檔：$path", null)
            return null
        }
        return f
    }

    /** 在 atMs 抽一幀，長邊縮到 maxSide，回 JPEG 位元組；抽不到回 null。 */
    private fun frameAt(call: MethodCall, result: MethodChannel.Result) {
        val file = pathOf(call, result) ?: return
        val atMs = (call.argument<Number>("atMs") ?: 0).toLong()
        val maxSide = (call.argument<Number>("maxSide") ?: 1280).toInt()
        executor.execute {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(file.absolutePath)
                val bitmap = decodeScaled(retriever, atMs * 1000L, maxSide)
                if (bitmap == null) {
                    main.post { result.success(null) }
                    return@execute
                }
                val out = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.JPEG, 92, out)
                bitmap.recycle()
                val bytes = out.toByteArray()
                main.post { result.success(bytes) }
            } catch (e: Exception) {
                main.post { result.error("DECODE", e.message ?: e.toString(), null) }
            } finally {
                try { retriever.release() } catch (e: Exception) { /* release 失敗不影響結果 */ }
            }
        }
    }

    private fun decodeScaled(r: MediaMetadataRetriever, timeUs: Long, maxSide: Int): Bitmap? {
        val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
        val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
        val rotation = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        // 顯示尺寸：直拍的影片 metadata 寬高是感測器方向，旋轉 90/270 要對調
        val (dispW, dispH) = if (rotation == 90 || rotation == 270) h to w else w to h
        if (dispW <= 0 || dispH <= 0 || maxSide <= 0) {
            return r.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
        }
        val scale = minOf(1.0, maxSide.toDouble() / maxOf(dispW, dispH))
        val dstW = maxOf(1, Math.round(dispW * scale).toInt())
        val dstH = maxOf(1, Math.round(dispH * scale).toInt())
        // API 27+ 可以直接要縮放過的幀，省掉一張全尺寸 bitmap（4K 一幀約 33 MB）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            return r.getScaledFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST, dstW, dstH)
        }
        val full = r.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST) ?: return null
        if (full.width <= dstW && full.height <= dstH) return full
        val scaled = Bitmap.createScaledBitmap(full, dstW, dstH, true)
        if (scaled !== full) full.recycle()
        return scaled
    }

    /** 影片基本資料：長度、顯示寬高、旋轉、（有的話）錄製幀率。 */
    private fun probe(call: MethodCall, result: MethodChannel.Result) {
        val file = pathOf(call, result) ?: return
        executor.execute {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(file.absolutePath)
                val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                val fps: Double? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)?.toDoubleOrNull()
                } else null
                val (dispW, dispH) = if (rotation == 90 || rotation == 270) h to w else w to h
                val info = hashMapOf<String, Any?>(
                    "durationMs" to durationMs,
                    "width" to dispW,
                    "height" to dispH,
                    "rotation" to rotation,
                    "frameRate" to fps,
                )
                main.post { result.success(info) }
            } catch (e: Exception) {
                main.post { result.error("DECODE", e.message ?: e.toString(), null) }
            } finally {
                try { retriever.release() } catch (e: Exception) { /* release 失敗不影響結果 */ }
            }
        }
    }
}
