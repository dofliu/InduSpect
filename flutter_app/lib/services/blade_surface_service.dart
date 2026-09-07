import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import 'blade_image_ops.dart';

/// 表面層分析（規格 §5.2）— `blade_prototype/blade_proto/surface.py` 的 Dart 對照實作。
///
/// 輸入是**長焦分區段照**：一段葉片橫越畫面。這條路徑用的是原本的「邊緣取樣 + 逐列
/// 多項式」天空模型，不是幾何層那個大核中值的局部模型——分區段照的葉片本身就佔滿
/// 畫面，大核中值會把葉片算進背景。這也是規格 §9 把表面層排在幾何層之前的原因：
/// 它移植得動，幾何層的局部模型留在 Phase 2。
///
/// 參數預設值與 Python 原型一致，數值可直接互相對照（見 `test/blade_surface_service_test.dart`）。

/// 一條邊緣的粗糙度指標
class BladeEdgeRoughness {
  /// 'top' | 'bottom'
  final String edge;
  final int nSamples;

  /// 基線殘差的 rms（px）。整體粗糙度。
  final double rmsPx;
  final double? rmsCm;

  /// 往葉片內部凹的深度 p95（px）。材料流失看這個，不看雙向的 rms。
  final double inwardP95Px;

  /// 連續 ≥2 個取樣點超過 pitSigma 倍 robust sigma 的凹坑數
  final int pitCount;

  /// 高頻能量占比（週期 < hfPeriodPx 的成分）。侵蝕是高頻、彎曲是低頻。
  final double highFreqRatio;

  /// 沿畫面 x 分三段的 rms 與紋理標準差（對應根/中/尖的區段映射）
  final List<double> zoneRmsPx;
  final List<double> zoneTextureStd;

  const BladeEdgeRoughness({
    required this.edge,
    required this.nSamples,
    required this.rmsPx,
    this.rmsCm,
    required this.inwardP95Px,
    required this.pitCount,
    required this.highFreqRatio,
    required this.zoneRmsPx,
    required this.zoneTextureStd,
  });

  Map<String, dynamic> toJson() => {
        'edge': edge,
        'n_samples': nSamples,
        'rms_px': rmsPx,
        if (rmsCm != null) 'rms_cm': rmsCm,
        'inward_p95_px': inwardP95Px,
        'pit_count': pitCount,
        'high_freq_ratio': highFreqRatio,
        'zone_rms_px': zoneRmsPx,
        'zone_texture_std': zoneTextureStd,
      };
}

/// 一張分區段照的分析結果
class BladeSurfaceAnalysis {
  final bool ok;

  /// 失敗原因（現場可執行的說法，不只說「失敗」）
  final String? failure;
  final double axisAngleDeg;

  /// 旋轉**之後**遮罩的主軸角度。應該 ≈ 0——這是「有沒有真的轉正」的唯一外部
  /// 可驗證量。旋轉符號寫反會把傾角加倍，而多項式基線會把傾斜吸收掉，
  /// 粗糙度看起來仍然正常；只有這個量會露出馬腳。
  final double residualAxisAngleDeg;
  final double medianThicknessPx;
  final BladeEdgeRoughness? top;
  final BladeEdgeRoughness? bottom;

  /// 前緣在畫面哪一側（'top' | 'bottom'），由呼叫端指定
  final String? leadingEdge;

  const BladeSurfaceAnalysis({
    required this.ok,
    this.failure,
    this.axisAngleDeg = 0,
    this.residualAxisAngleDeg = 0,
    this.medianThicknessPx = 0,
    this.top,
    this.bottom,
    this.leadingEdge,
  });

  factory BladeSurfaceAnalysis.failed(String reason) =>
      BladeSurfaceAnalysis(ok: false, failure: reason);

  BladeEdgeRoughness? get leadingEdgeRoughness =>
      leadingEdge == 'top' ? top : (leadingEdge == 'bottom' ? bottom : null);

  BladeEdgeRoughness? get trailingEdgeRoughness =>
      leadingEdge == 'top' ? bottom : (leadingEdge == 'bottom' ? top : null);

  /// 前緣／後緣 rms 比。前緣侵蝕的主要判據——**同一張照片內互比**，
  /// 所以不需要絕對校準，也不受相機、距離、光線影響。
  double? get leOverTeRmsRatio {
    final le = leadingEdgeRoughness, te = trailingEdgeRoughness;
    if (le == null || te == null) return null;
    return le.rmsPx / math.max(te.rmsPx, 1e-6);
  }

  Map<String, dynamic> toJson() => {
        'ok': ok,
        if (failure != null) 'failure': failure,
        'axis_angle_deg': axisAngleDeg,
        'residual_axis_angle_deg': residualAxisAngleDeg,
        'median_thickness_px': medianThicknessPx,
        if (leadingEdge != null) 'leading_edge': leadingEdge,
        if (top != null) 'top': top!.toJson(),
        if (bottom != null) 'bottom': bottom!.toJson(),
        if (leOverTeRmsRatio != null) 'le_over_te_rms_ratio': leOverTeRmsRatio,
      };
}

/// 分析參數。預設值與 Python 原型的 `analyze_blade_edges` 一致。
class BladeSurfaceParams {
  final double? cmPerPx;
  final String? leadingEdge; // 'top' | 'bottom'
  final int polyDeg;
  final double hfPeriodPx;
  final double pitSigma;
  final int bandOffsetPx;
  final double distThresh; // 天空距離門檻（robust sigma）
  final int maxSide;

  const BladeSurfaceParams({
    this.cmPerPx,
    this.leadingEdge,
    this.polyDeg = 3,
    this.hfPeriodPx = 20.0,
    this.pitSigma = 2.5,
    this.bandOffsetPx = 3,
    this.distThresh = 5.5,
    this.maxSide = 1600,
  });
}

class _Request {
  final Uint8List bytes;
  final BladeSurfaceParams params;
  const _Request(this.bytes, this.params);
}

/// 分析函式的型別。編排層收這個而不是直接呼叫 `BladeSurfaceService.analyze`，
/// 測試才有辦法在不進 isolate、不需要真影像的情況下驗編排邏輯。
typedef BladeSurfaceAnalyzer = Future<BladeSurfaceAnalysis> Function(
  Uint8List bytes, {
  BladeSurfaceParams params,
});

class BladeSurfaceService {
  BladeSurfaceService._();

  /// 在 isolate 裡分析（像素運算不能擋 UI thread）
  static Future<BladeSurfaceAnalysis> analyze(
    Uint8List bytes, {
    BladeSurfaceParams params = const BladeSurfaceParams(),
  }) =>
      compute(_analyzeIsolate, _Request(bytes, params));

  static BladeSurfaceAnalysis _analyzeIsolate(_Request req) =>
      analyzeSync(req.bytes, params: req.params);

  static BladeSurfaceAnalysis analyzeSync(
    Uint8List bytes, {
    BladeSurfaceParams params = const BladeSurfaceParams(),
  }) {
    final decoded = BladeImageOps.safeDecode(bytes);
    if (decoded == null) {
      return BladeSurfaceAnalysis.failed('無法讀取這張照片，請重新拍攝');
    }
    final image = _downscale(decoded, params.maxSide);
    final w = image.width, h = image.height;
    if (w < 64 || h < 32) {
      return BladeSurfaceAnalysis.failed('照片解析度過低，無法量測邊緣粗糙度');
    }

    final gray = _grayscale(image);
    final mask = _segmentBlade(image, params.distThresh);
    final area = mask.fold<int>(0, (a, b) => a + (b > 0 ? 1 : 0));
    if (area < w * h * 0.01) {
      return BladeSurfaceAnalysis.failed(
          '畫面上分不出葉片（前景僅 ${(area / (w * h) * 100).toStringAsFixed(1)}%）：'
          '請讓葉片橫越畫面、背景是純天空');
    }
    _keepLargestComponent(mask, w, h);

    final axis = _pcaAngleDeg(mask, w, h);
    final rot = _rotate(gray, mask, w, h, axis);
    final profiles = _edgeProfiles(rot, w, h);
    if (profiles.xs.length < 32) {
      return BladeSurfaceAnalysis.failed(
          '可用的邊緣取樣點只有 ${profiles.xs.length} 個：葉片可能被畫面上下緣切到，'
          '請退後或轉為橫幅重拍');
    }

    final thickness = <double>[];
    for (var i = 0; i < profiles.xs.length; i++) {
      thickness.add(profiles.bottom[i] - profiles.top[i]);
    }

    final top = _roughness('top', profiles.xs, profiles.top, 1.0, rot.gray, w, h,
        profiles.top, params, insideSign: 1);
    final bottom = _roughness('bottom', profiles.xs, profiles.bottom, -1.0, rot.gray,
        w, h, profiles.bottom, params, insideSign: -1);

    return BladeSurfaceAnalysis(
      ok: true,
      axisAngleDeg: axis,
      residualAxisAngleDeg: _pcaAngleDeg(rot.mask, w, h),
      medianThicknessPx: _median(thickness),
      top: top,
      bottom: bottom,
      leadingEdge: params.leadingEdge,
    );
  }

  // ───────────────────────────── 前處理 ─────────────────────────────

  static img.Image _downscale(img.Image src, int maxSide) {
    final long = math.max(src.width, src.height);
    if (long <= maxSide) return src;
    final s = maxSide / long;
    return img.copyResize(src,
        width: (src.width * s).round(),
        height: (src.height * s).round(),
        interpolation: img.Interpolation.average);
  }

  static Float32List _grayscale(img.Image im) {
    final out = Float32List(im.width * im.height);
    var i = 0;
    for (var y = 0; y < im.height; y++) {
      for (var x = 0; x < im.width; x++) {
        final p = im.getPixel(x, y);
        // Rec.601 亮度，與 OpenCV 的 COLOR_BGR2GRAY 同一組係數
        out[i++] = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      }
    }
    return out;
  }

  /// 天空模型：上下兩條窄帶取中位色，沿列線性內插（Python 的 `mode="top_bottom"`）。
  ///
  /// 分區段照的葉片橫越畫面，左右兩側幾乎都是葉片，所以取樣帶只能用上下緣——
  /// 這正是 `surface.py` 傳 `sky_mode="top_bottom"` 的理由。
  static Uint8List _segmentBlade(img.Image im, double distThresh) {
    final w = im.width, h = im.height;
    final band = math.max(2, (h * 0.05).round());
    final topSamples = <List<double>>[];
    final botSamples = <List<double>>[];
    for (var y = 0; y < band; y++) {
      for (var x = 0; x < w; x += 2) {
        topSamples.add(_labOf(im.getPixel(x, y)));
        botSamples.add(_labOf(im.getPixel(x, h - 1 - y)));
      }
    }
    final mTop = _medianVec(topSamples), mBot = _medianVec(botSamples);

    // robust 尺度：兩帶對各自中位數的 MAD。
    // 下限用 0.3 而不是 Python 的 0.75：OpenCV 的 8-bit Lab 把 L 縮到 0–255，
    // 這裡用未縮放的 CIE Lab（L 0–100），同一個雜訊在數值上小約 2.55 倍。
    // 距離本身是「殘差 / MAD」，分子分母同步縮放所以門檻 5.5σ 可以照用，
    // 但這個**絕對值**下限必須跟著換算，否則等於把門檻悄悄調嚴。
    final resid = <double>[];
    for (final s in topSamples) {
      for (var c = 0; c < 3; c++) {
        resid.add((s[c] - mTop[c]).abs());
      }
    }
    for (final s in botSamples) {
      for (var c = 0; c < 3; c++) {
        resid.add((s[c] - mBot[c]).abs());
      }
    }
    final scale = math.max(1.4826 * _median(resid), 0.3);

    final mask = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      final t = h > 1 ? y / (h - 1) : 0.0;
      final my = [
        mTop[0] + (mBot[0] - mTop[0]) * t,
        mTop[1] + (mBot[1] - mTop[1]) * t,
        mTop[2] + (mBot[2] - mTop[2]) * t,
      ];
      for (var x = 0; x < w; x++) {
        final lab = _labOf(im.getPixel(x, y));
        var d2 = 0.0;
        for (var c = 0; c < 3; c++) {
          final d = (lab[c] - my[c]) / scale;
          d2 += d * d;
        }
        mask[y * w + x] = math.sqrt(d2) > distThresh ? 255 : 0;
      }
    }
    return mask;
  }

  /// sRGB → CIE Lab（D65）。與 OpenCV 的 `COLOR_BGR2Lab` 同一個色空間，
  /// 只差 OpenCV 把 8-bit 值縮放過；這裡用未縮放的 Lab，門檻已對應調整。
  static List<double> _labOf(img.Pixel p) {
    double f(num v) {
      final c = v / 255.0;
      return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    }

    final r = f(p.r), g = f(p.g), b = f(p.b);
    final x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
    final y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    final z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
    double k(double t) =>
        t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
    final fx = k(x), fy = k(y), fz = k(z);
    return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
  }

  static void _keepLargestComponent(Uint8List mask, int w, int h) {
    final label = Int32List(w * h);
    var best = 0, bestSize = 0, next = 0;
    final stack = <int>[];
    for (var i = 0; i < mask.length; i++) {
      if (mask[i] == 0 || label[i] != 0) continue;
      next++;
      var size = 0;
      stack.add(i);
      label[i] = next;
      while (stack.isNotEmpty) {
        final p = stack.removeLast();
        size++;
        final px = p % w, py = p ~/ w;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final nx = px + dx, ny = py + dy;
            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
            final q = ny * w + nx;
            if (mask[q] != 0 && label[q] == 0) {
              label[q] = next;
              stack.add(q);
            }
          }
        }
      }
      if (size > bestSize) {
        bestSize = size;
        best = next;
      }
    }
    for (var i = 0; i < mask.length; i++) {
      if (label[i] != best) mask[i] = 0;
    }
  }

  /// 遮罩主軸與水平的夾角（度）。用二階矩，等價於 Python 的 SVD 主成分。
  static double _pcaAngleDeg(Uint8List mask, int w, int h) {
    var n = 0;
    var sx = 0.0, sy = 0.0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (mask[y * w + x] == 0) continue;
        n++;
        sx += x;
        sy += y;
      }
    }
    if (n == 0) return 0;
    final mx = sx / n, my = sy / n;
    var cxx = 0.0, cyy = 0.0, cxy = 0.0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (mask[y * w + x] == 0) continue;
        final dx = x - mx, dy = y - my;
        cxx += dx * dx;
        cyy += dy * dy;
        cxy += dx * dy;
      }
    }
    var ang = 0.5 * math.atan2(2 * cxy, cxx - cyy) * 180 / math.pi;
    if (ang > 90) ang -= 180;
    if (ang < -90) ang += 180;
    return ang;
  }

  static _Rotated _rotate(
      Float32List gray, Uint8List mask, int w, int h, double angleDeg) {
    final rad = angleDeg * math.pi / 180;
    final cos = math.cos(rad), sin = math.sin(rad);
    final cx = w / 2, cy = h / 2;
    final g = Float32List(w * h);
    final m = Uint8List(w * h);
    final valid = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        // 反向映射：目的座標 → 來源座標，等價於 cv2.getRotationMatrix2D(c, angleDeg, 1)
        // ——目的點 (x,y) 取樣來源的 R(θ)·(x−c)+c，其中 R(θ)=[[cosθ,−sinθ],[sinθ,cosθ]]。
        // 符號寫反會把傾角**加倍**而不是轉正（實測 +20° 的線變成 40°），
        // 而多項式基線會把傾斜吸收掉，所以粗糙度看起來還是對的——這種錯不會自己現形，
        // 只有拿 cv2.warpAffine 對照才抓得到。
        final dx = x - cx, dy = y - cy;
        final sxf = cos * dx - sin * dy + cx;
        final syf = sin * dx + cos * dy + cy;
        final sx = sxf.round(), sy = syf.round();
        if (sx < 0 || sy < 0 || sx >= w || sy >= h) continue;
        final o = y * w + x, i = sy * w + sx;
        // 灰階用雙線性（sub-pixel 邊緣要靠它），遮罩用最近鄰
        g[o] = _bilinear(gray, w, h, sxf, syf);
        m[o] = mask[i];
        valid[o] = 255;
      }
    }
    return _Rotated(g, m, valid);
  }

  static double _bilinear(Float32List src, int w, int h, double x, double y) {
    final x0 = x.floor().clamp(0, w - 1), y0 = y.floor().clamp(0, h - 1);
    final x1 = (x0 + 1).clamp(0, w - 1), y1 = (y0 + 1).clamp(0, h - 1);
    final fx = (x - x0).clamp(0.0, 1.0), fy = (y - y0).clamp(0.0, 1.0);
    final a = src[y0 * w + x0], b = src[y0 * w + x1];
    final c = src[y1 * w + x0], d = src[y1 * w + x1];
    return a * (1 - fx) * (1 - fy) + b * fx * (1 - fy) + c * (1 - fx) * fy + d * fx * fy;
  }

  // ───────────────────────────── 邊緣 ─────────────────────────────

  static _Profiles _edgeProfiles(_Rotated rot, int w, int h, {int margin = 8}) {
    final xs = <double>[], top = <double>[], bot = <double>[];
    for (var x = 0; x < w; x++) {
      int r0 = -1, r1 = -1, v0 = -1, v1 = -1;
      for (var y = 0; y < h; y++) {
        if (rot.valid[y * w + x] != 0) {
          if (v0 < 0) v0 = y;
          v1 = y;
        }
        if (rot.mask[y * w + x] != 0) {
          if (r0 < 0) r0 = y;
          r1 = y;
        }
      }
      if (r0 < 0 || r1 - r0 < 3 || v0 < 0) continue;
      // 葉片被畫面（或旋轉後的有效區）上下緣截斷時，那一欄的邊緣是假的
      if (r0 <= v0 + margin || r1 >= v1 - margin) continue;
      xs.add(x.toDouble());
      top.add(_subpixelEdge(rot.gray, w, h, x, r0, 1));
      bot.add(_subpixelEdge(rot.gray, w, h, x, r1, -1));
    }
    return _Profiles(xs, top, bot);
  }

  /// 半高交叉的 sub-pixel 邊緣。天空與葉片各取一段中位灰階，取一半當交叉值。
  static double _subpixelEdge(
      Float32List gray, int w, int h, int x, int row, int direction) {
    List<double> slice(int a, int b) {
      final out = <double>[];
      for (var y = math.max(0, a); y < math.min(h, b); y++) {
        out.add(gray[y * w + x]);
      }
      return out;
    }

    final sky = direction > 0 ? slice(row - 7, row - 3) : slice(row + 3, row + 7);
    final blade = direction > 0 ? slice(row + 3, row + 7) : slice(row - 7, row - 3);
    if (sky.isEmpty || blade.isEmpty) return row.toDouble();
    final half = (_median(sky) + _median(blade)) / 2.0;
    final lo = math.max(0, row - 3), hi = math.min(h - 1, row + 3);
    final seg = slice(lo, hi + 1);
    if (seg.length < 2) return row.toDouble();
    if (direction > 0) {
      for (var i = 0; i < seg.length - 1; i++) {
        final a = seg[i], b = seg[i + 1];
        if ((a - half) * (b - half) <= 0 && a != b) {
          return lo + i + (half - a) / (b - a);
        }
      }
    } else {
      for (var i = seg.length - 1; i > 0; i--) {
        final a = seg[i], b = seg[i - 1];
        if ((a - half) * (b - half) <= 0 && a != b) {
          return lo + i - (half - a) / (b - a);
        }
      }
    }
    return row.toDouble();
  }

  // ───────────────────────────── 粗糙度 ─────────────────────────────

  static BladeEdgeRoughness _roughness(
    String name,
    List<double> xs,
    List<double> ys,
    double inwardSign,
    Float32List gray,
    int w,
    int h,
    List<double> edgeRows,
    BladeSurfaceParams params, {
    required int insideSign,
  }) {
    final resid = _robustPolyResiduals(xs, ys, params.polyDeg);
    final inward = resid.map((r) => r * inwardSign).toList();

    var sq = 0.0;
    for (final r in resid) {
      sq += r * r;
    }
    final rms = math.sqrt(sq / resid.length);

    final medInward = _median(inward);
    final sigma =
        1.4826 * _median(inward.map((v) => (v - medInward).abs()).toList()) + 1e-6;
    var pits = 0, run = 0;
    for (final v in inward) {
      run = v > params.pitSigma * sigma ? run + 1 : 0;
      if (run == 2) pits++;
    }

    return BladeEdgeRoughness(
      edge: name,
      nSamples: xs.length,
      rmsPx: rms,
      rmsCm: params.cmPerPx == null ? null : rms * params.cmPerPx!,
      inwardP95Px: _percentile(inward, 95),
      pitCount: pits,
      highFreqRatio: _highFreqRatio(resid, params.hfPeriodPx),
      zoneRmsPx: _zoneRms(xs, resid),
      zoneTextureStd:
          _zoneTexture(xs, edgeRows, gray, w, h, params.bandOffsetPx, insideSign),
    );
  }

  /// robust 多項式基線的殘差。3σ 剔除離群點迭代兩次（同 Python）。
  static List<double> _robustPolyResiduals(
      List<double> xs, List<double> ys, int deg) {
    final n = xs.length;
    final span = math.max(xs.last - xs.first, 1.0);
    final mean = xs.reduce((a, b) => a + b) / n;
    final xn = xs.map((x) => (x - mean) / span * 2.0).toList();

    var keep = List<bool>.filled(n, true);
    var coeffs = _polyfit(xn, ys, deg, keep);
    for (var it = 0; it < 2; it++) {
      final resid = List<double>.generate(n, (i) => ys[i] - _polyval(coeffs, xn[i]));
      final kept = <double>[];
      for (var i = 0; i < n; i++) {
        if (keep[i]) kept.add(resid[i]);
      }
      if (kept.isEmpty) break;
      final med = _median(kept);
      final s = 1.4826 * _median(kept.map((v) => (v - med).abs()).toList()) + 1e-6;
      final next = List<bool>.generate(n, (i) => resid[i].abs() < 3.0 * s);
      if (next.where((k) => k).length < deg + 2) break;
      keep = next;
      coeffs = _polyfit(xn, ys, deg, keep);
    }
    return List<double>.generate(n, (i) => ys[i] - _polyval(coeffs, xn[i]));
  }

  /// 最小平方多項式擬合，解正規方程（deg ≤ 3，矩陣小，直接高斯消去）
  static List<double> _polyfit(
      List<double> x, List<double> y, int deg, List<bool> keep) {
    final m = deg + 1;
    final a = List.generate(m, (_) => List<double>.filled(m + 1, 0.0));
    for (var i = 0; i < x.length; i++) {
      if (!keep[i]) continue;
      final pows = List<double>.filled(2 * m, 1.0);
      for (var p = 1; p < 2 * m; p++) {
        pows[p] = pows[p - 1] * x[i];
      }
      for (var r = 0; r < m; r++) {
        for (var c = 0; c < m; c++) {
          a[r][c] += pows[r + c];
        }
        a[r][m] += pows[r] * y[i];
      }
    }
    // 高斯消去（部分樞軸）
    for (var c = 0; c < m; c++) {
      var piv = c;
      for (var r = c + 1; r < m; r++) {
        if (a[r][c].abs() > a[piv][c].abs()) piv = r;
      }
      if (a[piv][c].abs() < 1e-12) continue;
      final tmp = a[c];
      a[c] = a[piv];
      a[piv] = tmp;
      for (var r = 0; r < m; r++) {
        if (r == c) continue;
        final f = a[r][c] / a[c][c];
        for (var k = c; k <= m; k++) {
          a[r][k] -= f * a[c][k];
        }
      }
    }
    // 回傳高次到低次（與 np.polyval 的順序一致）
    final coeffs = List<double>.filled(m, 0.0);
    for (var i = 0; i < m; i++) {
      coeffs[m - 1 - i] = a[i][i].abs() < 1e-12 ? 0.0 : a[i][m] / a[i][i];
    }
    return coeffs;
  }

  static double _polyval(List<double> coeffs, double x) {
    var v = 0.0;
    for (final c in coeffs) {
      v = v * x + c;
    }
    return v;
  }

  /// 高頻能量占比。用直接 DFT（樣本數幾百，成本可忽略）而不是近似的空間域高通，
  /// 這樣數值可以和 Python 原型逐項對照。
  static double _highFreqRatio(List<double> resid, double hfPeriodPx) {
    final n = resid.length;
    if (n < 8) return 0.0;
    final mean = resid.reduce((a, b) => a + b) / n;
    final v = resid.map((r) => r - mean).toList();
    var total = 0.0, hf = 0.0;
    final cutoff = 1.0 / hfPeriodPx;
    for (var k = 1; k <= n ~/ 2; k++) {
      var re = 0.0, im = 0.0;
      final wk = -2 * math.pi * k / n;
      for (var i = 0; i < n; i++) {
        re += v[i] * math.cos(wk * i);
        im += v[i] * math.sin(wk * i);
      }
      final power = re * re + im * im;
      total += power;
      if (k / n > cutoff) hf += power;
    }
    return total <= 0 ? 0.0 : hf / total;
  }

  static List<double> _zoneRms(List<double> xs, List<double> resid) {
    final lo = xs.first, hi = xs.last;
    final out = <double>[];
    for (var z = 0; z < 3; z++) {
      final a = lo + (hi - lo) * z / 3, b = lo + (hi - lo) * (z + 1) / 3;
      var sq = 0.0;
      var n = 0;
      for (var i = 0; i < xs.length; i++) {
        if (xs[i] >= a && xs[i] <= b) {
          sq += resid[i] * resid[i];
          n++;
        }
      }
      out.add(n == 0 ? double.nan : math.sqrt(sq / n));
    }
    return out;
  }

  /// 邊緣內側帶狀區的局部灰階標準差 = 紋理指標。侵蝕會讓表面變粗，
  /// 這個量抓得到「輪廓還沒明顯凹但表面已經粗糙」的早期狀態。
  static List<double> _zoneTexture(List<double> xs, List<double> edgeRows,
      Float32List gray, int w, int h, int bandOffset, int insideSign) {
    final lo = xs.first, hi = xs.last;
    final out = <double>[];
    for (var z = 0; z < 3; z++) {
      final a = lo + (hi - lo) * z / 3, b = lo + (hi - lo) * (z + 1) / 3;
      final vals = <double>[];
      for (var i = 0; i < xs.length; i++) {
        if (xs[i] < a || xs[i] > b) continue;
        final x = xs[i].round();
        for (var d = bandOffset; d < bandOffset + 5; d++) {
          final y = (edgeRows[i] + insideSign * d).round();
          if (x < 0 || y < 0 || x >= w || y >= h) continue;
          vals.add(gray[y * w + x]);
        }
      }
      if (vals.length < 8) {
        out.add(double.nan);
        continue;
      }
      final mean = vals.reduce((p, q) => p + q) / vals.length;
      var sq = 0.0;
      for (final v in vals) {
        sq += (v - mean) * (v - mean);
      }
      out.add(math.sqrt(sq / vals.length));
    }
    return out;
  }

  // ───────────────────────────── 小工具 ─────────────────────────────

  static double _median(List<double> v) {
    if (v.isEmpty) return 0;
    final s = List<double>.from(v)..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }

  static List<double> _medianVec(List<List<double>> rows) => [
        _median(rows.map((r) => r[0]).toList()),
        _median(rows.map((r) => r[1]).toList()),
        _median(rows.map((r) => r[2]).toList()),
      ];

  static double _percentile(List<double> v, double p) {
    if (v.isEmpty) return 0;
    final s = List<double>.from(v)..sort();
    final idx = (p / 100 * (s.length - 1)).clamp(0, s.length - 1).toDouble();
    final lo = idx.floor(), hi = idx.ceil();
    if (lo == hi) return s[lo];
    return s[lo] + (s[hi] - s[lo]) * (idx - lo);
  }
}

class _Rotated {
  final Float32List gray;
  final Uint8List mask;
  final Uint8List valid;
  const _Rotated(this.gray, this.mask, this.valid);
}

class _Profiles {
  final List<double> xs;
  final List<double> top;
  final List<double> bottom;
  const _Profiles(this.xs, this.top, this.bottom);
}
