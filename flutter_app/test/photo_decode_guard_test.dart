import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:induspect_ai/services/image_service.dart';
import 'package:induspect_ai/services/photo_service.dart';

/// 兩個照片服務在**無法解碼**時，要交出它們自己文件寫的那個結果，
/// 而不是漏出解碼器內部的 `RangeError`。
///
/// 這兩處原本都有 try/catch，所以**不是在修崩潰**——差別在「呼叫端看到什麼」：
///
/// - `ImageService._processAndSaveImage` 原本 `rethrow`，於是拍照流程收到的是
///   `RangeError: Value not in range: 6`，而不是 `Exception('Failed to decode image')`。
/// - `PhotoService.compressPhoto` 原本會走到外層 catch，紀錄印出
///   「Compress failed: RangeError...」而不是「Failed to decode」——
///   看紀錄的人會以為是壓縮壞了，實際上是檔案不完整。
///
/// 兩個方法都在解碼失敗時就結束，不會碰到檔案系統，所以這裡測得起來
/// （不需要 path_provider 的 mock）。
void main() {
  Uint8List realJpeg() {
    final im = img.Image(width: 12, height: 9);
    for (var y = 0; y < 9; y++) {
      for (var x = 0; x < 12; x++) {
        im.setPixelRgb(x, y, x * 20, y * 25, 90);
      }
    }
    return Uint8List.fromList(img.encodeJpg(im, quality: 90));
  }

  final broken = <String, Uint8List>{
    '空位元組': Uint8List(0),
    '3 bytes': Uint8List.fromList([1, 2, 3]),
    '長度過關但不是影像': Uint8List.fromList(List<int>.filled(40, 7)),
    '純文字': Uint8List.fromList('definitely not an image'.codeUnits),
  };

  group('PhotoService.compressPhoto', () {
    test('壞掉的位元組回原始位元組，不丟例外', () async {
      final svc = PhotoService();
      for (final entry in broken.entries) {
        final out = await svc.compressPhoto(entry.value);
        expect(out, same(entry.value),
            reason: '${entry.key}：文件寫的是「回原圖」');
      }
    });

    test('真的影像會被壓縮（確認守門沒把好檔案也擋掉）', () async {
      final src = realJpeg();
      final out = await PhotoService().compressPhoto(src, maxWidth: 6, maxHeight: 6);
      expect(out.lengthInBytes, greaterThan(0));
      final decoded = img.decodeImage(out);
      expect(decoded, isNotNull);
      expect(decoded!.width, lessThanOrEqualTo(6));
    });
  });

  group('ImageService.compressAndSaveImageFromBytes', () {
    test('壞掉的位元組丟「Failed to decode image」，不是 RangeError', () async {
      final svc = ImageService();
      for (final entry in broken.entries) {
        await expectLater(
          () => svc.compressAndSaveImageFromBytes(entry.value),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('Failed to decode image'),
            ),
          ),
          reason: '${entry.key}：呼叫端要看得懂錯在哪',
        );
      }
    });

    test('丟的不是 RangeError（那是解碼器的內部細節漏出來）', () async {
      try {
        await ImageService().compressAndSaveImageFromBytes(
            Uint8List.fromList([1, 2, 3]));
        fail('應該要丟例外');
      } catch (e) {
        expect(e, isNot(isA<RangeError>()));
        expect(e.toString(), contains('Failed to decode image'));
      }
    });
  });
}
