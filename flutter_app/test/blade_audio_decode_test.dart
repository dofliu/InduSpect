import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/services/blade_audio_decode.dart';

/// 組一個 PCM WAV。位元深度／聲道數／額外區塊都可控，用來測讀取路徑。
Uint8List buildWav({
  required List<int> samples, // 依 bits 解讀的原始整數值（多聲道則交錯）
  int sampleRate = 16000,
  int bits = 16,
  int channels = 1,
  int format = 1,
  bool extraChunk = false,
  int? dataSizeOverride,
  bool truncateData = false,
}) {
  final bytesPerSample = bits ~/ 8;
  final dataBytes = BytesBuilder();
  for (final v in samples) {
    for (var b = 0; b < bytesPerSample; b++) {
      dataBytes.addByte((v >> (8 * b)) & 0xFF);
    }
  }
  var data = dataBytes.toBytes();
  if (truncateData) data = Uint8List.sublistView(data, 0, data.length ~/ 2);

  final out = BytesBuilder();
  void tag(String t) => out.add(ascii.encode(t));
  void u32(int v) => out.add(Uint8List(4)
    ..buffer.asByteData().setUint32(0, v, Endian.little));
  void u16(int v) => out.add(Uint8List(2)
    ..buffer.asByteData().setUint16(0, v, Endian.little));

  tag('RIFF');
  u32(0); // 大小欄位不影響解碼（串流寫入時常留 0）
  tag('WAVE');
  if (extraChunk) {
    // 手機錄音程式常插 LIST／fact 在 fmt 之前或之後
    tag('LIST');
    u32(4);
    out.add(ascii.encode('INFO'));
  }
  tag('fmt ');
  u32(16);
  u16(format);
  u16(channels);
  u32(sampleRate);
  u32(sampleRate * channels * bytesPerSample);
  u16(channels * bytesPerSample);
  u16(bits);
  tag('data');
  u32(dataSizeOverride ?? data.length);
  out.add(data);
  return out.toBytes();
}

/// WAV 讀取。只支援未壓縮 PCM 是刻意的——裝置上沒有純 Dart 的 AAC/MP3 解碼器，
/// 而現場要的是離線可用。所以每一種讀不了的情況都要有**能顯示給人看的原因**，
/// 而不是回一個 null 讓呼叫端自己編一句話。
void main() {
  group('夾具 WAV 對照 Python', () {
    test('取樣率、樣本數、逐點樣本值都與 acoustics.py 讀到的相同', () {
      final ref = jsonDecode(File('test/assets/blade_acoustic_reference.json')
          .readAsStringSync()) as Map<String, dynamic>;
      for (final name in ['healthy', 'eroded']) {
        final ent = ref[name] as Map<String, dynamic>;
        final want = ent['clip'] as Map<String, dynamic>;
        final r = BladeAudioDecode.decodeWav(
            File('test/assets/${ent['wav']}').readAsBytesSync());
        expect(r.ok, isTrue, reason: '$name: ${r.message}');
        final clip = r.clip!;
        expect(clip.sampleRate, want['sample_rate']);
        expect(clip.samples.length, want['n_samples']);
        expect(clip.durationS, closeTo(want['duration_s'] as double, 1e-9));
        (want['sample_at'] as Map).forEach((k, v) {
          expect(clip.samples[int.parse(k as String)],
              closeTo(v as double, 1e-9),
              reason: '$name samples[$k]');
        });
      }
    });
  });

  group('位元深度換算', () {
    test('16-bit 除以 32768', () {
      final r = BladeAudioDecode.decodeWav(
          buildWav(samples: [0, 16384, -16384, 32767]));
      expect(r.ok, isTrue);
      expect(r.clip!.samples[0], 0.0);
      expect(r.clip!.samples[1], closeTo(0.5, 1e-12));
      expect(r.clip!.samples[2], closeTo(-0.5, 1e-12));
      expect(r.clip!.samples[3], closeTo(32767 / 32768, 1e-12));
    });

    test('8-bit 是無號數，128 = 靜音', () {
      final r = BladeAudioDecode.decodeWav(
          buildWav(samples: [128, 255, 0, 192], bits: 8));
      expect(r.ok, isTrue);
      expect(r.clip!.samples[0], 0.0);
      expect(r.clip!.samples[1], closeTo(127 / 128, 1e-12));
      expect(r.clip!.samples[2], -1.0);
      expect(r.clip!.samples[3], closeTo(0.5, 1e-12));
    });

    test('24-bit 走「補一個低位元組當 int32 讀」，與 Python 同一個尾數', () {
      // Python：as32[:, 1:] = 三個位元組，再 view('<i4') / 2^31
      // 等於 24-bit 值左移 8 位。直接算 v/2^23 會差一個 2^-8 的尾數。
      final r = BladeAudioDecode.decodeWav(
          buildWav(samples: [0x400000, 0xC00000], bits: 24));
      expect(r.ok, isTrue);
      expect(r.clip!.samples[0], closeTo(0.5, 1e-12));
      expect(r.clip!.samples[1], closeTo(-0.5, 1e-12));
    });

    test('32-bit 除以 2^31', () {
      final r = BladeAudioDecode.decodeWav(
          samples32([0, 1073741824, -1073741824]));
      expect(r.ok, isTrue);
      expect(r.clip!.samples[1], closeTo(0.5, 1e-12));
      expect(r.clip!.samples[2], closeTo(-0.5, 1e-12));
    });

    test('多聲道取平均（與 Python 的 reshape().mean(axis=1) 相同）', () {
      // 左 = +0.5、右 = −0.5 → 平均 0
      final r = BladeAudioDecode.decodeWav(
          buildWav(samples: [16384, -16384, 32767, 32767], channels: 2));
      expect(r.ok, isTrue);
      expect(r.clip!.samples.length, 2);
      expect(r.clip!.samples[0], closeTo(0.0, 1e-12));
      expect(r.clip!.samples[1], closeTo(32767 / 32768, 1e-12));
    });
  });

  group('區塊走訪', () {
    test('fmt 前面插了別的區塊照樣讀得到（不能寫死偏移量）', () {
      final r = BladeAudioDecode.decodeWav(
          buildWav(samples: [16384], extraChunk: true));
      expect(r.ok, isTrue);
      expect(r.clip!.samples[0], closeTo(0.5, 1e-12));
    });

    test('data 區塊長度為 0 時改用實際可讀的位元組（串流寫入未回填標頭）', () {
      final r = BladeAudioDecode.decodeWav(
          buildWav(samples: [16384, 8192], dataSizeOverride: 0));
      expect(r.ok, isTrue);
      expect(r.clip!.samples.length, 2);
    });

    test('data 長度超出檔案時只讀得到的部分（複製中斷）', () {
      final r = BladeAudioDecode.decodeWav(
          buildWav(samples: [16384, 8192], dataSizeOverride: 999999));
      expect(r.ok, isTrue);
      expect(r.clip!.samples.length, 2);
    });

    test('WAVE_FORMAT_EXTENSIBLE 但 fmt 沒有 SubFormat 時不當成 PCM', () {
      final r = BladeAudioDecode.decodeWav(
          buildWav(samples: [16384], format: 0xFFFE));
      expect(r.ok, isFalse);
      expect(r.error, BladeAudioError.unsupportedCodec);
    });
  });

  group('讀不了的每一種情況都有原因，而且不丟例外', () {
    test('太短', () {
      final r = BladeAudioDecode.decodeWav(Uint8List.fromList([1, 2, 3]));
      expect(r.ok, isFalse);
      expect(r.error, BladeAudioError.tooShort);
      expect(r.message, contains('重新錄音'));
    });

    test('不是 RIFF/WAVE（例如 m4a）→ 訊息要講「換成 WAV」', () {
      final bytes = Uint8List(64);
      bytes.setRange(4, 8, ascii.encode('ftyp'));
      final r = BladeAudioDecode.decodeWav(bytes);
      expect(r.ok, isFalse);
      expect(r.error, BladeAudioError.notRiffWave);
      expect(r.message, contains('WAV'));
    });

    test('壓縮格式（非 PCM）', () {
      final r = BladeAudioDecode.decodeWav(
          buildWav(samples: [1, 2, 3], format: 85)); // MP3 in WAV
      expect(r.ok, isFalse);
      expect(r.error, BladeAudioError.unsupportedCodec);
      expect(r.message, contains('PCM'));
    });

    test('沒有 data 區塊', () {
      final full = buildWav(samples: [16384, 8192]);
      // 把 'data' 標籤改掉，模擬結構不完整
      final broken = Uint8List.fromList(full);
      final at = _find(broken, ascii.encode('data'));
      expect(at, greaterThan(0));
      broken.setRange(at, at + 4, ascii.encode('junk'));
      final r = BladeAudioDecode.decodeWav(broken);
      expect(r.ok, isFalse);
      expect(r.error, BladeAudioError.noDataChunk);
    });

    test('data 區塊裡連一個完整取樣都沒有', () {
      final r = BladeAudioDecode.decodeWav(buildWav(samples: const []));
      expect(r.ok, isFalse);
      expect(r.error, BladeAudioError.emptyData);
    });

    test('截斷的檔案不丟例外（現場的外接儲存會這樣）', () {
      for (final n in [45, 60, 100]) {
        final full = buildWav(
            samples: List<int>.generate(200, (i) => (i * 300) % 30000));
        final cut = Uint8List.sublistView(full, 0, n);
        // 重點是不丟例外，而且結果一定二分：要嘛拿到樣本，要嘛有一句可顯示的原因。
        // 「回 null 但沒有原因」是這支服務最不該出現的狀態。
        final r = BladeAudioDecode.decodeWav(cut);
        if (r.ok) {
          expect(r.clip!.samples, isNotEmpty, reason: 'n=$n');
          expect(r.error, isNull);
        } else {
          expect(r.message, isNotEmpty, reason: 'n=$n');
        }
      }
    });

    test('全零位元組不丟例外', () {
      final r = BladeAudioDecode.decodeWav(Uint8List(512));
      expect(r.ok, isFalse);
      expect(r.error, BladeAudioError.notRiffWave);
    });
  });
}

/// 32-bit PCM 的 WAV（buildWav 的 >> 位移對負數在 Dart 是算術位移，
/// 32-bit 時要自己組才不會溢位）
Uint8List samples32(List<int> vals) {
  final bd = ByteData(vals.length * 4);
  for (var i = 0; i < vals.length; i++) {
    bd.setInt32(i * 4, vals[i], Endian.little);
  }
  final raw = bd.buffer.asUint8List();
  final out = BytesBuilder();
  void tag(String t) => out.add(ascii.encode(t));
  void u32(int v) => out.add(Uint8List(4)
    ..buffer.asByteData().setUint32(0, v, Endian.little));
  void u16(int v) => out.add(Uint8List(2)
    ..buffer.asByteData().setUint16(0, v, Endian.little));
  tag('RIFF');
  u32(0);
  tag('WAVE');
  tag('fmt ');
  u32(16);
  u16(1);
  u16(1);
  u32(16000);
  u32(16000 * 4);
  u16(4);
  u16(32);
  tag('data');
  u32(raw.length);
  out.add(raw);
  return out.toBytes();
}

int _find(Uint8List haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
