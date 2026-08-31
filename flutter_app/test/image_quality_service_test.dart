import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:induspect_ai/services/image_quality_service.dart';

/// ImageQualityService（拍照品質閘門）測試
///
/// 以合成影像涵蓋現場惡劣環境的四種樣態：手震模糊、光線不足、
/// 整體過曝、錶面局部反光。全部為純本機運算，無需裝置或網路。

/// 均勻雜訊：高頻細節多 → 銳利、亮度居中（代表一張正常清楚的照片）
Uint8List _noise({int w = 400, int h = 300, int lo = 60, int hi = 200, int seed = 7}) {
  final rnd = Random(seed);
  final im = img.Image(width: w, height: h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final v = lo + rnd.nextInt(hi - lo + 1);
      im.setPixelRgb(x, y, v, v, v);
    }
  }
  return Uint8List.fromList(img.encodePng(im));
}

/// 純色塊（無細節）→ 模糊；亮度由 [v] 決定
Uint8List _solid(int v, {int w = 400, int h = 300}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(v, v, v));
  return Uint8List.fromList(img.encodePng(im));
}

/// 棋盤格：邊緣極多 → 非常銳利
Uint8List _checker({int w = 400, int h = 300, int cell = 8}) {
  final im = img.Image(width: w, height: h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final on = ((x ~/ cell) + (y ~/ cell)) % 2 == 0;
      final v = on ? 210 : 40;
      im.setPixelRgb(x, y, v, v, v);
    }
  }
  return Uint8List.fromList(img.encodePng(im));
}

/// 對同一張影像做高斯模糊 → 模擬手震/失焦
Uint8List _blurred(Uint8List src, {int radius = 12}) {
  final im = img.decodeImage(src)!;
  return Uint8List.fromList(img.encodePng(img.gaussianBlur(im, radius: radius)));
}

/// 清楚的底圖 + 一大塊死白 → 模擬錶面局部反光
Uint8List _withGlare(double coverage) {
  final im = img.decodeImage(_noise())!;
  final blockW = (im.width * coverage).round();
  img.fillRect(im,
      x1: 0, y1: 0, x2: blockW - 1, y2: im.height - 1,
      color: img.ColorRgb8(255, 255, 255));
  return Uint8List.fromList(img.encodePng(im));
}

void main() {
  group('正常照片', () {
    test('清楚、亮度居中 → 通過', () {
      final r = ImageQualityService.assessSync(_noise());
      expect(r.isAcceptable, true, reason: r.toString());
      expect(r.issues, isEmpty);
      expect(r.brightness, inInclusiveRange(60, 200));
    });

    test('棋盤格（大量邊緣）銳利度遠高於門檻', () {
      final r = ImageQualityService.assessSync(_checker());
      expect(r.sharpness, greaterThan(60.0));
      expect(r.issues, isNot(contains(ImageQualityIssue.blurry)));
    });
  });

  group('模糊偵測', () {
    test('高斯模糊後的同一張圖 → 判為模糊', () {
      final sharp = _checker();
      final blurry = _blurred(sharp);

      final rs = ImageQualityService.assessSync(sharp);
      final rb = ImageQualityService.assessSync(blurry);

      expect(rb.sharpness, lessThan(rs.sharpness),
          reason: '模糊後銳利度必須下降');
      expect(rb.issues, contains(ImageQualityIssue.blurry));
      expect(rb.isAcceptable, false);
    });

    test('純色塊（完全無細節）→ 判為模糊', () {
      final r = ImageQualityService.assessSync(_solid(128));
      expect(r.sharpness, lessThan(1.0));
      expect(r.issues, contains(ImageQualityIssue.blurry));
    });

    test('建議文字可執行（含對焦提示）', () {
      final r = ImageQualityService.assessSync(_solid(128));
      expect(r.advice, contains('對焦'));
    });
  });

  group('曝光偵測', () {
    test('過暗 → tooDark', () {
      final r = ImageQualityService.assessSync(_noise(lo: 0, hi: 20));
      expect(r.issues, contains(ImageQualityIssue.tooDark));
      expect(r.advice, contains('補光'));
    });

    test('整體過亮 → tooBright', () {
      final r = ImageQualityService.assessSync(_noise(lo: 240, hi: 255));
      expect(r.issues, contains(ImageQualityIssue.tooBright));
    });

    test('亮度居中不應誤判曝光', () {
      final r = ImageQualityService.assessSync(_noise());
      expect(r.issues, isNot(contains(ImageQualityIssue.tooDark)));
      expect(r.issues, isNot(contains(ImageQualityIssue.tooBright)));
    });
  });

  group('反光偵測（局部死白）', () {
    test('40% 面積死白且整體不算過亮 → glare', () {
      final r = ImageQualityService.assessSync(_withGlare(0.40));
      expect(r.overexposedRatio, greaterThan(0.18));
      expect(r.issues, contains(ImageQualityIssue.glare));
      expect(r.advice, contains('反光'));
    });

    test('僅 5% 死白（正常高光）→ 不觸發 glare', () {
      final r = ImageQualityService.assessSync(_withGlare(0.05));
      expect(r.issues, isNot(contains(ImageQualityIssue.glare)));
    });
  });

  group('防呆與門檻', () {
    test('無法解碼的位元組 → undecodable 且不可接受', () {
      final r = ImageQualityService.assessSync(
        Uint8List.fromList(List.generate(64, (i) => i)),
      );
      expect(r.isAcceptable, false);
      expect(r.issues, contains(ImageQualityIssue.undecodable));
      expect(r.advice, contains('重新拍攝'));
    });

    test('門檻可調：放寬後原本模糊的圖可通過', () {
      final blurry = _blurred(_checker());
      final strict = ImageQualityService.assessSync(blurry);
      final loose = ImageQualityService.assessSync(
        blurry,
        thresholds: const ImageQualityThresholds(minSharpness: 0.5),
      );
      expect(strict.issues, contains(ImageQualityIssue.blurry));
      expect(loose.issues, isNot(contains(ImageQualityIssue.blurry)));
    });

    test('相同內容不同拍攝解析度 → 銳利度分數相近（可跨機型比較）', () {
      // 兩張圖的格子都是寬度的 1/64，降採樣到 512 後幾何完全相同；
      // 兩者都會經過 average 內插，因此分數應該非常接近。
      final r1024 = ImageQualityService.assessSync(_checker(w: 1024, h: 768, cell: 16));
      final r2048 = ImageQualityService.assessSync(_checker(w: 2048, h: 1536, cell: 32));
      final ratio = r2048.sharpness / r1024.sharpness;
      expect(ratio, inInclusiveRange(0.7, 1.4),
          reason: '同一畫面用不同解析度拍，銳利度分數不應明顯漂移');
    });

    test('metrics 摘要含四項量化指標', () {
      final r = ImageQualityService.assessSync(_noise());
      expect(r.metrics, contains('銳利度'));
      expect(r.metrics, contains('亮度'));
      expect(r.metrics, contains('過曝'));
      expect(r.metrics, contains('過暗'));
    });
  });
}
