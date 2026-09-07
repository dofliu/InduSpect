import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/services/blade_audio_recorder.dart';
import 'package:record/record.dart';

/// 假的錄音器。記錄被呼叫的順序，用來驗「不該呼叫的沒被呼叫」——
/// 例如編碼器不支援時**不能**已經開始錄了。
class FakeRecorder implements BladeAudioRecorder {
  FakeRecorder({
    this.permission = true,
    this.wav = true,
    this.startThrows = false,
    this.stopThrows = false,
    this.stopReturns,
    this.stopReturnsNull = false,
  });

  bool permission;
  bool wav;
  bool startThrows;
  bool stopThrows;
  String? stopReturns;
  bool stopReturnsNull;

  final calls = <String>[];
  String? startedPath;

  @override
  Future<bool> hasPermission() async {
    calls.add('hasPermission');
    return permission;
  }

  @override
  Future<bool> supportsWav() async {
    calls.add('supportsWav');
    return wav;
  }

  @override
  Future<void> start(String path) async {
    calls.add('start');
    startedPath = path;
    if (startThrows) throw StateError('mic busy');
  }

  @override
  Future<String?> stop() async {
    calls.add('stop');
    if (stopThrows) throw StateError('stop blew up');
    if (stopReturnsNull) return null;
    return stopReturns ?? startedPath;
  }

  @override
  Future<void> cancel() async => calls.add('cancel');

  @override
  Future<void> dispose() async => calls.add('dispose');
}

/// 錄音流程。plugin 本身無法在這個環境驗，所以它被收在
/// `RecordPluginAudioRecorder` 一處，而流程（權限、編碼器、長度、收尾）全部測得到。
void main() {
  group('錄音設定是量測要求，不是偏好', () {
    test('未壓縮 WAV、單聲道、自動增益／降噪／回音消除全關', () {
      const c = RecordPluginAudioRecorder.wavConfig;
      expect(c.encoder, AudioEncoder.wav,
          reason: '裝置上沒有純 Dart 的 AAC 解碼器，錄成壓縮格式就離線分析不了');
      expect(c.numChannels, 1);
      expect(c.autoGain, isFalse,
          reason: '自動增益會在錄音過程中改變增益，把三片互比的基準拆掉');
      expect(c.noiseSuppress, isFalse,
          reason: '降噪削掉的正是我們要量的寬頻噪音（前緣侵蝕的徵兆）');
      expect(c.echoCancel, isFalse, reason: '回音消除為語音設計，會扭曲頻譜');
    });

    test('取樣率讓 8 kHz 落在通帶內，而不是剛好在 Nyquist 上', () {
      // 分析頻帶上限 8 kHz；16 kHz 取樣的 Nyquist 剛好是 8 kHz，
      // 抗鋸齒濾波器會在那裡開始滾降，把高頻占比量偏
      expect(BladeRecordingSpec.sampleRate, greaterThan(16000));
      expect(BladeRecordingSpec.sampleRate / 2, greaterThan(8000));
    });

    test('建議長度足以涵蓋 2–3 圈（12 rpm 一圈 5 秒）', () {
      expect(BladeRecordingSpec.recommendedMin.inSeconds,
          greaterThanOrEqualTo(15));
      expect(BladeRecordingSpec.hardMax,
          greaterThan(BladeRecordingSpec.recommendedMin));
    });
  });

  group('開始錄音的守門', () {
    test('沒有麥克風權限 → 明確失敗，而且沒有開始錄', () async {
      final fake = FakeRecorder(permission: false);
      final c = BladeRecordingController(recorder: fake);
      final r = await c.start('/tmp/a.wav');
      expect(r.ok, isFalse);
      expect(r.error, BladeRecorderError.noPermission);
      expect(r.message, contains('麥克風'));
      expect(fake.calls, isNot(contains('start')));
      expect(c.isRecording, isFalse);
    });

    test('裝置不支援 WAV → **不開始錄**，並指向「用錄音程式錄 WAV」', () async {
      // 這條是重點：不先問就錄，裝置可能靜靜錄成壓縮格式，
      // 等到分析才發現解不開——那時人已經離開現場了
      final fake = FakeRecorder(wav: false);
      final c = BladeRecordingController(recorder: fake);
      final r = await c.start('/tmp/a.wav');
      expect(r.ok, isFalse);
      expect(r.error, BladeRecorderError.wavUnsupported);
      expect(fake.calls, isNot(contains('start')));
      expect(r.message, contains('WAV'));
    });

    test('編碼器的檢查在開始之前（順序也要對）', () async {
      final fake = FakeRecorder();
      final c = BladeRecordingController(recorder: fake);
      await c.start('/tmp/a.wav');
      expect(fake.calls, ['hasPermission', 'supportsWav', 'start']);
    });

    test('plugin 啟動時丟例外 → startFailed，原始訊息留在 detail 不直接顯示', () async {
      final fake = FakeRecorder(startThrows: true);
      final c = BladeRecordingController(recorder: fake);
      final r = await c.start('/tmp/a.wav');
      expect(r.ok, isFalse);
      expect(r.error, BladeRecorderError.startFailed);
      expect(r.detail, contains('mic busy'));
      expect(r.message, isNot(contains('mic busy')));
      expect(c.isRecording, isFalse, reason: '啟動失敗不能算成正在錄');
    });

    test('成功後 isRecording 為 true，且路徑照我們給的', () async {
      final fake = FakeRecorder();
      final c = BladeRecordingController(recorder: fake);
      final r = await c.start('/tmp/rec.wav');
      expect(r.ok, isTrue);
      expect(r.path, '/tmp/rec.wav');
      expect(fake.startedPath, '/tmp/rec.wav');
      expect(c.isRecording, isTrue);
    });
  });

  group('結束錄音', () {
    test('沒開始就停 → nothingRecorded，不呼叫 plugin', () async {
      final fake = FakeRecorder();
      final c = BladeRecordingController(recorder: fake);
      final r = await c.stop();
      expect(r.error, BladeRecorderError.nothingRecorded);
      expect(fake.calls, isEmpty);
    });

    test('plugin 回 null 時退回我們指定的路徑（有些平台不回路徑）', () async {
      final fake = FakeRecorder(stopReturnsNull: true);
      final c = BladeRecordingController(recorder: fake);
      await c.start('/tmp/rec.wav');
      final r = await c.stop();
      expect(r.ok, isTrue);
      expect(r.path, '/tmp/rec.wav');
    });

    test('plugin 回不同路徑時用它的（plugin 可能改寫副檔名）', () async {
      final fake = FakeRecorder(stopReturns: '/tmp/other.wav');
      final c = BladeRecordingController(recorder: fake);
      await c.start('/tmp/rec.wav');
      final r = await c.stop();
      expect(r.path, '/tmp/other.wav');
    });

    test('停止時丟例外 → stopFailed，並提醒錄音可能不完整', () async {
      final fake = FakeRecorder(stopThrows: true);
      final c = BladeRecordingController(recorder: fake);
      await c.start('/tmp/rec.wav');
      final r = await c.stop();
      expect(r.error, BladeRecorderError.stopFailed);
      expect(r.message, contains('不完整'));
      expect(c.isRecording, isFalse);
    });

    test('停止之後就不算在錄了（重複停止不會再打 plugin）', () async {
      final fake = FakeRecorder();
      final c = BladeRecordingController(recorder: fake);
      await c.start('/tmp/rec.wav');
      await c.stop();
      expect(c.isRecording, isFalse);
      final again = await c.stop();
      expect(again.error, BladeRecorderError.nothingRecorded);
      expect(fake.calls.where((x) => x == 'stop').length, 1);
    });
  });

  group('放棄錄音', () {
    test('會刪掉檔案，而且不算在錄', () async {
      final tmp = await Directory.systemTemp.createTemp('blade_rec_test');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      final path = '${tmp.path}/rec.wav';
      await File(path).writeAsBytes(List<int>.filled(64, 0));

      final fake = FakeRecorder();
      final c = BladeRecordingController(recorder: fake);
      await c.start(path);
      await c.cancel();
      expect(c.isRecording, isFalse);
      expect(await File(path).exists(), isFalse,
          reason: '放棄的錄音不該留在磁碟上占空間');
      expect(fake.calls, contains('cancel'));
    });

    test('plugin 的 cancel 丟例外時不會往外冒（放棄失敗不需要打擾使用者）', () async {
      final c = BladeRecordingController(recorder: _ThrowingCancel());
      await c.start('/tmp/nonexistent-dir-xyz/rec.wav');
      await c.cancel(); // 不該丟
      expect(c.isRecording, isFalse);
    });
  });

  group('長度提示', () {
    test('沒在錄時 elapsed 為零、未達建議長度', () {
      final c = BladeRecordingController(recorder: FakeRecorder());
      expect(c.elapsed, Duration.zero);
      expect(c.reachedRecommended, isFalse);
    });

    test('開始之後 elapsed 會走，但一開始還沒到建議長度', () async {
      final c = BladeRecordingController(recorder: FakeRecorder());
      await c.start('/tmp/rec.wav');
      expect(c.elapsed, lessThan(BladeRecordingSpec.recommendedMin));
      expect(c.reachedRecommended, isFalse,
          reason: '剛開始錄就說「長度足夠」會讓人錄太短');
    });
  });
}

class _ThrowingCancel extends FakeRecorder {
  @override
  Future<void> cancel() async => throw StateError('cancel failed');
}
