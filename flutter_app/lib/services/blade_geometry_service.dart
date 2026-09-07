import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'blade_image_ops.dart';

/// 局部天空模型：背景與尺度都是**影像場**，不是參數化曲面。
///
/// 對照 `blade_prototype/blade_proto/segmentation.py::LocalSkyModel`。
/// 兩個場都在工作尺度上算，套用時雙線性放大回全解析度——它們本來就是低頻的
/// （核邊長是畫面的 20%）；殘差則在全解析度上取，1–2 px 的葉尖因此保得住。
class BladeSkyModel {
  /// 交錯的 Lab 背景估計（L,a,b），工作尺度
  final Float32List bg;

  /// 同尺度的各通道局部 robust 尺度
  final Float32List scale;
  final int w;
  final int h;
  final int kernelPx;
  final double minScale;

  const BladeSkyModel({
    required this.bg,
    required this.scale,
    required this.w,
    required this.h,
    required this.kernelPx,
    required this.minScale,
  });
}

class BladeSegmentation {
  final Uint8List mask; // 0 / 255
  final int w;
  final int h;
  final double threshold;

  /// 地平線列；null = 畫面沒有可辨識的地面帶
  final int? horizonY;
  final BladeSkyModel model;

  const BladeSegmentation({
    required this.mask,
    required this.w,
    required this.h,
    required this.threshold,
    required this.horizonY,
    required this.model,
  });

  double get maskAreaFrac {
    var n = 0;
    for (final v in mask) {
      if (v != 0) n++;
    }
    return n / (w * h);
  }
}

/// 分割與結構定位的參數。預設值全部與 Python 原型一致。
class BladeGeometryParams {
  /// 中值核邊長 / 工作尺度長邊。要 > 塔架寬、< 雲塊尺度。
  final double kernelFrac;

  /// 局部 robust sigma 單位的距離門檻
  final double distThresh;

  /// 估背景與尺度的工作尺度長邊
  final int workSide;

  /// 局部尺度下限（OpenCV 8-bit Lab 單位），純色天空不會除以 0
  final double minScale;

  /// |殘差| 量化成 uint8 的增益
  final double scaleGain;

  /// 中值只在此間隔的網格點上算（見 `BladeImageOps.medianFieldGrid`）
  final int gridStep;

  /// 元件最小面積 / 畫面面積
  final double minAreaFrac;

  /// 葉片最小面積 / 畫面面積
  final double minBladeAreaFrac;

  const BladeGeometryParams({
    this.kernelFrac = 0.20,
    this.distThresh = 7.0,
    this.workSide = 1024,
    this.minScale = 1.2,
    this.scaleGain = 4.0,
    this.gridStep = 16,
    this.minAreaFrac = 3e-4,
    this.minBladeAreaFrac = 2e-4,
  });
}

/// 幾何層：分割 + 結構定位（規格 §5.1 / §5.3）。
///
/// `blade_prototype/blade_proto/segmentation.py` 的 Dart 對照實作。門檻、邊界處理、
/// 距離變換的近似方式全部與 Python 一致——參考值由
/// `blade_prototype/scripts/make_geometry_fixture.py` 凍結，逐階段對照。
///
/// **與表面層的兩個關鍵差異**：
/// 1. 色空間用 OpenCV 的 8-bit Lab（見 `BladeImageOps`），因為 `minScale` 是那個
///    空間裡的絕對下限、而大核中值必須跑在 uint8 上。
/// 2. 中值只在網格點上算（`gridStep`）。逐像素在手機上跑不動；真實照片實測的代價是
///    設計範圍內 30 張的輪轂命中 23 → 22。
class BladeGeometryService {
  BladeGeometryService._();

  // ------------------------------------------------------- 天空模型

  /// 估局部天空模型：背景 = Lab 的大核中值，尺度 = |殘差| 的同核中值。
  ///
  /// 中值核是關鍵：它抹掉**比核窄**的東西、保留比核寬的東西。核邊長取工作尺度的
  /// 20% 時，塔架與葉片（幾十像素）被抹掉而留在殘差裡，雲塊（幾百像素）被算進背景
  /// 而不再產生殘差。尺度用同一個鄰域，所以雲區的尺度自然放大——葉片相對「該區的
  /// 天空」仍然突出，遮罩不會因為畫面有雲就整片空掉。
  static BladeSkyModel fitLocalSky(
    img.Image src, {
    BladeGeometryParams params = const BladeGeometryParams(),
  }) {
    final small = BladeImageOps.downscaleArea(src, params.workSide);
    final w = small.width, h = small.height;
    final lab = BladeImageOps.toLab8(small);

    var k = (params.kernelFrac * math.max(w, h)).round() | 1;
    k = k.clamp(5, 255);

    final bg = BladeImageOps.medianFieldGrid(lab, w, h, 3, k, params.gridStep);

    // |殘差| 量化成 uint8 才能走直方圖中值；×gain 再除回來，
    // 讓 0–64 Lab 單位的殘差有 1/gain 的解析度（與 Python 一致）
    final absr = Uint8List(w * h * 3);
    for (var i = 0; i < absr.length; i++) {
      final d = (lab[i] - bg[i]).abs() * params.scaleGain;
      absr[i] = d <= 0 ? 0 : (d >= 255 ? 255 : (d + 0.5).floor());
    }
    final scaleField =
        BladeImageOps.medianFieldGrid(absr, w, h, 3, k, params.gridStep);
    for (var i = 0; i < scaleField.length; i++) {
      final v = scaleField[i] / params.scaleGain * 1.4826;
      scaleField[i] = v < params.minScale ? params.minScale : v;
    }
    return BladeSkyModel(
      bg: bg,
      scale: scaleField,
      w: w,
      h: h,
      kernelPx: k,
      minScale: params.minScale,
    );
  }

  /// 全解析度殘差 ÷ 放大回全解析度的低頻場。
  static Float32List localSkyDistance(img.Image src, BladeSkyModel model) {
    final w = src.width, h = src.height;
    final lab = BladeImageOps.toLab8(src);
    Float32List bg = model.bg, scale = model.scale;
    if (model.w != w || model.h != h) {
      bg = _resizeBilinear(model.bg, model.w, model.h, 3, w, h);
      scale = _resizeBilinear(model.scale, model.w, model.h, 3, w, h);
    }
    final out = Float32List(w * h);
    for (var i = 0; i < w * h; i++) {
      final o = i * 3;
      var sum = 0.0;
      for (var c = 0; c < 3; c++) {
        final s = math.max(scale[o + c], model.minScale);
        final d = (lab[o + c] - bg[o + c]) / s;
        sum += d * d;
      }
      out[i] = math.sqrt(sum);
    }
    return out;
  }

  /// 交錯多通道場的雙線性放大。用 OpenCV `INTER_LINEAR` 的半像素慣例：
  /// `src = (dst + 0.5) * scale - 0.5`，夾到值域內。
  static Float32List _resizeBilinear(
      Float32List src, int sw, int sh, int ch, int dw, int dh) {
    final out = Float32List(dw * dh * ch);
    final fx = sw / dw, fy = sh / dh;
    for (var y = 0; y < dh; y++) {
      var syf = (y + 0.5) * fy - 0.5;
      if (syf < 0) syf = 0;
      if (syf > sh - 1) syf = sh - 1.0;
      final y0 = syf.floor(), y1 = math.min(y0 + 1, sh - 1);
      final ty = syf - y0;
      for (var x = 0; x < dw; x++) {
        var sxf = (x + 0.5) * fx - 0.5;
        if (sxf < 0) sxf = 0;
        if (sxf > sw - 1) sxf = sw - 1.0;
        final x0 = sxf.floor(), x1 = math.min(x0 + 1, sw - 1);
        final tx = sxf - x0;
        final o = (y * dw + x) * ch;
        for (var c = 0; c < ch; c++) {
          final a = src[(y0 * sw + x0) * ch + c];
          final b = src[(y0 * sw + x1) * ch + c];
          final cc = src[(y1 * sw + x0) * ch + c];
          final d = src[(y1 * sw + x1) * ch + c];
          out[o + c] = (a * (1 - tx) + b * tx) * (1 - ty) +
              (cc * (1 - tx) + d * tx) * ty;
        }
      }
    }
    return out;
  }

  // ------------------------------------------------------- 分割

  /// 把風機（葉片 + 塔架 + 機艙）從天空分出來。
  static BladeSegmentation segmentTurbine(
    img.Image src, {
    BladeGeometryParams params = const BladeGeometryParams(),
    BladeSkyModel? model,
  }) {
    final w = src.width, h = src.height;
    final m = model ?? fitLocalSky(src, params: params);
    // 距離圖先做 σ0.8 高斯平滑再取門檻：孤立雜訊像素被壓下去、邊界變平滑，
    // 而 1 px 寬的葉尖線會變成 2 px 寬的較低值仍高於門檻
    final dist =
        BladeImageOps.gaussianBlur(localSkyDistance(src, m), w, h, 0.8);
    final fg = Uint8List(w * h);
    for (var i = 0; i < fg.length; i++) {
      fg[i] = dist[i] > params.distThresh ? 255 : 0;
    }
    final mask = _cleanMask(fg, w, h, (params.minAreaFrac * w * h).toInt());
    return BladeSegmentation(
      mask: mask,
      w: w,
      h: h,
      threshold: params.distThresh,
      horizonY: findHorizon(mask, w, h),
      model: m,
    );
  }

  /// 形態學清理 + 元件過濾。對照 `_clean_mask`。
  ///
  /// **不做 open**：遠距／側視的葉尖只有 1–2 px 厚，open 會把它整條吃掉讓葉尖半徑
  /// 忽長忽短；雜訊碎片交給面積過濾。close 只補洞。
  static Uint8List _cleanMask(Uint8List fg, int w, int h, int minArea,
      {double maxWidthFrac = 0.7, bool dropWideBands = true}) {
    final closed = BladeImageOps.closeEllipse5(fg, w, h);
    final cc = BladeImageOps.connectedComponents(closed, w, h);
    final keep = List<bool>.filled(cc.count, false);
    for (var i = 1; i < cc.count; i++) {
      final s = cc.stats[i];
      if (s.area < minArea) continue;
      // 橫跨畫面的地面/地平線帶
      if (dropWideBands && s.width > maxWidthFrac * w && s.height < 0.5 * h) {
        continue;
      }
      keep[i] = true;
    }
    final out = Uint8List(w * h);
    for (var i = 0; i < out.length; i++) {
      out[i] = keep[cc.labels[i]] ? 255 : 0;
    }
    return out;
  }

  /// 找地面帶的上緣（地平線列）。由畫面底部往上走，只要該列前景填充率高就繼續。
  ///
  /// 真實照片的地面常常和塔架連成同一個元件，「寬而矮」的規則抓不到；
  /// 但它有另一個穩定特徵：**整列幾乎都是前景**。
  static int? findHorizon(
    Uint8List mask,
    int w,
    int h, {
    double fillThresh = 0.55,
    int gapRows = 6,
    double minSkyFrac = 0.25,
    double minBandFrac = 0.02,
  }) {
    final fill = Float32List(h);
    for (var y = 0; y < h; y++) {
      var n = 0;
      final row = y * w;
      for (var x = 0; x < w; x++) {
        if (mask[row + x] != 0) n++;
      }
      fill[y] = n / w;
    }
    final sm = _median1d(fill, 5);
    int? top;
    var miss = 0;
    for (var y = h - 1; y >= 0; y--) {
      if (sm[y] >= fillThresh) {
        top = y;
        miss = 0;
      } else {
        miss++;
        if (miss > gapRows) break;
      }
    }
    if (top == null) return null;
    final band = (h - top) / h;
    if (band < minBandFrac || band > 1.0 - minSkyFrac) return null;
    return top;
  }

  /// 1D 中值濾波（對照 `cv2.medianBlur` 對 (n,1) 的行為，邊界 REPLICATE）
  static Float32List _median1d(Float32List src, int k) {
    final n = src.length;
    final out = Float32List(n);
    final r = k ~/ 2;
    final buf = List<double>.filled(k, 0);
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < k; j++) {
        final s = (i + j - r).clamp(0, n - 1);
        buf[j] = src[s];
      }
      buf.sort();
      out[i] = buf[r];
    }
    return out;
  }
}
