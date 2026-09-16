import 'dart:math' as math;

import 'blade_dsp.dart';
import 'blade_geometry_compare.dart';
import 'blade_structure_service.dart';

/// 相機姿態估計與透視補償（`blade_prototype/blade_proto/pose.py` 的 Dart 對照，SPEC §13-11）。
///
/// `OFFAXIS_SENSITIVITY.md` 量到的事實：地面拍的正視整機照，三片互比會把**預彎的投影**標成
/// 一到三公尺的假葉尖偏移，z 十幾到四十——雜訊底救不回來，只有知道相機在哪裡才能把它算掉。
///
/// 兩件事：①**估姿態**——仰角由「輪轂高度 − 相機高度」除以到輪轂的直線距離（距離由 35 mm
/// 等效焦距 × 型錄轉子半徑 ÷ 量到的葉長反推，或直接給 GPS 水平距離）；yaw 由輪轂偏離塔軸的
/// 距離 ÷ 機艙 overhang（型錄很少寫，預設 5 m——**粗估**）。②**補償**——三片同型、預彎一樣，
/// 在已知姿態下預彎 w 造成的 in-plane 假彎曲對每片是已知方向、已知比例的量 g_i·w；三個量到的
/// 葉尖偏移對一個未知 w 做**留一法**擬合（假設最多一片有問題），殘差才拿去互比。半徑除掉平面
/// 透視比例、再減掉葉尖上風側偏移先驗沿軸的分量；|yaw| > 15° 不補半徑。
///
/// 不可退化：沒有姿態就不補償、不用預設值假裝補過；只動葉尖偏移與半徑兩個量；原始值一律留在
/// 輸出；拍攝閘門仍看**原始**半徑離散（閘門在補償之前）。
class BladePoseEstimate {
  final double? elevationDeg;
  final double? yawDeg;
  final double? distanceM;
  final double rotorTiltDeg;
  final String? elevationMethod; // 'horizontal' | 'focal'
  final String? yawMethod; // 'tower_offset'
  /// 塔軸 − 輪轂（公尺，+ = 塔軸在輪轂右側）
  final double? hubOffsetM;
  final List<String> notes;

  const BladePoseEstimate({
    required this.elevationDeg,
    required this.yawDeg,
    required this.distanceM,
    this.rotorTiltDeg = BladePoseService.defaultRotorTiltDeg,
    this.elevationMethod,
    this.yawMethod,
    this.hubOffsetM,
    this.notes = const [],
  });

  bool get usable => elevationDeg != null && yawDeg != null && distanceM != null;

  Map<String, dynamic> toJson() => {
        'elevation_deg': elevationDeg,
        'yaw_deg': yawDeg,
        'distance_m': distanceM,
        'rotor_tilt_deg': rotorTiltDeg,
        'elevation_method': elevationMethod,
        'yaw_method': yawMethod,
        'hub_offset_m': hubOffsetM,
        'notes': notes,
        'usable': usable,
      };
}

/// `fitPrebend` 的結果：預彎 w、三片對該 w 的殘差、離群候選（留一法留出來的那片）。
class BladePrebendFit {
  final double wM;
  final List<double> residuals;
  final int outlierIndex;
  const BladePrebendFit(this.wM, this.residuals, this.outlierIndex);
}

/// 補償後的三片互比（葉尖偏移與半徑兩個量）+ 補了多少的全部帳目。
class BladeCompensation {
  final BladePoseEstimate pose;
  final double prebendFitM;
  final bool deflectionCompensated;
  final bool radiusCompensated;
  final double tipOffsetPriorM;
  final List<double> tipDeflectionRawPx;
  final List<double> tipDeflectionCompensatedPx;
  final List<double> radiusRawPx;
  final List<double> radiusCompensatedPx;
  final List<double> deflectionBasisPxPerM;
  final List<double> radiusRatios;
  final List<double> radiusAlongPxPerM;
  final List<MetricComparison> comparisons;
  final List<int> bladesNearTower;
  final String? note;
  final double cmPerPx;

  const BladeCompensation({
    required this.pose,
    required this.prebendFitM,
    required this.deflectionCompensated,
    required this.radiusCompensated,
    required this.tipOffsetPriorM,
    required this.tipDeflectionRawPx,
    required this.tipDeflectionCompensatedPx,
    required this.radiusRawPx,
    required this.radiusCompensatedPx,
    required this.deflectionBasisPxPerM,
    required this.radiusRatios,
    required this.radiusAlongPxPerM,
    required this.comparisons,
    required this.bladesNearTower,
    required this.cmPerPx,
    this.note,
  });

  bool get anyFlagged => comparisons.any((c) => c.flagged);

  MetricComparison? metric(String name) {
    for (final c in comparisons) {
      if (c.metric == name) return c;
    }
    return null;
  }
}

class _Axes {
  final List<double> cDir, f, r, u;
  const _Axes(this.cDir, this.f, this.r, this.u);
}

class BladePoseService {
  BladePoseService._();

  static const double defaultCameraHeightM = 1.6;
  static const double defaultNacelleOverhangM = 5.0;
  static const double defaultRotorTiltDeg = 5.0;
  static const double fullFrameWidthMm = 36.0;

  /// 預彎擬合值超出這個範圍就不是預彎，是姿態錯了或有真缺陷——此時不補償
  static const double prebendFitMinM = 0.0;
  static const double prebendFitMaxM = 8.0;

  /// 半徑補償用的葉尖上風側總偏移先驗（預彎 3 m + 錐角 2.5° × 60 m ≈ 5.6 m）。不擬合：三片對兩個
  /// 未知在 yaw = 0 時奇異、其他姿態下對 yaw 誤差極敏感。±2 m 的先驗誤差 × 每公尺 2–3 px ≈ 60 cm，
  /// 低於半徑互比的門檻。
  static const double defaultTipOffsetM = 6.0;

  /// 半徑只在 |yaw| 不大時補：平面比例對 yaw 誤差敏感，而 yaw 是靠 overhang 預設值粗估的。
  static const double radiusCompMaxYawDeg = 15.0;

  /// 與六點鐘夾角在這以內的葉片可能與塔架合併（正視 ±20° 是實測；偏軸時塔軸偏向一側，放寬到 35°）
  static const double nearTowerDeg = 35.0;

  // ------------------------------------------------------------ 單項估計

  /// 35 mm 等效焦距 → 像素焦距：全片幅寬 36 mm 對應畫面長邊。
  static double focalPxFrom35mm(double focal35mm, int longSidePx) =>
      focal35mm / fullFrameWidthMm * longSidePx;

  /// 針孔：D = f_px × R_m / R_px。半徑或焦距不是正數就 null。
  static double? distanceFromScale(
      double rotorRadiusM, double rotorRadiusPx, double focalPx) {
    if (!(rotorRadiusM > 0) || !(rotorRadiusPx > 0) || !(focalPx > 0)) {
      return null;
    }
    return focalPx * rotorRadiusM / rotorRadiusPx;
  }

  static double? elevationFromSlant(double hubHeightM, double? distanceM,
      {double cameraHeightM = defaultCameraHeightM}) {
    final dh = hubHeightM - cameraHeightM;
    if (dh <= 0 || distanceM == null || distanceM <= dh) return null;
    return math.asin(dh / distanceM) * 180.0 / math.pi;
  }

  /// (仰角, 直線距離)；高度差或水平距離不是正數就 null。
  static (double, double)? elevationFromHorizontal(
      double hubHeightM, double? horizontalM,
      {double cameraHeightM = defaultCameraHeightM}) {
    final dh = hubHeightM - cameraHeightM;
    if (dh <= 0 || horizontalM == null || horizontalM <= 0) return null;
    return (
      math.atan2(dh, horizontalM) * 180.0 / math.pi,
      math.sqrt(horizontalM * horizontalM + dh * dh)
    );
  }

  /// 塔軸相對輪轂的水平偏移（公尺，+ = 塔軸在輪轂右側）→ yaw（+ = 相機在轉子 +x 側）。
  /// |offset| > overhang 在幾何上不可能，夾到 ±90°。
  static double? yawFromHubOffset(double offsetM,
      {double overhangM = defaultNacelleOverhangM}) {
    if (!(overhangM > 0)) return null;
    final r = (offsetM / overhangM).clamp(-1.0, 1.0);
    return math.asin(r) * 180.0 / math.pi;
  }

  /// 從結構定位結果 + 資產參數 + 焦距／距離估相機姿態。缺什麼就哪一項 null，**不猜**。
  static BladePoseEstimate estimate({
    required BladeStructure structure,
    required double? hubHeightM,
    required double? rotorRadiusM,
    int? imageLongSidePx,
    double? focal35mm,
    double? horizontalDistanceM,
    double cameraHeightM = defaultCameraHeightM,
    double overhangM = defaultNacelleOverhangM,
    double rotorTiltDeg = defaultRotorTiltDeg,
    double? cmPerPx,
  }) {
    final notes = <String>[];
    final radii = structure.blades.map((b) => b.tipRadiusPx).toList();
    final rPx = radii.isEmpty ? 0.0 : BladeDsp.median(radii);
    var scale = cmPerPx;
    if (scale == null && rotorRadiusM != null && rotorRadiusM > 0 && rPx > 0) {
      scale = rotorRadiusM * 100.0 / rPx;
    }

    double? el, dist;
    String? elMethod;
    if (hubHeightM == null || hubHeightM <= 0) {
      notes.add('沒有輪轂高度，無法估仰角');
    } else if (horizontalDistanceM != null && horizontalDistanceM > 0) {
      final got = elevationFromHorizontal(hubHeightM, horizontalDistanceM,
          cameraHeightM: cameraHeightM);
      if (got != null) {
        el = got.$1;
        dist = got.$2;
        elMethod = 'horizontal';
      }
    } else if (focal35mm != null &&
        focal35mm > 0 &&
        imageLongSidePx != null &&
        rotorRadiusM != null &&
        rPx > 0) {
      final fPx = focalPxFrom35mm(focal35mm, imageLongSidePx);
      dist = distanceFromScale(rotorRadiusM, rPx, fPx);
      el = dist == null
          ? null
          : elevationFromSlant(hubHeightM, dist, cameraHeightM: cameraHeightM);
      if (el == null) {
        notes.add('由焦距反推的距離小於輪轂高度差，姿態不成立（焦距或型錄半徑可能不對）');
        dist = null;
      } else {
        elMethod = 'focal';
      }
    } else {
      notes.add('沒有 GPS 水平距離也沒有 35 mm 等效焦距，無法估仰角');
    }

    double? yaw, offsetM;
    String? yawMethod;
    final towerX = structure.towerXAtHub;
    if (towerX == null || !structure.towerFound) {
      notes.add('沒有塔架軸，無法估 yaw');
    } else if (scale == null) {
      notes.add('沒有尺度（型錄轉子直徑），無法把塔軸偏移換成公尺');
    } else {
      offsetM = (towerX - structure.hubX) * scale / 100.0;
      yaw = yawFromHubOffset(offsetM, overhangM: overhangM);
      yawMethod = 'tower_offset';
      if (offsetM.abs() > overhangM) {
        notes.add('塔軸偏移 ${offsetM.toStringAsFixed(1)} m 超過機艙 overhang '
            '${overhangM.toStringAsFixed(1)} m，yaw 夾在 ±90°——overhang 預設值可能不合這台機型');
      } else {
        notes.add('yaw 由塔軸偏移 ${offsetM >= 0 ? '+' : ''}${offsetM.toStringAsFixed(2)} m ÷ '
            'overhang ${overhangM.toStringAsFixed(1)} m（預設值，粗估）');
      }
    }
    return BladePoseEstimate(
      elevationDeg: el,
      yawDeg: yaw,
      distanceM: dist,
      rotorTiltDeg: rotorTiltDeg,
      elevationMethod: elMethod,
      yawMethod: yawMethod,
      hubOffsetM: offsetM,
      notes: notes,
    );
  }

  // ------------------------------------------------------------ 針孔投影（與 pose.py 同一套幾何）

  static List<double> _cross(List<double> a, List<double> b) => [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
      ];

  static double _dot(List<double> a, List<double> b) =>
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

  static List<double> _unit(List<double> a) {
    final n = math.sqrt(_dot(a, a));
    return [a[0] / n, a[1] / n, a[2] / n];
  }

  static _Axes _cameraAxes(double elevationDeg, double yawDeg) {
    final yaw = yawDeg * math.pi / 180.0, el = elevationDeg * math.pi / 180.0;
    final cDir = [
      math.sin(yaw) * math.cos(el),
      -math.sin(el),
      math.cos(yaw) * math.cos(el)
    ];
    final f = [-cDir[0], -cDir[1], -cDir[2]];
    final r = _unit(_cross(f, [0.0, 1.0, 0.0]));
    final u = _cross(r, f);
    return _Axes(cDir, f, r, u);
  }

  /// 轉子座標（公尺）：u 沿葉片軸、w 朝上風側（轉子軸 a，上仰 tilt）。
  static List<double> _rotorPoint(
      double uM, double wM, double azimuthDeg, double tiltDeg) {
    final t = tiltDeg * math.pi / 180.0;
    final az = azimuthDeg * math.pi / 180.0;
    // e1 = (1,0,0)；e2 = (0, cos t, −sin t)；a = (0, sin t, cos t)
    final dx = math.cos(az);
    final dy = math.sin(az) * math.cos(t);
    final dz = -math.sin(az) * math.sin(t);
    return [
      uM * dx,
      uM * dy + wM * math.sin(t),
      uM * dz + wM * math.cos(t),
    ];
  }

  /// 轉子座標（公尺，輪轂為原點）→ 相對輪轂影像位置（px，y 向下）。焦距 = D × pxPerM。
  static List<List<double>> projectRotorPoints(
      List<List<double>> pointsM, BladePoseEstimate pose, double pxPerM) {
    final ax = _cameraAxes(pose.elevationDeg!, pose.yawDeg!);
    final d = pose.distanceM!;
    final fPx = d * pxPerM;
    final out = <List<double>>[];
    for (final p in pointsM) {
      final q = [p[0] - d * ax.cDir[0], p[1] - d * ax.cDir[1], p[2] - d * ax.cDir[2]];
      final depth = _dot(q, ax.f);
      out.add([fPx * _dot(q, ax.r) / depth, -fPx * _dot(q, ax.u) / depth]);
    }
    return out;
  }

  /// 每片：葉尖有 1 m 上風側預彎時，畫面上垂直葉片軸的位移（px）。
  /// 垂直方向 n 與 `bladeProfile` 同一個慣例：軸向 d = (cos φ, −sin φ)，n = (−sin φ, −cos φ)。
  static List<double> deflectionBasis(List<double> axisAnglesDeg,
      double rotorRadiusM, BladePoseEstimate pose, double pxPerM) {
    final out = <double>[];
    for (final phi in axisAnglesDeg) {
      final xy = projectRotorPoints([
        _rotorPoint(rotorRadiusM, 0.0, phi, pose.rotorTiltDeg),
        _rotorPoint(rotorRadiusM, 1.0, phi, pose.rotorTiltDeg),
      ], pose, pxPerM);
      final dxImg = xy[1][0] - xy[0][0], dyImg = xy[1][1] - xy[0][1];
      final rad = phi * math.pi / 180.0;
      out.add(dxImg * -math.sin(rad) + dyImg * -math.cos(rad));
    }
    return out;
  }

  /// 每片：(平面投影半徑對中位數的比例, 葉尖 1 m 上風側偏移沿葉片軸的位移 px)。
  static (List<double>, List<double>) radialBasis(List<double> axisAnglesDeg,
      double rotorRadiusM, BladePoseEstimate pose, double pxPerM) {
    final rs = <double>[], along = <double>[];
    for (final phi in axisAnglesDeg) {
      final xy = projectRotorPoints([
        _rotorPoint(rotorRadiusM, 0.0, phi, pose.rotorTiltDeg),
        _rotorPoint(rotorRadiusM, 1.0, phi, pose.rotorTiltDeg),
      ], pose, pxPerM);
      rs.add(math.sqrt(xy[0][0] * xy[0][0] + xy[0][1] * xy[0][1]));
      final rad = phi * math.pi / 180.0;
      along.add((xy[1][0] - xy[0][0]) * math.cos(rad) +
          (xy[1][1] - xy[0][1]) * -math.sin(rad));
    }
    final med = rs.isEmpty ? 1.0 : BladeDsp.median(rs);
    return (rs.map((r) => r / med).toList(), along);
  }

  /// d_i = w·g_i + ε_i，**留一法**：對每一片 k 用另兩片擬合 w、算 k 的殘差；殘差最大的那片當
  /// 離群候選，w 取另兩片的擬合值。三片一起最小平方會把一片真的偏移吃掉一半（Python 實測
  /// 400 cm 只剩 124 cm），假設「最多一片有問題」才把缺陷留在殘差裡。
  static BladePrebendFit fitPrebend(
      List<double> deflectionsPx, List<double> basisPxPerM) {
    final n = deflectionsPx.length;
    final finite = deflectionsPx.every((v) => v.isFinite) &&
        basisPxPerM.every((v) => v.isFinite);
    if (n < 3 || !finite) {
      var gg = 0.0, dg = 0.0;
      for (var i = 0; i < n; i++) {
        gg += basisPxPerM[i] * basisPxPerM[i];
        dg += deflectionsPx[i] * basisPxPerM[i];
      }
      final w = gg > 1e-9 ? dg / gg : 0.0;
      return BladePrebendFit(
          w, [for (var i = 0; i < n; i++) deflectionsPx[i] - w * basisPxPerM[i]], -1);
    }
    double? bestW;
    var bestResid = 0.0;
    var bestK = -1;
    for (var k = 0; k < n; k++) {
      var gg = 0.0, dg = 0.0;
      for (var i = 0; i < n; i++) {
        if (i == k) continue;
        gg += basisPxPerM[i] * basisPxPerM[i];
        dg += deflectionsPx[i] * basisPxPerM[i];
      }
      final wK = gg > 1e-9 ? dg / gg : 0.0;
      final residK = deflectionsPx[k] - wK * basisPxPerM[k];
      if (bestW == null || residK.abs() > bestResid.abs()) {
        bestW = wK;
        bestResid = residK;
        bestK = k;
      }
    }
    final w = bestW!;
    return BladePrebendFit(
        w, [for (var i = 0; i < n; i++) deflectionsPx[i] - w * basisPxPerM[i]], bestK);
  }

  /// 在已知姿態下重做葉尖偏移與半徑的三片互比。姿態不可用 → null（呼叫端保留原始互比）。
  static BladeCompensation? compensate(
    List<BladeProfile> profiles,
    BladePoseEstimate pose,
    double? rotorRadiusM, {
    double noiseFloorPx = 1.5,
    double zThresh = 3.0,
    double? cmPerPx,
    double tipOffsetM = defaultTipOffsetM,
  }) {
    if (!pose.usable || profiles.length != 3 || rotorRadiusM == null || !(rotorRadiusM > 0)) {
      return null;
    }
    final radii = profiles.map((p) => p.radiusPx).toList();
    final rPx = BladeDsp.median(radii);
    final pxPerM = rPx / rotorRadiusM;
    final scale = cmPerPx ?? 100.0 / pxPerM;
    final axes = profiles.map((p) => p.axisAngleDeg).toList();
    final rawDefl = profiles.map((p) => p.tipDeflectionPx).toList();
    final basis = deflectionBasis(axes, rotorRadiusM, pose, pxPerM);
    final fit = fitPrebend(rawDefl, basis);
    final okFit = fit.wM >= prebendFitMinM && fit.wM <= prebendFitMaxM;
    final (ratios, along) = radialBasis(axes, rotorRadiusM, pose, pxPerM);
    final okRad = pose.yawDeg!.abs() <= radiusCompMaxYawDeg;
    final radiiCorr = [
      for (var i = 0; i < 3; i++) (radii[i] - along[i] * tipOffsetM) / ratios[i]
    ];
    final comps = [
      BladeGeometryCompare.compareMetric('tip_deflection_px',
              okFit ? fit.residuals : rawDefl, noiseFloorPx, zThresh: zThresh)
          .withScale(scale),
      BladeGeometryCompare.compareMetric('radius_px', okRad ? radiiCorr : radii,
              noiseFloorPx * 2.0, zThresh: zThresh)
          .withScale(scale),
    ];
    // 接近六點鐘的葉片會與塔架／機艙合併，中心線被拉歪成假彎曲；補償模型算不掉，只能點名。
    final nearTower = <int>[];
    for (var i = 0; i < axes.length; i++) {
      final d = ((axes[i] - 270.0 + 180.0) % 360.0 + 360.0) % 360.0 - 180.0;
      if (d.abs() <= nearTowerDeg) nearTower.add(i);
    }
    final notes = <String>[];
    if (nearTower.isNotEmpty) {
      final labels = nearTower.map((i) => i < 3 ? 'ABC'[i] : '$i').join('、');
      notes.add('葉片 $labels 距六點鐘 ≤ ${nearTowerDeg.toStringAsFixed(0)}°，可能與塔架合併而使中心線被拉歪；'
          '該片的葉尖偏移不可靠，請等轉子轉開再拍');
    }
    if (!okFit) {
      notes.add('預彎擬合 ${fit.wM.toStringAsFixed(1)} m 超出 ${prebendFitMinM.toStringAsFixed(0)}–'
          '${prebendFitMaxM.toStringAsFixed(0)} m：姿態可能不對或有真缺陷，葉尖偏移未補償');
    }
    if (!okRad) {
      notes.add('|yaw| ${pose.yawDeg!.abs().toStringAsFixed(0)}° 超過 ${radiusCompMaxYawDeg.toStringAsFixed(0)}°，'
          '半徑的平面比例對 yaw 誤差太敏感：半徑未補償');
    }
    return BladeCompensation(
      pose: pose,
      prebendFitM: fit.wM,
      deflectionCompensated: okFit,
      radiusCompensated: okRad,
      tipOffsetPriorM: tipOffsetM,
      tipDeflectionRawPx: rawDefl,
      tipDeflectionCompensatedPx: fit.residuals,
      radiusRawPx: radii,
      radiusCompensatedPx: radiiCorr,
      deflectionBasisPxPerM: basis,
      radiusRatios: ratios,
      radiusAlongPxPerM: along,
      comparisons: comps,
      bladesNearTower: nearTower,
      cmPerPx: scale,
      note: notes.isEmpty ? null : notes.join('；'),
    );
  }
}
