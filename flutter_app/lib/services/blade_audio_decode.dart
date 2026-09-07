import 'dart:typed_data';

/// 讀進來的單聲道音訊。
class BladeAudioClip {
  /// -1..1 的單聲道樣本。多聲道來源已取各聲道平均。
  final Float64List samples;
  final int sampleRate;

  const BladeAudioClip({required this.samples, required this.sampleRate});

  double get durationS => samples.length / sampleRate;
}

/// 讀不了的原因。**不丟例外、不回半套資料**——現場拿到的檔案什麼都有可能，
/// 而「這個檔為什麼不能用」要能顯示給人看。
enum BladeAudioError {
  tooShort,
  notRiffWave,
  noFmtChunk,
  noDataChunk,
  unsupportedCodec,
  unsupportedBitDepth,
  emptyData,
}

/// 解碼結果。`clip` 與 `error` 恰有一個非 null。
class BladeAudioDecodeResult {
  final BladeAudioClip? clip;
  final BladeAudioError? error;

  const BladeAudioDecodeResult.ok(BladeAudioClip c)
      : clip = c,
        error = null;
  const BladeAudioDecodeResult.fail(BladeAudioError e)
      : clip = null,
        error = e;

  bool get ok => clip != null;

  /// 給使用者看的訊息。講「換什麼檔案／怎麼重錄」，不講位元組。
  String get message {
    switch (error) {
      case BladeAudioError.tooShort:
      case BladeAudioError.emptyData:
        return '這個音檔沒有內容，請重新錄音';
      case BladeAudioError.notRiffWave:
        return '只讀得懂 WAV 檔。手機錄音程式請選 WAV／PCM 格式，'
            'm4a 與 mp4 目前無法在裝置上離線解碼';
      case BladeAudioError.noFmtChunk:
      case BladeAudioError.noDataChunk:
        return '這個 WAV 檔的結構不完整（可能複製中斷），請重新取得檔案';
      case BladeAudioError.unsupportedCodec:
        return '這個 WAV 檔是壓縮格式（非 PCM）。錄音時請選未壓縮的 PCM';
      case BladeAudioError.unsupportedBitDepth:
        return '不支援的位元深度，請改用 16-bit PCM 錄音';
      case null:
        return '';
    }
  }
}

/// WAV 讀取（純 Dart，離線）。
///
/// 只支援未壓縮 PCM——這不是偷懶，是**裝置上沒有純 Dart 的 AAC/MP3 解碼器**，
/// 而現場要的是離線可用。所以格式限制寫在使用者看得到的訊息裡，
/// 而不是靜靜地回一個 null。
///
/// 對照 `blade_prototype/blade_proto/acoustics.py::_read_wav`：位元深度換算逐一相同
/// （8-bit 是無號數、24-bit 補一個低位元組後當 int32 讀），這樣 Python 算出來的
/// 參考值與 Dart 讀到的樣本同源。
class BladeAudioDecode {
  BladeAudioDecode._();

  /// RIFF 標頭 12 + 最小的 fmt 區塊 24 + data 標頭 8
  static const int minWavBytes = 44;

  static BladeAudioDecodeResult decodeWav(Uint8List bytes) {
    if (bytes.length < minWavBytes) {
      return const BladeAudioDecodeResult.fail(BladeAudioError.tooShort);
    }
    final bd = ByteData.sublistView(bytes);
    if (_tag(bytes, 0) != 'RIFF' || _tag(bytes, 8) != 'WAVE') {
      return const BladeAudioDecodeResult.fail(BladeAudioError.notRiffWave);
    }

    int? format, channels, sampleRate, bits;
    int dataOffset = -1, dataLength = 0;

    // 逐區塊走訪。不假設 fmt 一定在 data 前面，也不假設只有這兩個區塊
    // ——手機錄音程式常插 LIST／fact，寫死偏移量會讀到垃圾。
    var p = 12;
    while (p + 8 <= bytes.length) {
      final id = _tag(bytes, p);
      final size = bd.getUint32(p + 4, Endian.little);
      final body = p + 8;
      if (id == 'fmt ' && body + 16 <= bytes.length) {
        format = bd.getUint16(body, Endian.little);
        channels = bd.getUint16(body + 2, Endian.little);
        sampleRate = bd.getUint32(body + 4, Endian.little);
        bits = bd.getUint16(body + 14, Endian.little);
        // WAVE_FORMAT_EXTENSIBLE：真正的編碼寫在 SubFormat 的前兩個位元組
        if (format == 0xFFFE && body + 26 <= bytes.length) {
          format = bd.getUint16(body + 24, Endian.little);
        }
      } else if (id == 'data') {
        dataOffset = body;
        // 區塊長度可能超出實際檔案（複製中斷、串流寫入未回填標頭）：取實際可讀的
        dataLength = size == 0 || body + size > bytes.length ? bytes.length - body : size;
      }
      if (size <= 0) break; // 長度為 0 的區塊會讓走訪停不下來
      p = body + size + (size.isOdd ? 1 : 0); // RIFF 區塊補齊到偶數位元組
    }

    if (format == null || channels == null || sampleRate == null || bits == null) {
      return const BladeAudioDecodeResult.fail(BladeAudioError.noFmtChunk);
    }
    if (dataOffset < 0) {
      return const BladeAudioDecodeResult.fail(BladeAudioError.noDataChunk);
    }
    if (format != 1) {
      return const BladeAudioDecodeResult.fail(BladeAudioError.unsupportedCodec);
    }
    if (channels < 1 || sampleRate < 1) {
      return const BladeAudioDecodeResult.fail(BladeAudioError.noFmtChunk);
    }
    final bytesPerSample = bits ~/ 8;
    if (bytesPerSample < 1 || bytesPerSample > 4 || bits % 8 != 0) {
      return const BladeAudioDecodeResult.fail(BladeAudioError.unsupportedBitDepth);
    }

    final frameBytes = bytesPerSample * channels;
    final nFrames = dataLength ~/ frameBytes;
    if (nFrames < 1) {
      return const BladeAudioDecodeResult.fail(BladeAudioError.emptyData);
    }

    final out = Float64List(nFrames);
    for (var i = 0; i < nFrames; i++) {
      var acc = 0.0;
      var base = dataOffset + i * frameBytes;
      for (var c = 0; c < channels; c++) {
        acc += _sampleAt(bd, base, bytesPerSample);
        base += bytesPerSample;
      }
      out[i] = acc / channels;
    }
    return BladeAudioDecodeResult.ok(
        BladeAudioClip(samples: out, sampleRate: sampleRate));
  }

  /// 單一樣本 → -1..1。換算與 `_read_wav` 逐一對照。
  static double _sampleAt(ByteData bd, int at, int width) {
    switch (width) {
      case 1: // 8-bit WAV 是無號數
        return (bd.getUint8(at) - 128.0) / 128.0;
      case 2:
        return bd.getInt16(at, Endian.little) / 32768.0;
      case 3:
        // Python 是「補一個低位元組後當 int32 讀」，等於 24-bit 值左移 8 位。
        // 直接算 int24/2^23 會差一個 2^-8 的尾數，逐點比對就對不上了。
        final v = (bd.getUint8(at) << 8) |
            (bd.getUint8(at + 1) << 16) |
            (bd.getUint8(at + 2) << 24);
        return v.toSigned(32) / 2147483648.0;
      default:
        return bd.getInt32(at, Endian.little) / 2147483648.0;
    }
  }

  static String _tag(Uint8List b, int at) =>
      String.fromCharCodes(b, at, at + 4);
}
