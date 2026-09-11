import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'blade_dynamics_service.dart';

/// 影片的基本資料（原生 `probe` 回來的）。
class BladeVideoInfo {
  final double durationS;
  final int width;
  final int height;
  final int rotationDeg;

  /// 錄製幀率；metadata 沒寫就是 null（很多手機不寫）。
  final double? frameRate;

  const BladeVideoInfo({
    required this.durationS,
    required this.width,
    required this.height,
    required this.rotationDeg,
    this.frameRate,
  });

  /// 規格 §10.3：怠速側視影片至少 2 圈完整轉動；12 rpm 一圈 5 秒，抓 10 秒。
  static const double minUsefulS = 10.0;

  bool get longEnough => durationS >= minUsefulS;
}

/// 影片讀不了時給使用者看的原因。
class BladeVideoError implements Exception {
  final String message;
  const BladeVideoError(this.message);
  @override
  String toString() => message;
}

/// 葉片動態層的裝置端抽幀（原生端：`android/.../BladeVideoFrames.kt`）。
///
/// 這是 `BladeFrameExtractor` 注入點的實作。Flutter 沒有純 Dart 的 H.264／HEVC
/// 解碼器，所以走 platform channel 到 `MediaMetadataRetriever`；只抽**少數幾幀**
/// （每次葉片通過六點鐘各一幀，時刻由音軌算出），不是逐幀。
///
/// **目前只有 Android。** 其他平台 `isSupported` 為 false，[extract] 直接回 null
/// ——`analyzeFrames` 對 null 的定義是「這一幀抽不到、其他幀照算」，所以在
/// 桌面測試或 iOS 上動態層會安靜地退回「未進行」，不會炸。iOS 要補
/// `AVAssetImageGenerator`，等 `ios/` 目錄建立時一起。
class BladeVideoFrames {
  BladeVideoFrames._();

  @visibleForTesting
  static const MethodChannel channel = MethodChannel('com.induspect/blade_video');

  /// 幀的長邊上限。幾何層的工作尺度是 1024（`workSide`），留一點餘裕給下採樣；
  /// 再大只是多花解碼時間與記憶體——4K 一幀全尺寸約 33 MB。
  static const int defaultMaxSide = 1280;

  /// 原生實作只有 Android。`kIsWeb` 先擋：web 上 `defaultTargetPlatform` 也可能回 android。
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// `BladeFrameExtractor` 的實作。抽不到、解碼失敗、平台不支援都回 null，
  /// **不丟例外**——呼叫端（`analyzeFrames`）已經把 null 定義成「這一幀沒有」。
  static Future<Uint8List?> extract(String videoPath, double atSeconds,
      {int maxSide = defaultMaxSide}) async {
    if (!isSupported) return null;
    if (!atSeconds.isFinite || atSeconds < 0) return null;
    try {
      final r = await channel.invokeMethod<dynamic>('frameAt', <String, dynamic>{
        'path': videoPath,
        'atMs': (atSeconds * 1000).round(),
        'maxSide': maxSide,
      });
      return bytesOf(r);
    } on PlatformException {
      return null; // 找不到檔、解碼失敗：這一幀沒有，其他幀照算
    } on MissingPluginException {
      return null; // 原生端沒註冊（例如單元測試環境）
    }
  }

  /// 給 `analyzeSession(frameExtractor: …)` 用的 tear-off 形狀；
  /// 平台不支援時回 null，讓服務層照原本的路寫「尚未接上」。
  static BladeFrameExtractor? get extractorOrNull =>
      isSupported ? (path, at) => extract(path, at) : null;

  /// 影片基本資料。讀不了會丟 [BladeVideoError]（這裡要講原因，不像 extract 可以安靜）。
  static Future<BladeVideoInfo> probe(String videoPath) async {
    if (!isSupported) {
      throw const BladeVideoError('此平台尚未接上原生影片解碼（目前僅 Android）');
    }
    final dynamic r;
    try {
      r = await channel.invokeMethod<dynamic>('probe', <String, dynamic>{'path': videoPath});
    } on PlatformException catch (e) {
      throw BladeVideoError(switch (e.code) {
        'NO_FILE' => '找不到影片檔',
        'BAD_ARGS' => '影片路徑為空',
        _ => '影片讀不了：${e.message ?? e.code}',
      });
    } on MissingPluginException {
      throw const BladeVideoError('原生影片解碼未註冊');
    }
    if (r is! Map) throw const BladeVideoError('影片資料格式不對');
    final m = r.cast<Object?, Object?>();
    final durationMs = (m['durationMs'] as num?)?.toDouble() ?? 0;
    return BladeVideoInfo(
      durationS: durationMs / 1000.0,
      width: (m['width'] as num?)?.toInt() ?? 0,
      height: (m['height'] as num?)?.toInt() ?? 0,
      rotationDeg: (m['rotation'] as num?)?.toInt() ?? 0,
      frameRate: (m['frameRate'] as num?)?.toDouble(),
    );
  }

  /// 原生回來可能是 Uint8List（StandardMessageCodec 的 typed data）或 List<int>。
  @visibleForTesting
  static Uint8List? bytesOf(dynamic r) {
    if (r == null) return null;
    if (r is Uint8List) return r.isEmpty ? null : r;
    if (r is List) {
      if (r.isEmpty) return null;
      return Uint8List.fromList(r.cast<int>());
    }
    return null;
  }
}
