import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

/// 影像品質門檻（可調；建議依實機現場照片校準）
///
/// [minSharpness] 為 Laplacian 響應的變異數。為使不同解析度可比較，
/// 分析前一律把影像縮到最長邊 [ImageQualityService.analysisMaxSide]。
class ImageQualityThresholds {
  final double minSharpness;
  final double minBrightness;
  final double maxBrightness;
  final double maxOverexposedRatio;
  final double maxUnderexposedRatio;

  const ImageQualityThresholds({
    this.minSharpness = 60.0,
    this.minBrightness = 45.0,
    this.maxBrightness = 228.0,
    this.maxOverexposedRatio = 0.18,
    this.maxUnderexposedRatio = 0.40,
  });
}

/// 單一品質問題
enum ImageQualityIssue { undecodable, blurry, tooDark, tooBright, glare }

extension ImageQualityIssueText on ImageQualityIssue {
  /// 現場可執行的具體建議（不只說「不合格」，要說怎麼補救）
  String get advice {
    switch (this) {
      case ImageQualityIssue.undecodable:
        return '無法讀取這張照片，請重新拍攝';
      case ImageQualityIssue.blurry:
        return '畫面可能模糊，請對焦後重拍（可先點螢幕對焦、雙手持穩）';
      case ImageQualityIssue.tooDark:
        return '光線不足，請開手電筒補光或靠近拍攝';
      case ImageQualityIssue.tooBright:
        return '畫面過亮，請避開直射光源或降低曝光';
      case ImageQualityIssue.glare:
        return '錶面反光嚴重，請側身變換角度避開反光';
    }
  }
}

/// 影像品質評估結果
class ImageQualityReport {
  /// Laplacian 響應變異數，越高越銳利
  final double sharpness;

  /// 平均亮度 0–255
  final double brightness;

  /// 接近全白（>250）的像素比例 0–1，用來偵測反光/過曝
  final double overexposedRatio;

  /// 接近全黑（<15）的像素比例 0–1
  final double underexposedRatio;

  final List<ImageQualityIssue> issues;

  const ImageQualityReport({
    required this.sharpness,
    required this.brightness,
    required this.overexposedRatio,
    required this.underexposedRatio,
    required this.issues,
  });

  factory ImageQualityReport.undecodable() => const ImageQualityReport(
        sharpness: 0,
        brightness: 0,
        overexposedRatio: 0,
        underexposedRatio: 0,
        issues: [ImageQualityIssue.undecodable],
      );

  bool get isAcceptable => issues.isEmpty;

  /// 給使用者看的建議（多個問題時合併）
  String get advice => issues.map((i) => i.advice).join('\n');

  /// 除錯/稽核用的量化摘要
  String get metrics =>
      '銳利度 ${sharpness.toStringAsFixed(1)}｜亮度 ${brightness.toStringAsFixed(0)}'
      '｜過曝 ${(overexposedRatio * 100).toStringAsFixed(0)}%'
      '｜過暗 ${(underexposedRatio * 100).toStringAsFixed(0)}%';

  @override
  String toString() => 'ImageQualityReport($metrics, issues: $issues)';
}

/// 拍照品質閘門（Tier 0 思路：純本機、零 AI、零網路、可完整單元測試）
///
/// 現場環境惡劣時（手震、光線不足、錶面反光）拍出的照片，AI 可能讀出
/// 錯誤數值卻仍被當成正常讀值送去法規判定。此服務在照片進入分析前先擋下，
/// 直接請使用者重拍——比事後發現判定錯誤便宜得多。
class ImageQualityService {
  ImageQualityService._();

  /// 分析前統一縮到此最長邊：加速，並讓不同解析度的銳利度分數可互相比較。
  ///
  /// 註：預設門檻是以「經過 average 內插降採樣」的影像校準的。App 的
  /// image_picker 上限為 1920×1080，實務上所有現場照片都會走到降採樣路徑；
  /// 若餵入本身就 ≤512px 的小圖則不會重採樣，分數會略偏高。
  static const int analysisMaxSide = 512;

  /// 非同步評估（在 isolate 執行，避免阻塞 UI）
  static Future<ImageQualityReport> assess(Uint8List bytes) =>
      compute(_assessIsolate, bytes);

  static ImageQualityReport _assessIsolate(Uint8List bytes) => assessSync(bytes);

  /// 同步評估（測試用，或已在背景 isolate 時直接呼叫）
  static ImageQualityReport assessSync(
    Uint8List bytes, {
    ImageQualityThresholds thresholds = const ImageQualityThresholds(),
  }) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return ImageQualityReport.undecodable();

    final small = _downscale(decoded, analysisMaxSide);
    final w = small.width;
    final h = small.height;
    if (w < 3 || h < 3) return ImageQualityReport.undecodable();

    // 亮度圖（0–255）
    final lum = Float64List(w * h);
    double sum = 0;
    int over = 0;
    int under = 0;
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final v = img.getLuminance(small.getPixel(x, y)).toDouble();
        lum[y * w + x] = v;
        sum += v;
        if (v > 250) over++;
        if (v < 15) under++;
      }
    }
    final pixels = w * h;
    final brightness = sum / pixels;
    final overRatio = over / pixels;
    final underRatio = under / pixels;

    // Laplacian 3x3 kernel [0,1,0; 1,-4,1; 0,1,0] 響應的變異數 → 銳利度
    double rSum = 0;
    double rSqSum = 0;
    int n = 0;
    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        final i = y * w + x;
        final r = lum[i - w] + lum[i + w] + lum[i - 1] + lum[i + 1] - 4 * lum[i];
        rSum += r;
        rSqSum += r * r;
        n++;
      }
    }
    final mean = rSum / n;
    final sharpness = math.max(0.0, rSqSum / n - mean * mean);

    final issues = <ImageQualityIssue>[];
    if (sharpness < thresholds.minSharpness) issues.add(ImageQualityIssue.blurry);
    if (brightness < thresholds.minBrightness ||
        underRatio > thresholds.maxUnderexposedRatio) {
      issues.add(ImageQualityIssue.tooDark);
    }
    if (brightness > thresholds.maxBrightness) {
      issues.add(ImageQualityIssue.tooBright);
    }
    // 整體不算太亮、但有大片死白 → 局部反光（錶面眩光的典型樣態）
    if (overRatio > thresholds.maxOverexposedRatio &&
        brightness <= thresholds.maxBrightness) {
      issues.add(ImageQualityIssue.glare);
    }

    return ImageQualityReport(
      sharpness: sharpness,
      brightness: brightness,
      overexposedRatio: overRatio,
      underexposedRatio: underRatio,
      issues: issues,
    );
  }

  /// 等比縮到最長邊 <= [maxSide]；已夠小則原樣回傳。
  /// 用 average（盒狀）內插，避免 nearest 的鋸齒被誤判為「銳利」。
  static img.Image _downscale(img.Image src, int maxSide) {
    final longest = math.max(src.width, src.height);
    if (longest <= maxSide) return src;
    final scale = maxSide / longest;
    return img.copyResize(
      src,
      width: math.max(1, (src.width * scale).round()),
      height: math.max(1, (src.height * scale).round()),
      interpolation: img.Interpolation.average,
    );
  }
}
