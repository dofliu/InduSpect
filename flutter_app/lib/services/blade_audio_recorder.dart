import 'dart:io';

import 'package:record/record.dart';

/// 錄音參數的**單一來源**。
///
/// 兩個不能動的設定，理由是量測性的不是偏好問題：
///
/// - **一律未壓縮 PCM/WAV**。裝置上沒有純 Dart 的 AAC 解碼器，錄成 m4a 就離線
///   分析不了（`blade_audio_decode.dart` 只讀 PCM，而那是刻意的）。
/// - **自動增益、降噪、回音消除全部關掉**。這一層的判據是「同一段錄音裡三片
///   互比」，而自動增益會在錄音過程中改變增益，把那個比較的基準拆掉；降噪削掉的
///   正是我們要量的寬頻噪音（前緣侵蝕的徵兆）；回音消除是為語音設計的，會扭曲頻譜。
///   這三個在 `RecordConfig` 預設就是 false，這裡明寫是為了讓「不能開」有地方記錄。
class BladeRecordingSpec {
  BladeRecordingSpec._();

  /// 44.1 kHz 而不是 16 kHz：分析頻帶上限是 8 kHz，而 16 kHz 取樣的 Nyquist
  /// **剛好**是 8 kHz——抗鋸齒濾波器在 Nyquist 附近就開始滾降，會把 2–8 kHz 的
  /// 高頻占比量偏。44.1 kHz 讓 8 kHz 落在通帶內。
  static const int sampleRate = 44100;

  /// 單聲道。立體聲對這個判據沒有幫助，而且會讓檔案大一倍。
  static const int numChannels = 1;

  /// 建議的最短長度：要涵蓋 2–3 圈轉動才切得出三片。12 rpm 一圈 5 秒。
  static const Duration recommendedMin = Duration(seconds: 15);

  /// 上限只是避免不小心錄一小時；沒有分析上的理由。
  static const Duration hardMax = Duration(minutes: 3);

  /// **跨次趨勢要求取樣率一致**：`nperSegFor` 由「32 ms 視窗」推出分析窗長，
  /// 所以取樣率變了 bin 間距就變，窄頻峰的基線估計跟著變。同一台風機的歷次錄音
  /// 用同一個取樣率，比值才可比。錄下來的取樣率會存進 `qualityJson`。
  static const String comparabilityNote = '歷次錄音請用同一個取樣率，否則跨次比較的基準會變';
}

/// 錄音失敗的原因。**每一種都要有能顯示給人看的話**——現場沒有 log 可看。
enum BladeRecorderError {
  noPermission,
  wavUnsupported,
  startFailed,
  nothingRecorded,
  stopFailed,
}

/// 開始／結束錄音的結果。`path` 與 `error` 恰有一個非 null。
class BladeRecordingOutcome {
  final String? path;
  final BladeRecorderError? error;

  /// plugin 丟出來的原始訊息（若有）。只進 log 不直接給使用者看。
  final String? detail;

  const BladeRecordingOutcome.ok(String p)
      : path = p,
        error = null,
        detail = null;
  const BladeRecordingOutcome.fail(BladeRecorderError e, {this.detail})
      : path = null,
        error = e;

  bool get ok => path != null;

  String get message {
    switch (error) {
      case BladeRecorderError.noPermission:
        return '沒有麥克風權限，無法錄音。請到系統設定開啟後再試';
      case BladeRecorderError.wavUnsupported:
        return '這台裝置不支援錄成未壓縮 WAV。請改用手機的錄音程式錄 WAV／PCM，'
            '再用「附加音軌」選檔——壓縮格式在裝置上無法離線解碼';
      case BladeRecorderError.startFailed:
        return '錄音啟動失敗（麥克風可能被其他 App 佔用）';
      case BladeRecorderError.nothingRecorded:
        return '沒有錄到任何內容';
      case BladeRecorderError.stopFailed:
        return '結束錄音時失敗，這段錄音可能不完整';
      case null:
        return '';
    }
  }
}

/// 錄音的抽象。
///
/// **plugin 的 API 只出現在 [RecordPluginAudioRecorder] 一處。** 這個環境沒有實機
/// 也沒有 Flutter SDK，plugin 的行為驗不了；把它收在一個薄轉呼叫裡，
/// 流程邏輯（權限、編碼器支援、長度、解碼驗證）就全部測得到，
/// 而萬一 plugin 的 API 對不上，要改的也只有那一個檔案裡的那幾行。
abstract class BladeAudioRecorder {
  /// 要權限（必要時彈出系統對話框）
  Future<bool> hasPermission();

  /// 這台裝置能不能錄成未壓縮 WAV
  Future<bool> supportsWav();

  Future<void> start(String path);

  /// 回傳實際的檔案路徑（plugin 可能改寫），沒錄到回 null
  Future<String?> stop();

  /// 放棄這段錄音（會刪掉檔案）
  Future<void> cancel();

  Future<void> dispose();
}

/// 唯一碰 `record` plugin 的地方。
class RecordPluginAudioRecorder implements BladeAudioRecorder {
  RecordPluginAudioRecorder([AudioRecorder? recorder])
      : _rec = recorder ?? AudioRecorder();

  final AudioRecorder _rec;

  @override
  Future<bool> hasPermission() => _rec.hasPermission();

  @override
  Future<bool> supportsWav() => _rec.isEncoderSupported(AudioEncoder.wav);

  /// 錄音設定。**公開成常數是為了測得到**——「自動增益／降噪／回音消除一律關掉」
  /// 是量測上的要求（見 [BladeRecordingSpec]），而那種設定被人順手改開的話，
  /// 不會有任何報錯，只會讓逐片位準互比從此失去意義。有測試釘住它。
  static const RecordConfig wavConfig = RecordConfig(
    encoder: AudioEncoder.wav,
    sampleRate: BladeRecordingSpec.sampleRate,
    numChannels: BladeRecordingSpec.numChannels,
    autoGain: false,
    echoCancel: false,
    noiseSuppress: false,
  );

  @override
  Future<void> start(String path) => _rec.start(wavConfig, path: path);

  @override
  Future<String?> stop() => _rec.stop();

  @override
  Future<void> cancel() => _rec.cancel();

  @override
  Future<void> dispose() => _rec.dispose();
}

/// 錄音流程的編排：權限 → 編碼器支援 → 開始 → 結束 → 交出路徑。
///
/// 不做分析與存檔——那是呼叫端的事（附加音軌那條路已經有一套驗證與存檔，
/// 錄音只是換一個來源，不該長出第二套）。
class BladeRecordingController {
  BladeRecordingController({BladeAudioRecorder? recorder})
      : _rec = recorder ?? RecordPluginAudioRecorder();

  final BladeAudioRecorder _rec;
  DateTime? _startedAt;
  String? _path;

  bool get isRecording => _startedAt != null;

  /// 已錄多久。沒在錄時回 [Duration.zero]。
  Duration get elapsed =>
      _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);

  /// 長度是否達到建議值。**沒達到不阻止**——現場可能只有那幾秒，
  /// 而分析層自己會判「不可用」並說原因。
  bool get reachedRecommended => elapsed >= BladeRecordingSpec.recommendedMin;

  Future<BladeRecordingOutcome> start(String path) async {
    if (!await _rec.hasPermission()) {
      return const BladeRecordingOutcome.fail(BladeRecorderError.noPermission);
    }
    // **先問編碼器再開始**。不問的話裝置可能靜靜錄成壓縮格式，
    // 等到分析時才發現解不開——那時人已經離開現場了。
    if (!await _rec.supportsWav()) {
      return const BladeRecordingOutcome.fail(BladeRecorderError.wavUnsupported);
    }
    try {
      await _rec.start(path);
    } catch (e) {
      return BladeRecordingOutcome.fail(BladeRecorderError.startFailed,
          detail: '$e');
    }
    _startedAt = DateTime.now();
    _path = path;
    return BladeRecordingOutcome.ok(path);
  }

  Future<BladeRecordingOutcome> stop() async {
    if (_startedAt == null) {
      return const BladeRecordingOutcome.fail(
          BladeRecorderError.nothingRecorded);
    }
    _startedAt = null;
    String? out;
    try {
      out = await _rec.stop();
    } catch (e) {
      return BladeRecordingOutcome.fail(BladeRecorderError.stopFailed,
          detail: '$e');
    }
    // plugin 回 null 時退回我們指定的路徑：某些平台不回路徑但檔案是寫成功的
    final path = out ?? _path;
    if (path == null || path.isEmpty) {
      return const BladeRecordingOutcome.fail(
          BladeRecorderError.nothingRecorded);
    }
    return BladeRecordingOutcome.ok(path);
  }

  Future<void> cancel() async {
    _startedAt = null;
    try {
      await _rec.cancel();
    } catch (_) {
      // 放棄錄音失敗不需要讓使用者看到：檔案留著也不會被引用
    }
    final p = _path;
    if (p != null) {
      try {
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 刪不掉就算了，那是暫存目錄
      }
    }
  }

  Future<void> dispose() => _rec.dispose();
}
