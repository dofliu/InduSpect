import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/services/blade_acoustic_service.dart';
import 'package:induspect_ai/services/blade_audio_decode.dart';
import 'package:induspect_ai/services/blade_geometry_compare.dart';

/// 聲音層對照 Python 原型（`blade_prototype/blade_proto/acoustics.py`）。
///
/// 兩段合成音軌，**兩個方向都測**：
///
/// 1. `blade_audio_healthy.wav` — 三片一致。驗「不誤報」。
/// 2. `blade_audio_eroded.wav` — 第 2 片 +4 dB 寬頻、第 3 片 1800 Hz 哨音。
///    驗「真的會報」，而且報在對的那一片。
///
/// 只測健康那組會漏掉「標記根本不會觸發」這種失敗；只測缺陷那組會漏掉誤報。
///
/// 參考值由 `blade_prototype/scripts/make_acoustic_fixture.py` 產生，**從寫出去的
/// WAV 讀回來之後才算**（含 int16 量化），所以與 Dart 端的輸入同源。
void main() {
  late Map<String, dynamic> ref;

  setUpAll(() {
    ref = jsonDecode(File('test/assets/blade_acoustic_reference.json')
        .readAsStringSync()) as Map<String, dynamic>;
  });

  BladeAcousticResult analyze(String name) {
    final ent = ref[name] as Map<String, dynamic>;
    final r = BladeAudioDecode.decodeWav(
        File('test/assets/${ent['wav']}').readAsBytesSync());
    expect(r.ok, isTrue, reason: r.message);
    return BladeAcousticService.analyzeSamples(r.clip!);
  }

  Map<String, dynamic> want(String name) =>
      (ref[name] as Map<String, dynamic>)['result'] as Map<String, dynamic>;

  group('轉動偵測（兩段都要對）', () {
    for (final name in ['healthy', 'eroded']) {
      test('$name：轉速、週期、信賴度、訊噪比與 Python 相同', () {
        final r = analyze(name);
        final w = want(name);
        expect(r.usable, w['usable']);
        expect(r.rpmFromAudio, closeTo(w['rpm_from_audio'] as double, 1e-9));
        expect(r.bladePassHz, closeTo(w['blade_pass_hz'] as double, 1e-9));
        expect(r.rotorHz, closeTo(w['rotor_hz'] as double, 1e-9));
        expect(r.periodicityConfidence,
            closeTo(w['periodicity_confidence'] as double, 1e-9));
        expect(r.envelopeSnrDb, closeTo(w['envelope_snr_db'] as double, 1e-9));
        expect(r.windDominance, closeTo(w['wind_dominance'] as double, 1e-9));
        expect(r.amDepthDb, closeTo(w['am_depth_db'] as double, 1e-9));
        expect(r.asymmetryDb, closeTo(w['asymmetry_db'] as double, 1e-9));
        expect(r.passTimesS.length, w['n_passes']);
      });

      test('$name：ACF 的諧波歧義解對了（rpm 與合成真值相符）', () {
        final r = analyze(name);
        final truth = (ref[name] as Map<String, dynamic>)['truth']
            as Map<String, dynamic>;
        // 三片一致時 ACF 在 T_bp、2T_bp、3T_bp 都有峰，挑錯的話 rpm 會差 3 倍
        expect(r.rpmFromAudio,
            closeTo((truth['rpm'] as num).toDouble(), 0.5),
            reason: '轉速應與合成真值相符，差三倍就是把 3P 當成 1P');
      });
    }
  });

  group('逐片指標逐項對照', () {
    for (final name in ['healthy', 'eroded']) {
      test('$name：位準、高頻占比、窄頻峰、獨有性', () {
        final r = analyze(name);
        final wb = (want(name)['blades'] as List).cast<Map<String, dynamic>>();
        expect(r.blades.length, wb.length);
        for (var i = 0; i < wb.length; i++) {
          final b = r.blades[i], w = wb[i];
          expect(b.index, w['index']);
          expect(b.nPasses, w['n_passes']);
          expect(b.bandLevelDb, closeTo(w['band_level_db'] as double, 1e-9),
              reason: '$name blade$i level');
          expect(b.highBandRatio,
              closeTo(w['high_band_ratio'] as double, 1e-9),
              reason: '$name blade$i hb');
          expect(b.tonalFreqHz, closeTo(w['tonal_freq_hz'] as double, 1e-6));
          expect(b.tonalProminenceDb,
              closeTo(w['tonal_prominence_db'] as double, 1e-9));
          expect(b.tonalExclusive, w['tonal_exclusive'],
              reason: '$name blade$i exclusive');
        }
      });
    }

    test('葉片標籤是 A/B/C', () {
      final r = analyze('eroded');
      expect(r.blades.map((b) => b.label).toList(), ['A', 'B', 'C']);
    });
  });

  group('互比：兩個方向都要對', () {
    test('健康音軌不得標記任何一片（不誤報）', () {
      final r = analyze('healthy');
      expect(r.usable, isTrue);
      expect(r.comparisons, isNotEmpty, reason: '要真的比過，不是略過');
      for (final c in r.comparisons) {
        expect(c.flagged, isFalse, reason: '${c.metric} 不該被標記');
      }
      expect(r.blades.any((b) => b.tonalExclusive), isFalse);
      expect(r.anyFlagged, isFalse);
    });

    test('侵蝕音軌：寬頻位準與高頻占比都標記，而且指對那一片', () {
      final r = analyze('eroded');
      final w = want('eroded')['comparisons'] as Map<String, dynamic>;
      expect(r.anyFlagged, isTrue);
      for (final metric in ['band_level_db', 'high_band_ratio']) {
        final c = r.comparisonOf(metric);
        final ww = w[metric] as Map<String, dynamic>;
        expect(c, isNotNull, reason: '$metric 應該有互比結果');
        expect(c!.flagged, ww['flagged'], reason: '$metric flagged');
        expect(c.outlierIndex, ww['outlier_index'],
            reason: '$metric 指到的葉片');
        expect(c.z, closeTo(ww['z'] as double, 1e-9));
        expect(c.direction, MetricDirection.high,
            reason: '聲學量只有偏高才算徵兆');
      }
      // 合成時是第 2 片（index 1）加了 +4 dB
      expect(r.comparisonOf('band_level_db')!.outlierIndex, 1);
    });

    test('哨音：只有那一片被標成獨有，而且頻率接近合成值', () {
      final r = analyze('eroded');
      final excl = r.blades.where((b) => b.tonalExclusive).toList();
      expect(excl.length, 1);
      expect(excl.first.index, 2, reason: '合成時是第 3 片加哨音');
      expect(excl.first.tonalFreqHz, closeTo(1800.0, 1800.0 * 0.05));
      expect(excl.first.tonalProminenceDb, greaterThan(8.0));
    });
  });

  group('窄頻峰的突出量與獨有性', () {
    /// 25 Hz 間距、0–8 kHz 的平坦頻譜，在 [peaks] 各插一根 [db] 的峰
    ({Float64List freqs, Float64List specDb}) spectrum(
        List<double> peaks, double db) {
      const n = 321; // 0 .. 8000 Hz，25 Hz 一格
      final freqs = Float64List(n);
      final spec = Float64List(n);
      for (var i = 0; i < n; i++) {
        freqs[i] = i * 25.0;
      }
      for (final pf in peaks) {
        var bi = 0;
        var bd = double.infinity;
        for (var i = 0; i < n; i++) {
          final d = (freqs[i] - pf).abs();
          if (d < bd) {
            bd = d;
            bi = i;
          }
        }
        spec[bi] = db;
      }
      return (freqs: freqs, specDb: spec);
    }

    test('excessAtFrequency 讀的是指定頻率，不是頻帶內的最大值', () {
      final sp = spectrum([1400.0], 20.0);
      expect(
          BladeAcousticService.excessAtFrequency(
              sp.specDb, sp.freqs, 1400.0, 400.0, 8000.0),
          greaterThan(15.0));
      // 別的頻率讀到的是基線附近——這正是「另兩片在這個頻率沒有東西」該有的答案
      expect(
          BladeAcousticService.excessAtFrequency(
                  sp.specDb, sp.freqs, 3000.0, 400.0, 8000.0)
              .abs(),
          lessThan(1.0));
    });

    test('**根本原因**：窄頻帶的 bin 數不足中值濾波時回 NaN', () {
      final sp = spectrum([1400.0], 20.0);
      // ±3% 的窄頻帶（1358–1442 Hz，25 Hz 間距 → 約 4 個 bin）
      final narrow = BladeAcousticService.excessAtFrequency(
          sp.specDb, sp.freqs, 1400.0, 1400.0 * 0.97, 1400.0 * 1.03);
      expect(narrow.isNaN, isTrue,
          reason: '舊版就是在這裡拿到 NaN，然後把它當成 0 dB——'
              '於是獨有性複查等於沒做');
      // 同一個頻率改用全頻帶基線就量得出來
      expect(
          BladeAcousticService.excessAtFrequency(
              sp.specDb, sp.freqs, 1400.0, 400.0, 8000.0),
          greaterThan(15.0));
    });

    test('tonalExcess 在頻帶過窄時回空，且明確區分「量不出來」與「沒有峰」', () {
      final sp = spectrum([1400.0], 20.0);
      expect(
          BladeAcousticService.tonalExcess(sp.specDb, sp.freqs, 1390.0, 1410.0)
              .isEmpty,
          isTrue);
      final full =
          BladeAcousticService.tonalExcess(sp.specDb, sp.freqs, 400.0, 8000.0);
      expect(full.isEmpty, isFalse);
      expect(full.freqsHz.length, full.excessDb.length);
    });

    test('三片同頻時，相對另兩片的突出量差不足 → 不算獨有', () {
      // 三片都有 1400 Hz 的 20 dB 峰
      final sp = spectrum([1400.0], 20.0);
      final own = BladeAcousticService.excessAtFrequency(
          sp.specDb, sp.freqs, 1400.0, 400.0, 8000.0);
      final other = BladeAcousticService.excessAtFrequency(
          sp.specDb, sp.freqs, 1400.0, 400.0, 8000.0);
      const p = BladeAcousticParams();
      // 這是 analyzeSamples 裡獨有性判準的算式
      expect(own >= p.tonalMinProminenceDb, isTrue, reason: '峰本身夠突出');
      expect(own - other >= p.tonalMinProminenceDb / 2.0, isFalse,
          reason: '但另一片同頻也有，就不是「只有這片」');
    });

    test('只有一片有時，差額足夠 → 算獨有', () {
      final loud = spectrum([1400.0], 20.0);
      final quiet = spectrum(const [], 0.0);
      final own = BladeAcousticService.excessAtFrequency(
          loud.specDb, loud.freqs, 1400.0, 400.0, 8000.0);
      final other = BladeAcousticService.excessAtFrequency(
          quiet.specDb, quiet.freqs, 1400.0, 400.0, 8000.0);
      const p = BladeAcousticParams();
      expect(own >= p.tonalMinProminenceDb, isTrue);
      expect(own - other >= p.tonalMinProminenceDb / 2.0, isTrue);
    });
  });

  group('三重守門：不可用時不給看起來像數據的數字', () {
    BladeAcousticResult ofSamples(Float64List x, {int sr = 16000}) =>
        BladeAcousticService.analyzeSamples(
            BladeAudioClip(samples: x, sampleRate: sr));

    test('靜音 → 不可用，且不產生逐片結果', () {
      final r = ofSamples(Float64List(16000 * 3));
      expect(r.usable, isFalse);
      expect(r.blades, isEmpty, reason: '不可用時不能有逐片數字');
      expect(r.comparisons, isEmpty);
      expect(r.notes, isNotEmpty, reason: '要說出為什麼不可用');
    });

    test('白噪音（沒有葉片通過的週期性）→ 不可用', () {
      final rnd = math.Random(7);
      final x = Float64List(16000 * 4);
      for (var i = 0; i < x.length; i++) {
        x[i] = (rnd.nextDouble() - 0.5) * 0.2;
      }
      final r = ofSamples(x);
      expect(r.usable, isFalse);
      expect(r.blades, isEmpty);
    });

    test('風噪主導（能量幾乎全在 200 Hz 以下）→ 不可用並指出重錄方式', () {
      final x = Float64List(16000 * 4);
      for (var i = 0; i < x.length; i++) {
        x[i] = 0.5 * math.sin(2 * math.pi * 40 * i / 16000);
      }
      final r = ofSamples(x);
      expect(r.usable, isFalse);
      expect(r.notes.join(), contains('防風罩'));
    });

    test('訊噪比偏低但仍可用時，要留下漏判的警告而不是靜靜通過', () {
      // 直接驗門檻的意義：marginal 與 min 之間是「照做但要說清楚」
      const p = BladeAcousticParams();
      expect(p.marginalSnrDb, greaterThan(p.minSnrDb));
      final r = analyze('healthy');
      expect(r.envelopeSnrDb, greaterThan(p.marginalSnrDb),
          reason: '夾具本身訊噪比夠高，所以不該出現偏低警告');
      expect(r.notes.join(), isNot(contains('偏低')));
    });
  });

  group('analyzeBytes：位元組進、結論出，不丟例外', () {
    test('壞掉的位元組 → 不可用 + 可顯示的原因', () {
      for (final bytes in [
        Uint8List(0),
        Uint8List.fromList([1, 2, 3]),
        Uint8List(512),
      ]) {
        final r = BladeAcousticService.analyzeBytes(bytes);
        expect(r.usable, isFalse);
        expect(r.notes, isNotEmpty);
        expect(r.blades, isEmpty);
      }
    });

    test('真夾具走 analyzeBytes 與走 analyzeSamples 結果相同', () {
      final bytes = File('test/assets/blade_audio_eroded.wav').readAsBytesSync();
      final a = BladeAcousticService.analyzeBytes(bytes);
      final b = analyze('eroded');
      expect(a.usable, b.usable);
      expect(a.rpmFromAudio, closeTo(b.rpmFromAudio, 1e-12));
      expect(a.blades.length, b.blades.length);
    });

    test('太短的音軌明確拒絕，理由講的是長度而不是週期性', () {
      // Python 在這裡是丟 ValueError。Dart 改成回不可用 + 一句原因，
      // 因為一段錄壞的音軌不該讓整個場次的分析中斷。
      final short = BladeAcousticService.analyzeSamples(
          BladeAudioClip(samples: Float64List(1000), sampleRate: 16000));
      expect(short.usable, isFalse);
      expect(short.notes.join(), contains('不足 0.5 秒'),
          reason: '要說是太短，不能只說「找不到週期性」——後者會讓人以為風機沒轉');
      expect(short.blades, isEmpty);
      expect(BladeAcousticService.tooShort(
              BladeAudioClip(samples: Float64List(4000), sampleRate: 16000)),
          isTrue);
      expect(BladeAcousticService.tooShort(
              BladeAudioClip(samples: Float64List(8000), sampleRate: 16000)),
          isFalse);
    });
  });

  group('葉片標籤對齊', () {
    test('給了影片的六點鐘時刻後，標籤說明改為「已對齊」', () {
      final r = BladeAudioDecode.decodeWav(
          File('test/assets/blade_audio_eroded.wav').readAsBytesSync());
      final plain = BladeAcousticService.analyzeSamples(r.clip!);
      final aligned = BladeAcousticService.analyzeSamples(r.clip!,
          passTimesHint: [plain.passTimesS[1]]);
      expect(plain.notes.join(), contains('先後順序'));
      expect(aligned.notes.join(), contains('已對齊'));
    });
  });
}
