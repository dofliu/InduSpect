import 'dart:math' as math;
import 'dart:typed_data';

import 'blade_capture_gate.dart';
import 'blade_dsp.dart';
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
/// 哪個方向才算缺陷徵兆。
///
/// 幾何量（葉尖偏移、弦寬）兩個方向都是異常，所以預設 [both]。聲學量不是：
/// 某片的寬頻位準比另兩片**低**不代表它有問題，若不限方向，最安靜的那片
/// 會被標成前緣侵蝕——那是完全反過來的結論。
enum MetricDirection {
  both('both'),
  high('high'),
  low('low');

  const MetricDirection(this.wire);

  /// 與 `geometry.py` 的字串值相同，讓兩邊的 JSON 對得起來
  final String wire;
}

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

  /// 哪個方向算異常。存進結果是刻意的：報告上「z = 4 但沒標記」看起來像 bug，
  /// 除非看得到它是被方向性擋掉的。
  final MetricDirection direction;

  /// [outlierDeviation] 換成公分（有尺度時才有；對照 Python 的 `outlier_deviation_cm`）。
  /// **只是單位換算，不改判定**——標記與 z 一律在 px 上算，尺度不對只會讓 cm 值不對，
  /// 不會多標或少標。
  final double? outlierDeviationCm;

  const MetricComparison({
    required this.metric,
    required this.values,
    required this.deviations,
    required this.outlierIndex,
    required this.outlierDeviation,
    required this.othersSpread,
    required this.z,
    required this.flagged,
    this.direction = MetricDirection.both,
    this.outlierDeviationCm,
  });

  /// 套上尺度：回一份帶 [outlierDeviationCm] 的複本。NaN 的離群量不換算。
  MetricComparison withScale(double cmPerPx) => MetricComparison(
        metric: metric,
        values: values,
        deviations: deviations,
        outlierIndex: outlierIndex,
        outlierDeviation: outlierDeviation,
        othersSpread: othersSpread,
        z: z,
        flagged: flagged,
        direction: direction,
        outlierDeviationCm:
            outlierDeviation.isFinite ? outlierDeviation * cmPerPx : null,
      );

  Map<String, dynamic> toJson() => {
        'metric': metric,
        'values': values,
        'outlier_index': outlierIndex,
        'outlier_deviation': outlierDeviation,
        'others_spread': othersSpread,
        'z': z,
        'flagged': flagged,
        'direction': direction.wire,
        if (outlierDeviationCm != null) 'outlier_deviation_cm': outlierDeviationCm,
      };
}

class BladeComparison {
  final int nBlades;
  final List<MetricComparison> comparisons;
  final String? note;

  /// 側視時為 'side'（`sideViewSummary`），正視為 null——正視的 JSON 形狀不變。
  final String? view;

  /// 側視時垂掛葉片的量測（index／radius_px／bend_coeff／tip_deflection_px／
  /// residual_rms_px／n_contaminated_bins，有尺度時多 tip_deflection_cm）；正視為 null。
  final Map<String, dynamic>? hangingBlade;

  /// 這張照片的尺度（cm/px）。呼叫端直接給，或由型錄轉子半徑與量到的葉長反推
  /// （對照 `geometry.py::compare_blades` 的 `cm_per_px`）；兩者都沒有就是 null，
  /// 此時所有 `*_cm` 欄位都不存在——**不猜尺度**。
  final double? cmPerPx;

  const BladeComparison({
    required this.nBlades,
    required this.comparisons,
    this.note,
    this.view,
    this.hangingBlade,
    this.cmPerPx,
  });

  bool get anyFlagged => comparisons.any((c) => c.flagged);

  Map<String, dynamic> toJson() => {
        'n_blades': nBlades,
        'comparisons': comparisons.map((c) => c.toJson()).toList(),
        'any_flagged': anyFlagged,
        if (note != null) 'note': note,
        if (view != null) 'view': view,
        if (hangingBlade != null) 'hanging_blade': hangingBlade,
        if (cmPerPx != null) 'cm_per_px': cmPerPx,
      };
}

/// 幾何層（規格 §5.3）：中心線抽取、彎曲係數、三片互比。
///
/// `blade_prototype/blade_proto/geometry.py` 的 Dart 對照實作。
///
/// **三片互比不需要絕對量測，也不需要歷史基線**：同一台風機三片同批同型，
/// 在同一轉子位置的剪影應一致。這是幾何層能在手機尺度上成立的唯一理由——
/// 絕對量測需要知道 cm/px，而那個數字在現場拿不到。
///
/// 有型錄轉子直徑時（`WtAsset.rotorDiameterM`）可以**反推**尺度：三片量到的葉長中位數
/// 就是轉子半徑，cm/px = 半徑 ÷ 中位葉長。這只把 px 換成 cm 讓報告看得懂、跨次可比，
/// **判定一律在 px 上做**（對照 `geometry.py::compare_blades`）。正視合成夾具上反推誤差
/// 見 `blade_geometry_reference.json` 的 `comparison.cm_per_px` 對 `truth.cm_per_px`。
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
  ///
  /// [direction] 不是 [MetricDirection.both] 時，離群者改取**最高（或最低）那片**
  /// 而不是離中位數最遠那片。兩片往相反方向偏時這個差別是關鍵：
  /// high 模式要抓最吵的，不是偏離最多的。
  static MetricComparison compareMetric(
    String name,
    List<double> values,
    double noiseFloor, {
    double zThresh = 3.0,
    double spreadRatio = 2.0,
    MetricDirection direction = MetricDirection.both,
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
        direction: direction,
      );
    }
    final fv = finite.map((i) => values[i]).toList();
    final med = _median(fv);
    final dev = values.map((v) => v - med).toList();
    var j = 0;
    var best = -double.infinity;
    for (var i = 0; i < fv.length; i++) {
      final score = switch (direction) {
        MetricDirection.high => fv[i],
        MetricDirection.low => -fv[i],
        MetricDirection.both => (fv[i] - med).abs(),
      };
      if (score > best) {
        best = score;
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
    var flagged = z >= zThresh && devK.abs() >= spreadRatio * spread;
    // 方向不對就不算徵兆。**這一步在 z 算完之後**：z 照樣回報，
    // 只是不標記——現場看到「差很多但沒報」時，那個 z 是唯一的線索。
    if (direction == MetricDirection.high && devK <= 0) {
      flagged = false;
    } else if (direction == MetricDirection.low && devK >= 0) {
      flagged = false;
    }
    return MetricComparison(
      metric: name,
      values: values,
      deviations: dev,
      outlierIndex: k,
      outlierDeviation: devK,
      othersSpread: spread,
      z: z,
      flagged: flagged,
      direction: direction,
    );
  }

  /// 比較三片的葉尖偏移、半徑、弦寬、殘差。
  ///
  /// [noiseFloorPx]：單片量測雜訊底。**預設 1.5 px 來自合成影像的靈敏度分析，
  /// 還沒有真實手機語料背書**（規格 §10 外業待辦）——它決定 z 值，也就決定要不要
  /// 標記，所以外業回來第一件要校準的就是它。
  ///
  /// [cmPerPx] 直接給尺度；沒給而有 [rotorRadiusM]（型錄轉子半徑，公尺）時，
  /// 以三片葉長中位數反推。兩者都沒有就不出任何 cm 值。
  static BladeComparison compareBlades(
    List<BladeProfile> profiles, {
    double noiseFloorPx = 1.5,
    double zThresh = 3.0,
    double? cmPerPx,
    double? rotorRadiusM,
  }) {
    if (profiles.length < 2) {
      return BladeComparison(
        nBlades: profiles.length,
        comparisons: const [],
        note: '少於兩片，無法互比',
      );
    }
    final radii = profiles.map((p) => p.radiusPx).toList();
    final scale = resolveScale(cmPerPx, rotorRadiusM, _median(radii));
    final comps = [
      compareMetric('tip_deflection_px',
          profiles.map((p) => p.tipDeflectionPx).toList(), noiseFloorPx,
          zThresh: zThresh),
      compareMetric('radius_px', radii, noiseFloorPx * 2.0, zThresh: zThresh),
      compareMetric('mean_width_px',
          profiles.map((p) => p.meanWidthPx).toList(), noiseFloorPx,
          zThresh: zThresh),
      compareMetric('residual_rms_px',
          profiles.map((p) => p.residualRmsPx).toList(), noiseFloorPx * 0.5,
          zThresh: zThresh),
    ];
    return BladeComparison(
      nBlades: profiles.length,
      comparisons:
          scale == null ? comps : comps.map((c) => c.withScale(scale)).toList(),
      cmPerPx: scale,
    );
  }

  /// 尺度的單一規則（對照 Python `if cm_per_px is None and rotor_radius_m:`）：
  /// 直接給的優先；否則型錄半徑 ÷ 參考葉長（px）；半徑或葉長不是正數就沒有尺度。
  static double? resolveScale(
      double? cmPerPx, double? rotorRadiusM, double referenceRadiusPx) {
    if (cmPerPx != null) return cmPerPx;
    if (rotorRadiusM == null || !(rotorRadiusM > 0)) return null;
    if (!(referenceRadiusPx > 0) || !referenceRadiusPx.isFinite) return null;
    return rotorRadiusM * 100.0 / referenceRadiusPx;
  }

  /// 側視（閘門 `BladeStructureGate.detectSideView` 判定）：不做三片互比，只回報垂掛
  /// 葉片的彎曲。回傳與 [compareBlades] 同形（`comparisons` 為空），報告與分析編排
  /// 不必另開一條路徑。單幀的 tipDeflection **含預彎**，不是缺陷量——要與同一台的
  /// 基線或另一幀比才有意義，所以這裡不設門檻、不標記。對照 `geometry.py::side_view_summary`。
  ///
  /// 尺度只能由**垂掛那片**反推：六點鐘那片的投影長度 ≈ 轉子半徑（sin 90° = 1），
  /// 上方那段是另兩片疊在一起、只有 R·sin 30°，不能拿來反推。
  static BladeComparison sideViewSummary(
    List<BladeProfile> profiles,
    int hangingIndex, {
    double? cmPerPx,
    double? rotorRadiusM,
  }) {
    final p = profiles[hangingIndex];
    final scale = resolveScale(cmPerPx, rotorRadiusM, p.radiusPx);
    return BladeComparison(
      nBlades: profiles.length,
      comparisons: const [],
      view: 'side',
      cmPerPx: scale,
      hangingBlade: {
        'index': hangingIndex,
        'label': hangingIndex < 3 ? 'ABC'[hangingIndex] : '$hangingIndex',
        'axis_angle_deg': p.axisAngleDeg,
        'radius_px': p.radiusPx,
        'bend_coeff': p.bendCoeff,
        'tip_deflection_px': p.tipDeflectionPx,
        'residual_rms_px': p.residualRmsPx,
        'n_contaminated_bins': p.nContaminatedBins,
        if (scale != null) 'tip_deflection_cm': p.tipDeflectionPx * scale,
      },
      note: '側視：三片投影共線，互比不適用；量測項目為垂掛葉片的 flapwise 彎曲'
          '（單幀值含預彎，需與同一台的基線比對）',
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

  // 這幾個數值 helper 的實作在 `blade_dsp.dart`。**同一個模組不留兩份同樣的數學**
  // ——聲音層與幾何層都要用擬合與中位數，各寫一份的話兩邊會慢慢漂開，
  // 而那種漂移不會讓測試紅，只會讓兩層的判定基準悄悄不一致。
  static double _percentile(Float64List a, double q) => BladeDsp.percentile(a, q);

  static double _median(List<double> v) => BladeDsp.median(v);

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

  static List<double> _polyfit(
          Float64List x, List<double> y, List<bool> keep, int deg) =>
      BladeDsp.polyfit(x, y, keep, deg);

  static double _polyval(List<double> coeffs, double x) =>
      BladeDsp.polyval(coeffs, x);
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

  /// 抽出來的三片輪廓。動態層要用它們的軸線角度與半徑（挑出「這一幀哪片朝下」），
  /// 而互比本身用不到，所以放在這裡而不是另跑一次管線——重跑一次分割與結構定位
  /// 是這條路上最貴的一步。[ok] 為 false 時是空的。
  final List<BladeProfile> profiles;

  /// 這張照片的尺度（cm/px）；沒有型錄轉子直徑、或閘門拒收時是 null。
  /// 也複製在 `metrics['cm_per_px']`，讓它跟著其他數值一起進 `metricJson`。
  final double? cmPerPx;

  const BladeGeometryOutcome({
    required this.ok,
    this.reasons = const [],
    this.warnings = const [],
    this.metrics = const {},
    this.comparisons = const [],
    this.profiles = const [],
    this.cmPerPx,
  });
}

/// 幾何層分析的注入點（測試不必進 isolate、也不必有真影像）。
///
/// [rotorRadiusM]：型錄轉子半徑（公尺），有的話結果會多一組 cm 值；影片抽幀那條路
/// 不傳（多幀互比只看 px 的一致性）。
typedef BladeGeometryAnalyzer = Future<BladeGeometryOutcome> Function(
    Uint8List bytes, {double? rotorRadiusM});

/// 一張整機照 → 分割 → 結構定位 → **拍攝閘門** → 三片互比。
///
/// 閘門在互比之前，而且拒收時直接回傳、不算互比。這個順序是幾何層能不能用的關鍵：
/// 真實影像驗證量到的問題不是演算法偶爾算錯，是它算錯的時候看起來和算對的時候一樣。
///
/// [rotorRadiusM]：型錄轉子半徑（公尺）。有的話由量到的葉長反推 cm/px，互比結果多一組
/// cm 值（`outlierDeviationCm`／`tip_deflection_cm`）；**判定不變**，只是單位換算。
BladeGeometryOutcome runGeometryPipeline(
  Uint8List bytes, {
  BladeGeometryParams params = const BladeGeometryParams(),
  double noiseFloorPx = 1.5,
  double? rotorRadiusM,
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
  // 閘門判定為側視時不做三片互比：另兩片疊成一段，互比只會吐出自洽但無意義的離群。
  final hangingIndex = verdict.metrics['hanging_blade_index'];
  final side = verdict.metrics['view'] == 'side' &&
      hangingIndex is int &&
      hangingIndex >= 0 &&
      hangingIndex < profiles.length;
  final cmp = side
      ? BladeGeometryCompare.sideViewSummary(profiles, hangingIndex,
          rotorRadiusM: rotorRadiusM)
      : BladeGeometryCompare.compareBlades(profiles,
          noiseFloorPx: noiseFloorPx, rotorRadiusM: rotorRadiusM);
  final hb = cmp.hangingBlade;
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
      if (cmp.cmPerPx != null) 'cm_per_px': cmp.cmPerPx,
      if (hb != null) ...{
        'hanging_radius_px': hb['radius_px'],
        'hanging_bend_coeff': hb['bend_coeff'],
        'hanging_tip_deflection_px': hb['tip_deflection_px'],
        'hanging_residual_rms_px': hb['residual_rms_px'],
        if (hb.containsKey('tip_deflection_cm'))
          'hanging_tip_deflection_cm': hb['tip_deflection_cm'],
      },
    },
    comparisons: cmp.comparisons,
    profiles: profiles,
    cmPerPx: cmp.cmPerPx,
  );
}
