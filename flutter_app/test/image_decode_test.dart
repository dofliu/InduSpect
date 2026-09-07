import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:induspect_ai/utils/image_decode.dart';

/// `safeDecodeImage` 的測試。
///
/// 這支 helper 存在的唯一理由是：`package:image` 的 `decodeImage` **會丟例外，
/// 不只回 null**。位元組太短時它在格式嗅探階段就 `RangeError`（GIF 的
/// `isValidFile` 讀字串讀過界），那時連格式都還沒判斷出來。
/// 所以下面每一條都在驗「不丟例外」，而不只是「回 null」。
void main() {
  /// 真的 PNG，用來確認 helper 沒有把好檔案也擋掉
  Uint8List realPng() {
    final im = img.Image(width: 8, height: 6);
    for (var y = 0; y < 6; y++) {
      for (var x = 0; x < 8; x++) {
        im.setPixelRgb(x, y, x * 30, y * 40, 100);
      }
    }
    return Uint8List.fromList(img.encodePng(im));
  }

  test('真的 PNG 解得回來，尺寸正確', () {
    final decoded = safeDecodeImage(realPng());
    expect(decoded, isNotNull);
    expect(decoded!.width, 8);
    expect(decoded.height, 6);
  });

  test('極短的位元組回 null，不丟例外（decodeImage 在這裡會 RangeError）', () {
    for (final n in [0, 1, 2, 3, 6, 8, 15]) {
      final bytes = Uint8List.fromList(List<int>.filled(n, 7));
      expect(safeDecodeImage(bytes), isNull, reason: '長度 $n');
    }
  });

  test('長度過關但內容不是影像 → 走 try/catch 那條路，同樣回 null', () {
    // 40 bytes 超過 minDecodableBytes，所以這條測的是 catch 而不是長度守門
    expect(minDecodableBytes, lessThan(40));
    for (final bytes in [
      Uint8List.fromList(List<int>.filled(40, 7)),
      Uint8List.fromList(List<int>.generate(200, (i) => i % 256)),
      Uint8List.fromList('not an image at all, just plain text'.codeUnits),
    ]) {
      expect(safeDecodeImage(bytes), isNull,
          reason: '長度 ${bytes.length}');
    }
  });

  test('截斷的 PNG（只保留前半）回 null，不丟例外', () {
    final full = realPng();
    for (final frac in [0.2, 0.5, 0.8, 0.95]) {
      final cut = Uint8List.sublistView(full, 0, (full.length * frac).floor());
      // 截斷的 PNG 可能解得出部分、也可能失敗——要求的只有「不丟例外」
      expect(() => safeDecodeImage(cut), returnsNormally,
          reason: '保留 ${(frac * 100).toStringAsFixed(0)}%');
    }
  });

  test('minDecodableBytes 是保守值：比最短的格式標頭大', () {
    // PNG 8 / JPEG 2 / GIF 6 bytes——16 都涵蓋得住
    expect(minDecodableBytes, greaterThanOrEqualTo(8));
  });
}
