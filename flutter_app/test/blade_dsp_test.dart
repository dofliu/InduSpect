import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/services/blade_audio_decode.dart';
import 'package:induspect_ai/services/blade_dsp.dart';

/// DSP 基本運算逐項對照 scipy／numpy。
///
/// 參考值由 `blade_prototype/scripts/make_acoustic_fixture.py` 在同一段
/// `blade_audio_eroded.wav` 上量出並凍結。**每一項各一條測試**：STFT 的縮放、
/// Savitzky–Golay 的邊緣處理、medfilt 的邊界填補各有好幾種說得通的慣例，
/// 猜錯不會報錯，只會讓最後一個數字對不上——那時已經分不清是哪一步錯了。
void main() {
  late Map<String, dynamic> ref;
  late Map<String, dynamic> st;
  late BladeAudioClip clip;

  setUpAll(() {
    ref = jsonDecode(File('test/assets/blade_acoustic_reference.json')
        .readAsStringSync()) as Map<String, dynamic>;
    final r = BladeAudioDecode.decodeWav(
        File('test/assets/blade_audio_eroded.wav').readAsBytesSync());
    expect(r.ok, isTrue, reason: '夾具 WAV 要讀得起來：${r.message}');
    clip = r.clip!;
    st = (ref['eroded'] as Map)['stages'] as Map<String, dynamic>;
  });

  /// 分析前的前處理與 `analyze_samples` 相同：移除平均值
  Float64List centered() {
    var mean = 0.0;
    for (final v in clip.samples) {
      mean += v;
    }
    mean /= clip.samples.length;
    return Float64List.fromList(
        clip.samples.map((v) => v - mean).toList(growable: false));
  }

  group('窗與窗長', () {
    test('分析窗長 = 2^round(log2(0.032 × sr))，與 Python 相同', () {
      expect(BladeDsp.nperSegFor(clip.sampleRate), st['nperseg']);
      // 常見取樣率都不會落在 .5 上（否則 Python 的半數取偶與 Dart 的
      // 半數遠離零會給出不同窗長）
      expect(BladeDsp.nperSegFor(16000), 512);
      expect(BladeDsp.nperSegFor(24000), 1024);
      expect(BladeDsp.nperSegFor(48000), 2048);
      expect(BladeDsp.nperSegFor(8000), 256);
    });

    test('Hann 是週期性版本（分母 n），窗和恰為 n/2', () {
      final w = BladeDsp.hannPeriodic(512);
      // 對稱版的 w[1] 會是 0.5-0.5cos(2π/511)，與這個值不同
      expect(w[1], closeTo(0.5 - 0.5 * math.cos(2 * math.pi / 512), 1e-15));
      expect(w[0], 0.0);
      var sum = 0.0;
      for (final v in w) {
        sum += v;
      }
      expect(sum, closeTo(256.0, 1e-9));
    });
  });

  group('FFT', () {
    test('單一正弦的能量集中在對應的 bin', () {
      const n = 256, k0 = 17;
      final re = Float64List(n), im = Float64List(n);
      for (var i = 0; i < n; i++) {
        re[i] = math.cos(2 * math.pi * k0 * i / n);
      }
      BladeDsp.fft(re, im);
      final mag = List<double>.generate(
          n ~/ 2 + 1, (k) => math.sqrt(re[k] * re[k] + im[k] * im[k]));
      var argmax = 0;
      for (var k = 1; k < mag.length; k++) {
        if (mag[k] > mag[argmax]) argmax = k;
      }
      expect(argmax, k0);
      expect(mag[k0], closeTo(n / 2, 1e-6));
      // 其他 bin 應該幾乎為零——不成立就表示位元反轉或蝴蝶運算寫錯
      for (var k = 0; k < mag.length; k++) {
        if (k == k0) continue;
        expect(mag[k], lessThan(1e-9));
      }
    });

    test('常數訊號只有 DC', () {
      final re = Float64List(64)..fillRange(0, 64, 2.0);
      final im = Float64List(64);
      BladeDsp.fft(re, im);
      expect(re[0], closeTo(128.0, 1e-9));
      for (var k = 1; k < 33; k++) {
        expect(math.sqrt(re[k] * re[k] + im[k] * im[k]), lessThan(1e-9));
      }
    });
  });

  group('STFT 對照 scipy.signal.stft', () {
    test('形狀、頻率軸、時間軸', () {
      final s = BladeDsp.stft(centered(), clip.sampleRate);
      expect(s.nFreq, st['n_freqs']);
      expect(s.nTime, st['n_times']);
      final frameHz = 1.0 /
          BladeDsp.median(List<double>.generate(
              s.nTime - 1, (i) => s.timesS[i + 1] - s.timesS[i]));
      expect(frameHz, closeTo(st['frame_hz'] as double, 1e-6));
      (st['freq_hz_at'] as Map).forEach((k, v) {
        expect(s.freqsHz[int.parse(k as String)], closeTo(v as double, 1e-6));
      });
      (st['time_s_at'] as Map).forEach((k, v) {
        expect(s.timesS[int.parse(k as String)], closeTo(v as double, 1e-9));
      });
    });

    test('幅值逐點對照（縮放、邊界補零、padded 三者都要對）', () {
      final s = BladeDsp.stft(centered(), clip.sampleRate);
      (st['mag_at'] as Map).forEach((key, v) {
        final parts = (key as String).split(',');
        final fi = int.parse(parts[0]), ti = int.parse(parts[1]);
        // 容差放在 1e-7：Python 的參考值只存到小數第 9 位
        expect(s.magAt(fi, ti), closeTo(v as double, 1e-7),
            reason: 'S[$fi,$ti]');
      });
    });

    test('頻帶能量逐幀對照，且風噪占比一致', () {
      final s = BladeDsp.stft(centered(), clip.sampleRate);
      final band = BladeDsp.bandEnergy(s, 400.0, 8000.0);
      (st['band_energy_at'] as Map).forEach((k, v) {
        expect(band[int.parse(k as String)], closeTo(v as double, 1e-9));
      });
      final wind = BladeDsp.bandEnergy(s, 0.0, 200.0);
      final total = BladeDsp.bandEnergy(s, 0.0, 8000.0);
      var ws = 0.0, ts = 0.0;
      for (var i = 0; i < s.nTime; i++) {
        ws += wind[i];
        ts += total[i];
      }
      expect(ws / (ts + 1e-20), closeTo(st['wind_dominance'] as double, 1e-9));
    });

    test('頻帶內沒有 bin 時回全 0（不是 NaN）', () {
      final s = BladeDsp.stft(centered(), clip.sampleRate);
      final none = BladeDsp.bandEnergy(s, 1e9, 2e9);
      expect(none.length, s.nTime);
      expect(none.every((v) => v == 0.0), isTrue);
    });
  });

  group('包絡與週期性', () {
    test('Savitzky–Golay 係數 = [-21,14,39,54,59,54,39,14,-21]/231', () {
      final want = (ref['savgol_9_2_coeffs'] as List).cast<num>();
      for (var i = 0; i < 9; i++) {
        expect(BladeDsp.savgol92[i], closeTo(want[i].toDouble(), 1e-12));
      }
    });

    test('平滑後的包絡、中位數、p98、訊噪比都對得上', () {
      final s = BladeDsp.stft(centered(), clip.sampleRate);
      final band = BladeDsp.bandEnergy(s, 400.0, 8000.0);
      final raw = Float64List(s.nTime);
      for (var i = 0; i < s.nTime; i++) {
        raw[i] = math.sqrt(math.max(band[i], 0.0));
      }
      final env = BladeDsp.savgolSmooth(raw);
      (st['envelope_at'] as Map).forEach((k, v) {
        expect(env[int.parse(k as String)], closeTo(v as double, 1e-9),
            reason: 'env[$k]');
      });
      final med = BladeDsp.median(env) + 1e-20;
      expect(med, closeTo(st['envelope_median'] as double, 1e-9));
      expect(BladeDsp.percentile(env, 98),
          closeTo(st['envelope_p98'] as double, 1e-9));
      expect(20.0 * math.log((BladeDsp.percentile(env, 98) + 1e-20) / med) /
              math.ln10,
          closeTo(st['snr_db'] as double, 1e-9));
    });

    test('自相關逐 lag 對照，lag 0 恆為 1', () {
      final s = BladeDsp.stft(centered(), clip.sampleRate);
      final band = BladeDsp.bandEnergy(s, 400.0, 8000.0);
      final raw = Float64List(s.nTime);
      for (var i = 0; i < s.nTime; i++) {
        raw[i] = math.sqrt(math.max(band[i], 0.0));
      }
      final acf = BladeDsp.autocorrNormalized(BladeDsp.savgolSmooth(raw));
      expect(acf[0], closeTo(1.0, 1e-9));
      (st['acf_at'] as Map).forEach((k, v) {
        expect(acf[int.parse(k as String)], closeTo(v as double, 1e-8),
            reason: 'acf[$k]');
      });
    });

    test('全為零的包絡回全零，不是 NaN', () {
      final acf = BladeDsp.autocorrNormalized(Float64List(64));
      expect(acf.every((v) => v == 0.0), isTrue);
    });

    test('調變深度：純正弦包絡的深度應接近其振幅比', () {
      const n = 400;
      const frameHz = 50.0, freq = 2.0;
      final env = Float64List(n);
      for (var i = 0; i < n; i++) {
        env[i] = 1.0 + 0.4 * math.sin(2 * math.pi * freq * i / frameHz);
      }
      expect(BladeDsp.modulationDepth(env, frameHz, freq), closeTo(0.4, 0.01));
      // 沒有那個頻率的成分時應接近 0
      expect(BladeDsp.modulationDepth(env, frameHz, 11.0), lessThan(0.05));
    });

    test('拋物線精修把整數峰推到真正的頂點', () {
      // y = -(x-3.25)^2 的取樣，頂點在 3.25
      final ac = Float64List.fromList(
          List<double>.generate(8, (i) => -math.pow(i - 3.25, 2).toDouble()));
      expect(BladeDsp.refinePeak(ac, 3), closeTo(3.25, 1e-9));
    });

    test('valueAtLag 超出範圍回 0，範圍內線性內插', () {
      final ac = Float64List.fromList([1.0, 0.5, 0.0, -0.5]);
      expect(BladeDsp.valueAtLag(ac, 0.5), closeTo(0.75, 1e-12));
      expect(BladeDsp.valueAtLag(ac, -1), 0.0);
      expect(BladeDsp.valueAtLag(ac, 3), 0.0);
    });
  });

  group('中值濾波與統計', () {
    test('medfilt 用零填補（不是 REPLICATE）', () {
      // 斜坡是能分辨兩種邊界的最短案例。scipy 實測：
      //   medfilt([1..7], 5) = [1, 2, 3, 4, 5, 5, 5]
      // REPLICATE 會給 [2, 2, 3, 4, 5, 6, 6]——兩端各差一個值，
      // 而那正是頻譜基線兩端的所在，會直接改掉窄頻峰的突出量。
      final ramp = BladeDsp.medianFilter(
          Float64List.fromList([1, 2, 3, 4, 5, 6, 7]), 5);
      expect(ramp, [1.0, 2.0, 3.0, 4.0, 5.0, 5.0, 5.0]);

      // 核比資料長時整段被零填補主導（scipy 會發 UserWarning，值是 0）
      expect(BladeDsp.medianFilter(Float64List.fromList([9.0, 9.0]), 5),
          [0.0, 0.0]);
      // 但剛好等長時中位數仍是原值
      expect(BladeDsp.medianFilter(Float64List.fromList([9.0, 9.0, 9.0]), 5),
          [9.0, 9.0, 9.0]);
      // 偶數核強制加一（scipy 只接受奇數核）
      expect(BladeDsp.medianFilter(Float64List.fromList([1, 2, 3, 4, 5]), 4),
          BladeDsp.medianFilter(Float64List.fromList([1, 2, 3, 4, 5]), 5));
    });

    test('percentile 用 numpy 的 linear 方法', () {
      final v = [1.0, 2.0, 3.0, 4.0, 5.0, 9.0];
      expect(BladeDsp.percentile(v, 50), closeTo(3.5, 1e-12));
      expect(BladeDsp.percentile(v, 80), closeTo(5.0, 1e-12));
      expect(BladeDsp.percentile(v, 98), closeTo(8.6, 1e-12));
      expect(BladeDsp.percentile(<double>[], 50).isNaN, isTrue);
    });

    test('roundHalfEven 與 numpy 的 round 相同（不是 Dart 的 round）', () {
      expect(BladeDsp.roundHalfEven(2.5), 2);
      expect(BladeDsp.roundHalfEven(3.5), 4);
      expect(BladeDsp.roundHalfEven(-2.5), -2);
      expect(BladeDsp.roundHalfEven(2.4), 2);
      expect(BladeDsp.roundHalfEven(2.6), 3);
      // Dart 的 round 會給 3 / -3，差一整幀
      expect(2.5.round(), 3);
    });

    test('polyfit 係數順序與 numpy 相同（高次到低次）', () {
      final x = Float64List.fromList([0, 1, 2, 3, 4]);
      final y = [1.0, 3.0, 9.0, 19.0, 33.0]; // 2x^2 + 0x + 1
      final c = BladeDsp.polyfit(x, y, List<bool>.filled(5, true), 2);
      expect(c[0], closeTo(2.0, 1e-9));
      expect(c[1], closeTo(0.0, 1e-9));
      expect(c[2], closeTo(1.0, 1e-9));
      expect(BladeDsp.polyval(c, 5.0), closeTo(51.0, 1e-8));
    });
  });
}
