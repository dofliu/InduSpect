import 'dart:math' as math;
import 'dart:typed_data';

import 'blade_capture_gate.dart';
import 'blade_geometry_service.dart';
import 'blade_image_ops.dart';
import 'blade_structure_service.dart';

/// 單片葉片的輪廓（對照 `geometry.py::BladeProfile`）。
///
/// 所有側向量都除以葉長 R，所以是**無因次**的——跨片、跨次都可比。
class BladeProfile {
  final int index;

  /// 影像平面方位角（數學慣例，270° = 六點鐘）
  final double axisAngleDeg;

  /// 輪轂到葉尖（px）
  final double radiusPx;

  /// 正規化 span 位置（0–1）
  final Float64List u;

  /// 中心線側向偏移 / R
  final Float64List center;
  final Float64List edgeLo;
  final Float64List edgeHi;

  /// 弦寬 / R
  final Float64List width;

  /// 二次擬合係數（單位 R）。PCA 軸吸收了一次項，所以它對軸傾斜不敏感。
  final double bendCoeff;

  /// bendCoeff × R：葉尖相對於直線的偏移
  final double tipDeflectionPx;

  /// 二次擬合殘差（形狀不規則度）
  final double residualRmsPx;
  final double meanWidthPx;
  final double tipX;
  final double tipY;

  /// 弦寬離群（雲塊/鳥/附著物黏在邊緣）而被修補的分箱數
  final int nContaminatedBins;

  const BladeProfile({
    required this.index,
    required this.axisAngleDeg,
    required this.radiusPx,
    required this.u,
    required this.center,
    required this.edgeLo,
    required this.edgeHi,
    required this.width,
    required this.bendCoeff,
    required this.tipDeflectionPx,
    required this.residualRmsPx,
    required this.meanWidthPx,
    required this.tipX,
    required this.tipY,
    this.nContaminatedBins = 0,
  });

  Map<String, dynamic> toJson() => {
        'index': index,
        'axis_angle_deg': axisAngleDeg,
        'radius_px': radiusPx,
        'bend_coeff': bendCoeff,
        'tip_deflection_px': tipDeflectionPx,
        'residual_rms_px': residualRmsPx,
        'mean_width_px': meanWidthPx,
        'n_contaminated_bins': nContaminatedBins,
      };
}

/// 一個量的三片互比結果（對照 `geometry.py::MetricComparison`）
class MetricComparison {
  final String metric;
  final List<double> values;

  /// 各片相對三片中位數
  final List<double> deviations;
  final int outlierIndex;

  /// 離群者與另外兩片平均的差（px 或 R 比例）
  final double outlierDeviation;

  /// 另外兩片彼此差
  final double othersSpread;

  /// |deviation| / 雜訊底
  final double z;
  final bool flagged;

  const MetricComparison({
    required this.metric,
    required this.values,
    required this.deviations,
    required this.outlierIndex,
    required this.outlierDeviation,
    required this.othersSpread,
    required this.z,
    required this.flagged,
  });

  Map<String, dynamic> toJson() => {
        'metric': metric,
        'values': values,
        'outlier_index': outlierIndex,
        'outlier_deviation': outlierDeviation,
        'others_spread': othersSpread,
        'z': z,
        'flagged': flagged,
      };
}

class BladeComparison {
  final int nBlades;
  final List<MetricComparison> comparisons;
  final String? note;

  const BladeComparison({
    required this.nBlades,
    required this.comparisons,
    this.note,
  });

  bool get anyFlagged => comparisons.any((c) => c.flagged);

  Map<String, dynamic> toJson() => {
        'n_blades': nBlades,
        'comparisons': comparisons.map((c) => c.toJson()).toList(),
        'any_flagged': anyFlagged,
        if (note != null) 'note': note,
      };
}

/// 幾何層（規格 §5.3）：中心線抽取、彎曲係數、三片互比。
///
/// `blade_prototype/blade_proto/geometry.py` 的 Dart 對照實作。
///
/// **三片互比不需要絕對量測，也不需要歷史基線**：同一台風機三片同批同型，
/// 在同一轉子位置的剪影應一致。這是幾何層能在手機尺度上成立的唯一理由——
/// 絕對量測需要知道 cm/px，而那個數字在現場拿不到。
class BladeGeometryCompare {
  BladeGeometryCompare._();

  /// 從結構定位的結果算出每片的輪廓。
  ///
  /// [correctRoll]：用塔架傾角把畫面轉正。塔架是畫面裡唯一可信的「垂直」參考，
  /// 沒有它的話手持的 roll 會被算進葉片的側向偏移。
  static List<BladeProfile> profilesFromStructure(
    BladeStructure st, {
    bool correctRoll = true,
    int nBins = 48,
    double uMin = 0.12,
    double uMax = 0.98,
  }) {
    final roll = (correctRoll && st.towerFound) ? st.towerAngleDeg : 0.0;
    final out = <BladeProfile>[];
    for (var i = 0; i < st.blades.length; i++) {
      final p = bladeProfile(st.blades[i], st.hubX, st.hubY, i,
          rollDeg: roll, nBins: nBins, uMin: uMin, uMax: uMax);
      if (p != null) out.add(p);
    }
    return out;
  }

  /// 從單一葉片元件像素抽出中心線與邊緣輪廓。
  ///
  /// 像素太少（外段取不到 PCA 軸）時回 null 而不是丟例外——
  /// 一片抽不出來不該讓整台風機的分析失敗。
  static BladeProfile? bladeProfile(
    BladeTip comp,
    double hubX,
    double hubY,
    int index, {
    double rollDeg = 0.0,
    int nBins = 48,
    double uMin = 0.12,
    double uMax = 0.98,
  }) {
    final n = comp.xs.length;
    if (n < 30) return null;
    final px = Float64List(n), py = Float64List(n);
    final rt = rollDeg * math.pi / 180.0;
    final cr = math.cos(-rt), sr = math.sin(-rt);
    for (var i = 0; i < n; i++) {
      final x = comp.xs[i] - hubX, y = comp.ys[i] - hubY;
      if (rollDeg != 0.0) {
        // 把塔架轉正（與 Python 的 p @ _rot(-roll).T 相同）
        px[i] = cr * x - sr * y;
        py[i] = sr * x + cr * y;
      } else {
        px[i] = x;
        py[i] = y;
      }
    }

    // 主軸用外段像素（避免根部殘留輪轂影響），並指向遠離輪轂
    var rMax = 0.0;
    final r = Float64List(n);
    for (var i = 0; i < n; i++) {
      r[i] = math.sqrt(px[i] * px[i] + py[i] * py[i]);
      if (r[i] > rMax) rMax = r[i];
    }
    final ox = <double>[], oy = <double>[];
    for (var i = 0; i < n; i++) {
      if (r[i] > 0.25 * rMax) {
        ox.add(px[i]);
        oy.add(py[i]);
      }
    }
    if (ox.length < 20) return null;
    var mx = 0.0, my = 0.0;
    for (var i = 0; i < ox.length; i++) {
      mx += ox[i];
      my += oy[i];
    }
    mx /= ox.length;
    my /= ox.length;
    var sxx = 0.0, sxy = 0.0, syy = 0.0;
    for (var i = 0; i < ox.length; i++) {
      final dx = ox[i] - mx, dy = oy[i] - my;
      sxx += dx * dx;
      sxy += dx * dy;
      syy += dy * dy;
    }
    final tr = sxx + syy;
    final det = sxx * syy - sxy * sxy;
    final l1 = tr / 2 + math.sqrt(math.max(tr * tr / 4 - det, 0.0));
    var dx0 = sxy.abs() > 1e-12 ? l1 - syy : (sxx >= syy ? 1.0 : 0.0);
    var dy0 = sxy.abs() > 1e-12 ? sxy : (sxx >= syy ? 0.0 : 1.0);
    final dn = math.sqrt(dx0 * dx0 + dy0 * dy0);
    if (dn <= 0) return null;
    dx0 /= dn;
    dy0 /= dn;
    if (mx * dx0 + my * dy0 < 0) {
      dx0 = -dx0;
      dy0 = -dy0;
    }
    // n 軸與 synth 同向：方位角 θ 時 n = (−sinθ, −cosθ)
    final nx = dy0, ny = -dx0;

    final uu = Float64List(n), vv = Float64List(n);
    for (var i = 0; i < n; i++) {
      uu[i] = px[i] * dx0 + py[i] * dy0;
      vv[i] = px[i] * nx + py[i] * ny;
    }
    final bigR = _percentile(uu, 99.8);
    if (!(bigR > 0)) return null;

    final edges = Float64List(nBins + 1);
    for (var i = 0; i <= nBins; i++) {
      edges[i] = uMin * bigR + (uMax - uMin) * bigR * i / nBins;
    }
    final lo = List<double>.filled(nBins, double.nan);
    final hi = List<double>.filled(nBins, double.nan);
    final cnt = List<int>.filled(nBins, 0);
    for (var i = 0; i < n; i++) {
      final b = _binOf(edges, uu[i], nBins);
      if (b < 0) continue;
      cnt[b]++;
      if (lo[b].isNaN || vv[i] < lo[b]) lo[b] = vv[i];
      if (hi[b].isNaN || vv[i] > hi[b]) hi[b] = vv[i];
    }
    for (var i = 0; i < nBins; i++) {
      if (cnt[i] < 2) {
        lo[i] = double.nan;
        hi[i] = double.nan;
      }
    }
    _fillNan(lo);
    _fillNan(hi);
    final t = Float64List(nBins);
    for (var i = 0; i < nBins; i++) {
      t[i] = (edges[i] + edges[i + 1]) / 2.0 / bigR;
    }

    // 邊緣修補：雲塊/鳥/附著物黏在葉片一側會讓那幾箱的弦寬暴增、中心線被拉歪。
    // 弦寬沿 span 應平滑（根部定值後線性收斂），用 robust 擬合找離群箱，
    // 再看 lo/hi 哪一側偏離自己的擬合較多，就以擬合值取代那一側。
    var width = List<double>.generate(nBins, (i) => hi[i] - lo[i]);
    var nBad = 0;
    if (nBins >= 12) {
      final wFit = _robustSeriesFit(t, width, 3);
      final bad = <int>[];
      for (var i = 0; i < nBins; i++) {
        if (!wFit.keep[i] && !width[i].isNaN) bad.add(i);
      }
      if (bad.isNotEmpty) {
        final loFit = _robustSeriesFit(t, lo, 3).fit;
        final hiFit = _robustSeriesFit(t, hi, 3).fit;
        for (final i in bad) {
          if ((lo[i] - loFit[i]).abs() > (hi[i] - hiFit[i]).abs()) {
            lo[i] = loFit[i];
          } else {
            hi[i] = hiFit[i];
          }
        }
        nBad = bad.length;
        width = List<double>.generate(nBins, (i) => hi[i] - lo[i]);
      }
    }

    final mid = List<double>.generate(nBins, (i) => (lo[i] + hi[i]) / 2.0);
    final okT = <double>[], okY = <double>[];
    for (var i = 0; i < nBins; i++) {
      if (!mid[i].isNaN) {
        okT.add(t[i]);
        okY.add(mid[i] / bigR);
      }
    }
    if (okT.length < 4) return null;
    final q = _polyfit2(okT, okY);
    final a2 = q[0], a1 = q[1], a0 = q[2];

    var sq = 0.0;
    var m = 0;
    for (var i = 0; i < nBins; i++) {
      if (mid[i].isNaN) continue;
      final f = a2 * t[i] * t[i] + a1 * t[i] + a0;
      final e = (mid[i] / bigR - f) * bigR;
      sq += e * e;
      m++;
    }
    final residRms = m > 0 ? math.sqrt(sq / m) : double.nan;

    var wsum = 0.0;
    var wn = 0;
    for (final v in width) {
      if (!v.isNaN) {
        wsum += v;
        wn++;
      }
    }

    // 葉尖位置由擬合外推到 u = 1（不是取最遠的那個像素）：
    // 單一像素會被雜訊決定，擬合值才是那片葉片的形狀
    final tipU = bigR, tipV = (a2 + a1 + a0) * bigR;
    var tix = tipU * dx0 + tipV * nx;
    var tiy = tipU * dy0 + tipV * ny;
    if (rollDeg != 0.0) {
      final cb = math.cos(rt), sb = math.sin(rt);
      final rx = cb * tix - sb * tiy;
      final ry = sb * tix + cb * tiy;
      tix = rx;
      tiy = ry;
    }

    var axisDeg = math.atan2(-dy0, dx0) * 180.0 / math.pi;
    axisDeg %= 360.0;
    if (axisDeg < 0) axisDeg += 360.0;

    return BladeProfile(
      index: index,
      axisAngleDeg: axisDeg,
      radiusPx: bigR,
      u: t,
      center: Float64List.fromList(
          List<double>.generate(nBins, (i) => mid[i] / bigR)),
      edgeLo:
          Float64List.fromList(List<double>.generate(nBins, (i) => lo[i] / bigR)),
      edgeHi:
          Float64List.fromList(List<double>.generate(nBins, (i) => hi[i] / bigR)),
      width: Float64List.fromList(
          List<double>.generate(nBins, (i) => width[i] / bigR)),
      bendCoeff: a2,
      tipDeflectionPx: a2 * bigR,
      residualRmsPx: residRms,
      meanWidthPx: wn > 0 ? wsum / wn : double.nan,
      tipX: hubX + tix,
      tipY: hubY + tiy,
      nContaminatedBins: nBad,
    );
  }

  /// 三片互比：離群者 = 離中位數最遠者；同時要求它與另外兩片的差距明顯大於
  /// 另外兩片彼此差。NaN 一律不參與。
  static MetricComparison compareMetric(
    String name,
    List<double> values,
    double noiseFloor, {
    double zThresh = 3.0,
    double spreadRatio = 2.0,
  }) {
    final finite = <int>[];
    for (var i = 0; i < values.length; i++) {
      if (values[i].isFinite) finite.add(i);
    }
    if (finite.length < 2) {
      return MetricComparison(
        metric: name,
        values: values,
        deviations: List<double>.filled(values.length, double.nan),
        outlierIndex: finite.isEmpty ? 0 : finite.first,
        outlierDeviation: double.nan,
        othersSpread: double.nan,
        z: double.nan,
        flagged: false,
      );
    }
    final fv = finite.map((i) => values[i]).toList();
    final med = _median(fv);
    final dev = values.map((v) => v - med).toList();
    var j = 0;
    var bestAbs = -1.0;
    for (var i = 0; i < fv.length; i++) {
      final a = (fv[i] - med).abs();
      if (a > bestAbs) {
        bestAbs = a;
        j = i;
      }
    }
    final k = finite[j];
    final others = <double>[];
    for (var i = 0; i < fv.length; i++) {
      if (i != j) others.add(fv[i]);
    }
    final spread = others.length == 2 ? (others[0] - others[1]).abs() : 0.0;
    final othersMean = others.isEmpty
        ? 0.0
        : others.reduce((a, b) => a + b) / others.length;
    final devK = others.isEmpty ? dev[k] : values[k] - othersMean;
    final z = devK.abs() / math.max(noiseFloor, 1e-9);
    final flagged = z >= zThresh && devK.abs() >= spreadRatio * spread;
    return MetricComparison(
      metric: name,
      values: values,
      deviations: dev,
      outlierIndex: k,
      outlierDeviation: devK,
      othersSpread: spread,
      z: z,
      flagged: flagged,
    );
  }

  /// 比較三片的葉尖偏移、半徑、弦寬、殘差。
  ///
  /// [noiseFloorPx]：單片量測雜訊底。**預設 1.5 px 來自合成影像的靈敏度分析，
  /// 還沒有真實手機語料背書**（規格 §10 外業待辦）——它決定 z 值，也就決定要不要
  /// 標記，所以外業回來第一件要校準的就是它。
  static BladeComparison compareBlades(
    List<BladeProfile> profiles, {
    double noiseFloorPx = 1.5,
    double zThresh = 3.0,
  }) {
    if (profiles.length < 2) {
      return BladeComparison(
        nBlades: profiles.length,
        comparisons: const [],
        note: '少於兩片，無法互比',
      );
    }
    return BladeComparison(
      nBlades: profiles.length,
      comparisons: [
        compareMetric('tip_deflection_px',
            profiles.map((p) => p.tipDeflectionPx).toList(), noiseFloorPx,
            zThresh: zThresh),
        compareMetric('radius_px', profiles.map((p) => p.radiusPx).toList(),
            noiseFloorPx * 2.0,
            zThresh: zThresh),
        compareMetric('mean_width_px',
            profiles.map((p) => p.meanWidthPx).toList(), noiseFloorPx,
            zThresh: zThresh),
        compareMetric('residual_rms_px',
            profiles.map((p) => p.residualRmsPx).toList(), noiseFloorPx * 0.5,
            zThresh: zThresh),
      ],
    );
  }

  // ------------------------------------------------------- 數值 helper

  static int _binOf(Float64List edges, double v, int nBins) {
    if (v < edges[0] || v >= edges[nBins]) return -1;
    var lo = 0, hi = nBins;
    while (lo + 1 < hi) {
      final mid = (lo + hi) ~/ 2;
      if (edges[mid] <= v) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  static double _percentile(Float64List a, double q) {
    final s = Float64List.fromList(a)..sort();
    if (s.isEmpty) return double.nan;
    final pos = (q / 100.0) * (s.length - 1);
    final i = pos.floor(), f = pos - i;
    if (i + 1 >= s.length) return s[s.length - 1];
    return s[i] * (1 - f) + s[i + 1] * f;
  }

  static double _median(List<double> v) {
    final s = List<double>.from(v)..sort();
    final n = s.length;
    if (n == 0) return double.nan;
    return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2.0;
  }

  /// 線性內插填掉 NaN（對照 `geometry.py::_fill_nan`）
  static void _fillNan(List<double> a) {
    final good = <int>[];
    for (var i = 0; i < a.length; i++) {
      if (!a[i].isNaN) good.add(i);
    }
    if (good.isEmpty) return;
    for (var i = 0; i < a.length; i++) {
      if (!a[i].isNaN) continue;
      if (i < good.first) {
        a[i] = a[good.first];
      } else if (i > good.last) {
        a[i] = a[good.last];
      } else {
        var k = 0;
        while (k + 1 < good.length && good[k + 1] < i) {
          k++;
        }
        final x0 = good[k], x1 = good[k + 1];
        final f = (i - x0) / (x1 - x0);
        a[i] = a[x0] * (1 - f) + a[x1] * f;
      }
    }
  }

  /// 對 y(t) 做多項式擬合並迭代剔除 3σ 離群
  static _SeriesFit _robustSeriesFit(Float64List t, List<double> y, int deg,
      {int iters = 3}) {
    final ok = List<bool>.generate(y.length, (i) => !y[i].isNaN);
    var keep = List<bool>.from(ok);
    var coeffs = _polyfit(t, y, keep, deg);
    for (var it = 0; it < iters; it++) {
      final resid = List<double>.filled(y.length, double.nan);
      for (var i = 0; i < y.length; i++) {
        if (ok[i]) resid[i] = y[i] - _polyval(coeffs, t[i]);
      }
      final kept = <double>[];
      for (var i = 0; i < y.length; i++) {
        if (keep[i] && !resid[i].isNaN) kept.add(resid[i]);
      }
      if (kept.isEmpty) break;
      final medR = _median(kept);
      final abs = kept.map((v) => (v - medR).abs()).toList();
      final sigma = 1.4826 * _median(abs) + 1e-6;
      final next = List<bool>.generate(
          y.length, (i) => ok[i] && resid[i].abs() < 3.0 * sigma);
      final n = next.where((b) => b).length;
      var same = true;
      for (var i = 0; i < next.length; i++) {
        if (next[i] != keep[i]) {
          same = false;
          break;
        }
      }
      if (n < deg + 2 || same) break;
      keep = next;
      coeffs = _polyfit(t, y, keep, deg);
    }
    final fit = List<double>.generate(y.length, (i) => _polyval(coeffs, t[i]));
    return _SeriesFit(fit, keep);
  }

  /// 二次擬合，回傳 [a2, a1, a0]（與 numpy 的係數順序一致）
  static List<double> _polyfit2(List<double> x, List<double> y) {
    final keep = List<bool>.filled(x.length, true);
    return _polyfit(Float64List.fromList(x), y, keep, 2);
  }

  /// 正規方程 + 高斯消去的多項式擬合。係數由高次到低次（numpy 順序）。
  static List<double> _polyfit(
      Float64List x, List<double> y, List<bool> keep, int deg) {
    final m = deg + 1;
    final a = List<List<double>>.generate(m, (_) => List<double>.filled(m, 0.0));
    final b = List<double>.filled(m, 0.0);
    for (var i = 0; i < y.length; i++) {
      if (!keep[i] || y[i].isNaN) continue;
      final pw = List<double>.filled(m, 1.0);
      for (var j = 1; j < m; j++) {
        pw[j] = pw[j - 1] * x[i];
      }
      for (var r = 0; r < m; r++) {
        for (var c = 0; c < m; c++) {
          a[r][c] += pw[r] * pw[c];
        }
        b[r] += pw[r] * y[i];
      }
    }
    // 高斯消去（部分樞軸）
    for (var col = 0; col < m; col++) {
      var piv = col;
      for (var r = col + 1; r < m; r++) {
        if (a[r][col].abs() > a[piv][col].abs()) piv = r;
      }
      if (a[piv][col].abs() < 1e-12) continue;
      if (piv != col) {
        final tr = a[piv];
        a[piv] = a[col];
        a[col] = tr;
        final tb = b[piv];
        b[piv] = b[col];
        b[col] = tb;
      }
      for (var r = col + 1; r < m; r++) {
        final f = a[r][col] / a[col][col];
        if (f == 0) continue;
        for (var c = col; c < m; c++) {
          a[r][c] -= f * a[col][c];
        }
        b[r] -= f * b[col];
      }
    }
    final sol = List<double>.filled(m, 0.0);
    for (var r = m - 1; r >= 0; r--) {
      var s = b[r];
      for (var c = r + 1; c < m; c++) {
        s -= a[r][c] * sol[c];
      }
      sol[r] = a[r][r].abs() < 1e-12 ? 0.0 : s / a[r][r];
    }
    // sol 是 [c0, c1, ... cdeg]（低次到高次）→ 反轉成 numpy 順序
    return sol.reversed.toList();
  }

  static double _polyval(List<double> coeffs, double x) {
    var v = 0.0;
    for (final c in coeffs) {
      v = v * x + c;
    }
    return v;
  }
}

class _SeriesFit {
  final List<double> fit;
  final List<bool> keep;
  const _SeriesFit(this.fit, this.keep);
}

/// 幾何層一次完整分析的產出：閘門判定 + 三片互比。
class BladeGeometryOutcome {
  /// 拍攝閘門是否放行。false 時 [comparisons] 一定為空——
  /// 定位錯誤時互比一樣會吐出自洽但完全錯的數字，所以不能算。
  final bool ok;
  final List<String> reasons;
  final List<String> warnings;
  final Map<String, dynamic> metrics;
  final List<MetricComparison> comparisons;

  const BladeGeometryOutcome({
    required this.ok,
    this.reasons = const [],
    this.warnings = const [],
    this.metrics = const {},
    this.comparisons = const [],
  });
}

/// 幾何層分析的注入點（測試不必進 isolate、也不必有真影像）
typedef BladeGeometryAnalyzer = Future<BladeGeometryOutcome> Function(
    Uint8List bytes);

/// 一張整機照 → 分割 → 結構定位 → **拍攝閘門** → 三片互比。
///
/// 閘門在互比之前，而且拒收時直接回傳、不算互比。這個順序是幾何層能不能用的關鍵：
/// 真實影像驗證量到的問題不是演算法偶爾算錯，是它算錯的時候看起來和算對的時候一樣。
BladeGeometryOutcome runGeometryPipeline(
  Uint8List bytes, {
  BladeGeometryParams params = const BladeGeometryParams(),
  double noiseFloorPx = 1.5,
}) {
  final decoded = BladeImageOps.safeDecode(bytes);
  if (decoded == null) {
    return const BladeGeometryOutcome(
        ok: false, reasons: ['無法讀取這張照片，請重新拍攝']);
  }
  final seg = BladeGeometryService.segmentTurbine(decoded, params: params);
  final st = BladeStructureService.findStructure(seg.mask, seg.w, seg.h,
      horizonY: seg.horizonY);
  final verdict = BladeStructureGate.judge(seg: seg, structure: st);
  if (!verdict.ok) {
    return BladeGeometryOutcome(
      ok: false,
      reasons: verdict.reasons,
      warnings: verdict.warnings,
      metrics: verdict.metrics,
    );
  }
  final profiles = BladeGeometryCompare.profilesFromStructure(st);
  final cmp = BladeGeometryCompare.compareBlades(profiles,
      noiseFloorPx: noiseFloorPx);
  return BladeGeometryOutcome(
    ok: true,
    warnings: verdict.warnings,
    metrics: {
      ...verdict.metrics,
      'rotor_radius_px': st.rotorRadiusPx,
      'tower_angle_deg': st.towerAngleDeg,
      'n_profiles': profiles.length,
      'contaminated_bins':
          profiles.fold<int>(0, (a, pr) => a + pr.nContaminatedBins),
    },
    comparisons: cmp.comparisons,
  );
}
