import 'dart:math' as math;

import 'blade_geometry_service.dart';
import 'blade_structure_service.dart';
import 'image_quality_service.dart';

/// 一張葉片照的拍攝品質判定。
class BladeCaptureVerdict {
  /// 能不能拿去做量測。false 時照片照樣保存，但**不會進演算法**。
  final bool ok;

  /// 真的不能用的原因（現場可執行的話術）
  final List<String> blockers;

  /// 提醒但不擋的原因
  final List<String> advisories;

  final ImageQualityReport report;

  const BladeCaptureVerdict({
    required this.ok,
    required this.blockers,
    required this.advisories,
    required this.report,
  });

  /// 存進 `WtMedia.qualityJson`。`ok` 這個鍵是 `WtMedia.qualityOk` 讀的，
  /// 沒有它就代表「還沒驗過」——不可以省略。
  Map<String, dynamic> toJson() => {
        'ok': ok,
        'sharpness': report.sharpness,
        'brightness': report.brightness,
        'overexposed_ratio': report.overexposedRatio,
        'underexposed_ratio': report.underexposedRatio,
        if (blockers.isNotEmpty) 'blockers': blockers,
        if (advisories.isNotEmpty) 'advisories': advisories,
      };
}

/// 葉片照專用的拍攝品質閘門。
///
/// **為什麼不直接用 `ImageQualityService` 的判定**：那組門檻是以「儀表近拍」
/// 校準的，葉片照的畫面大半是天空，三個量都會偏掉——
///
/// - `sharpness`：Laplacian 變異數是**整張**平均，天空是平坦區。就算葉片邊緣
///   銳利如刀，整張的分數也會被天空拉到 60 以下。
/// - `brightness` / `overexposedRatio`：藍天 180–230、陰天白空 240+，直接踩到
///   `maxBrightness = 228` 與 `maxOverexposedRatio = 0.18`。
///
/// 所以這裡只擋**真的轉移得過來**的兩項（讀不到檔、整張太暗），其餘降為提醒。
///
/// 模糊降為提醒還有一個關鍵理由：**模糊的失敗方向是安全的**。邊緣被模糊化之後
/// 半高交叉仍然找得到，只是輪廓變平滑 → 殘差 rms 變小 → 前後緣比變小 →
/// **漏判**而不是誤判。誤判會讓現場停機檢查、漏判只是這次沒抓到，
/// 在沒有真實手機語料可校準門檻之前（規格 §10 外業待辦），寧可漏不可誤攔。
class BladeCaptureGate {
  BladeCaptureGate._();

  static BladeCaptureVerdict judge(ImageQualityReport report) {
    final blockers = <String>[];
    final advisories = <String>[];

    for (final issue in report.issues) {
      switch (issue) {
        case ImageQualityIssue.undecodable:
          blockers.add(issue.advice);
          break;
        case ImageQualityIssue.tooDark:
          blockers.add('畫面整體過暗，葉片與天空的對比不足以分割'
              '（逆光時請換到背對太陽的位置，不要靠調曝光解決）');
          break;
        case ImageQualityIssue.blurry:
          advisories.add('銳利度偏低（${report.sharpness.toStringAsFixed(0)}）。'
              '葉片照大半是天空，這個分數本來就會偏低，因此不擋；'
              '但真的手震會讓侵蝕被低估，建議雙手持穩再拍一張比對');
          break;
        case ImageQualityIssue.tooBright:
          advisories.add('畫面偏亮（平均 ${report.brightness.toStringAsFixed(0)}）。'
              '天空為主的畫面本來就亮，因此不擋');
          break;
        case ImageQualityIssue.glare:
          advisories.add('有大片死白區（占 '
              '${(report.overexposedRatio * 100).toStringAsFixed(0)}%）。'
              '若是雲或光暈會讓分割失敗，換角度避開會更保險');
          break;
      }
    }

    return BladeCaptureVerdict(
      ok: blockers.isEmpty,
      blockers: blockers,
      advisories: advisories,
      report: report,
    );
  }
}

/// 整機照的結構判定（對照 `blade_prototype/blade_proto/quality.py`）。
///
/// 真實影像驗證量到的問題不是演算法偶爾算錯，而是它**算錯的時候看起來和算對的時候
/// 一樣**：輪轂落在穀倉屋頂上、地平線殘塊被當成第三片葉片，`findStructure` 一樣回傳
/// 一個三葉結構，三片互比一樣吐出一組數字。現場操作者看不出差別。
///
/// 這一層跑在結構定位之後、三片互比之前。它不判斷葉片好壞，只判斷**這張照片能不能
/// 拿來判斷**；失敗時給的是「怎麼重拍」，不是「這台風機沒問題」。
class BladeStructureVerdict {
  /// false 時**不得**進行三片互比或產生幾何結論
  final bool ok;

  /// 拒收原因（含重拍建議）
  final List<String> reasons;

  /// 可用但要降權
  final List<String> warnings;
  final Map<String, dynamic> metrics;

  const BladeStructureVerdict({
    required this.ok,
    this.reasons = const [],
    this.warnings = const [],
    this.metrics = const {},
  });

  Map<String, dynamic> toJson() => {
        'ok': ok,
        if (reasons.isNotEmpty) 'reasons': reasons,
        if (warnings.isNotEmpty) 'warnings': warnings,
        'metrics': metrics,
      };
}

class BladeStructureGate {
  BladeStructureGate._();

  /// 地平線以上、非天空像素占該區域的比例上限。整台風機對著天空拍只有幾個百分點。
  /// 這條**只發警告不拒收**——見下方說明。
  static const double maxMaskFrac = 0.15;

  /// 三片葉尖半徑的離散度上限。同一台風機三片等長，真實照片上正確定位時 ≤12%，
  /// 抓到地物、電線或別台風機當葉片時會跳到 23% 以上，而且沒有中間值。
  /// **這是整個閘門唯一真正有鑑別力的條件**：75 張真實照片上它零誤放行。
  static const double maxRadiusSpread = 0.15;

  /// 第二個轉子的半徑相對主風機的比例，超過就發**取景歧義警告**（不拒收）
  static const double secondRotorWarnRatio = 0.5;

  /// 前景太少代表風機根本沒被分出來（白葉片對上亮雲天空）
  static const double minMaskFrac = 0.0015;

  /// 側視：相機垂直轉子面，三片葉片的投影落在通過輪轂的同一條垂直線上——正視用的
  /// 「葉片數 ≠ 3」與「三片半徑離散」兩條規則在這裡本來就不成立（另兩片疊成一段、
  /// 投影長度只有 R·sin），照套會把規格 §5.1 的側視模式整個擋掉。
  /// 判定側視的條件刻意嚴格：**恰好 2 個伸長元件、全部在垂直 ±12° 內、一上一下、
  /// 塔架找到**。12° 是拿 75 張真實照片定的：≤12° 沒有任何一張命中，唯一標成
  /// 「轉子近側視」的那張兩片是 6.6° 與 19.2°——那是斜視不是側視，斜視的垂掛葉片
  /// 彎曲含透視分量，放行只會多一個假訊號來源。與 `quality.py::SIDE_VIEW_MAX_TILT_DEG` 相同。
  static const double sideViewMaxTiltDeg = 12.0;

  static BladeStructureVerdict judge({
    BladeSegmentation? seg,
    BladeStructure? structure,
    String? error,
    int nBladesExpected = 3,
    bool checkSecondRotor = true,
  }) {
    final reasons = <String>[];
    final warnings = <String>[];
    final metrics = <String, dynamic>{};

    if (error != null) {
      reasons.add('結構定位失敗（$error）：多半是天空模型被雲層或前景物撐壞，'
          '請找雲量少的時段、讓風機正對乾淨天空重拍');
      return BladeStructureVerdict(
          ok: false, reasons: reasons, warnings: warnings, metrics: metrics);
    }

    if (seg != null) {
      // 只看地平線以上：結構定位本來就只用這一區，把地面算進來會讓
      // 「風機拍得乾淨、但地面剛好入鏡」的照片被誤擋
      final limit = seg.horizonY ?? seg.h;
      var on = 0;
      final area = limit * seg.w;
      for (var i = 0; i < area; i++) {
        if (seg.mask[i] != 0) on++;
      }
      final frac = area > 0 ? on / area : 1.0;
      metrics['mask_area_frac'] = _round(seg.maskAreaFrac, 4);
      metrics['sky_mask_frac'] = _round(frac, 4);
      metrics['horizon_y'] = seg.horizonY;
      if (frac < minMaskFrac) {
        reasons.add('畫面上幾乎分不出風機（前景僅 '
            '${(frac * 100).toStringAsFixed(2)}%）：白色葉片對上亮雲天空對比不足，'
            '請換角度讓葉片背景是純天空');
      } else if (frac > maxMaskFrac) {
        // 只給警告不拒收：75 張真實照片的門檻掃描顯示，這條規則擋掉的錯誤案例
        // 全部已經被下面的葉尖半徑規則擋掉，自己額外擋掉的只有一張正確案例
        warnings.add('地平線以上的前景占 ${(frac * 100).toStringAsFixed(0)}%'
            '（一般 <${(maxMaskFrac * 100).toStringAsFixed(0)}%）：'
            '雲層、建物或地形可能被當成風機，判定結果請降權看待');
      }
    }

    if (structure == null || !structure.ok) {
      if (reasons.isEmpty) {
        reasons.add(structure?.failure ?? '沒有結構定位結果');
      }
      return BladeStructureVerdict(
          ok: false, reasons: reasons, warnings: warnings, metrics: metrics);
    }

    final n = structure.blades.length;
    metrics['n_blades'] = n;
    // 側視走另一組規則（見 sideViewMaxTiltDeg）：不要求三片、不看半徑離散，
    // 但要明說這張只能量垂掛葉片的彎曲、不能做三片互比。
    final hanging = nBladesExpected == 3 ? detectSideView(structure) : null;
    metrics['view'] = hanging != null ? 'side' : 'front';
    if (hanging != null) {
      metrics['hanging_blade_index'] = hanging;
      warnings.add('側視：三片投影共線，三片互比不適用。本張只量垂掛葉片的 flapwise 彎曲，'
          '而且單幀值含預彎，要與同一台的基線或正視互比結果對照才有意義');
    } else if (n != nBladesExpected) {
      // 依葉片數分開講。n = 0 與 n = 1/2 的成因完全不同，而 2026-09-14 之前三種都印
      // 「可能有葉片貼在塔架上，請等轉子轉開」——75 張真實照片裡 18 張是 n = 0，
      // 那句話會把現場的人帶去等轉子，但真正的成因是轉子沒有完整入鏡或根本沒被分割出來。
      // （「葉尖貼近畫面邊界」當拒收條件量過，不可用：正確放行的真實照片葉尖到邊界只有
      //  0.02–0.03 R，設計範圍內的 12 MP 合成照更只有 0.007 R。所以只修訊息，不新增規則。）
      if (n == 0) {
        reasons.add('一片葉片都沒有定位到：'
            '多半是轉子沒有完整入鏡（請退後到整個轉子連同塔架都進得了畫面），'
            '或風機根本沒被分割出來（雲層、逆光或前景物撐壞天空模型，'
            '請換雲量少的時段、讓葉片背景是乾淨天空）');
      } else if (n < nBladesExpected) {
        reasons.add('只定位到 $n 片葉片（應為 $nBladesExpected）：'
            '可能有葉片正好貼在塔架上（六點鐘方位）或沒入雲層，'
            '請等轉子轉到三片都離開塔架再拍');
      } else {
        reasons.add('定位到 $n 片葉片（多於 $nBladesExpected）：'
            '畫面裡可能不只一台風機，或雲塊、電線被當成葉片，'
            '請重拍並確保只有一台風機在框內');
      }
    }

    final radii = structure.blades.map((b) => b.tipRadiusPx).toList();
    metrics['tip_radii_px'] = radii.map((r) => _round(r, 1)).toList();
    if (radii.length >= 2) {
      final sp = _spread(radii);
      metrics['tip_radius_spread'] = _round(sp, 3);
      // 側視時上方那段是另兩片疊在一起、長度只有 R·sin，離散度沒有「是不是同一台」的意義
      if (hanging == null && sp > maxRadiusSpread) {
        reasons.add('三片葉尖半徑差 ${(sp * 100).toStringAsFixed(0)}%'
            '（上限 ${(maxRadiusSpread * 100).toStringAsFixed(0)}%）：'
            '同一台風機三片等長，差這麼多代表有一片其實是地物、電線或別台風機，'
            '請重拍並確保只有一台風機在框內');
      }
    }

    if (seg != null && seg.horizonY != null) {
      final below = <int>[];
      for (var i = 0; i < structure.blades.length; i++) {
        if (structure.blades[i].tipY >= seg.horizonY!) below.add(i + 1);
      }
      if (below.isNotEmpty) {
        reasons.add('第 ${below.join('、')} 片的葉尖落在地平線以下：'
            '抓到的不是葉片，請重拍');
      }
    }

    // 取景歧義：畫面裡有第二個轉子時，演算法有可能乾淨地鎖上「不是操作者要量的那一台」。
    // 這一條**只發警告不拒收**，理由是量出來的：75 張真實照片上閘門本來就沒有誤放行
    // （multi 照片全部被上面的半徑離散規則擋下），再加一條拒收只有代價沒有收益
    // ——ratio > 0.5 會擋掉 8 張正確放行中的 2 張。
    if (checkSecondRotor && seg != null && radii.isNotEmpty) {
      final r = BladeStructureService.findSecondRotor(
          seg.mask, seg.w, seg.h, structure,
          horizonY: seg.horizonY);
      final r1 = _median(radii);
      metrics['second_rotor_radius_px'] = _round(r[0], 1);
      metrics['second_rotor_arms'] = r[1].toInt();
      if (r1 > 1.0) {
        final ratio = r[0] / r1;
        metrics['second_rotor_ratio'] = _round(ratio, 3);
        if (ratio >= secondRotorWarnRatio) {
          warnings.add('畫面裡還有另一個轉子，半徑約為主風機的 '
              '${(ratio * 100).toStringAsFixed(0)}%：請確認量到的是要量的那一台；'
              '風場的風機外觀相同，量錯對象不會有任何徵兆');
        }
      }
    }

    if (!structure.towerFound) {
      warnings.add('沒有找到塔架：塔架傾斜與六點鐘方位判讀不可用（幾何互比仍可進行）');
    }
    if (!structure.hubRefined) {
      warnings.add('輪轂只有初估、未經葉片軸線精修：葉尖偏移量的精度會下降');
    }
    for (final note in structure.notes) {
      if (note.contains('超過上限') || note.contains('共線')) {
        warnings.add('結構定位提示：$note');
      }
    }

    return BladeStructureVerdict(
      ok: reasons.isEmpty,
      reasons: reasons,
      warnings: warnings,
      metrics: metrics,
    );
  }

  /// 是側視就回傳垂掛葉片（朝下那片）的索引，否則 null。
  ///
  /// 條件見 [sideViewMaxTiltDeg]。只收「兩片、一上一下」：單獨一根垂直的東西也可能是
  /// 桿子、桅杆或被雲切掉的別台風機，沒有上方那段就沒有「這是轉子」的證據；
  /// 三片分得開就不是側視，走正視規則。對照 `quality.py::detect_side_view`。
  static int? detectSideView(BladeStructure structure,
      {double maxTiltDeg = sideViewMaxTiltDeg}) {
    if (structure.blades.length != 2 || !structure.towerFound) return null;
    final angles = structure.blades.map((b) => b.tipAngleDeg).toList();
    if (angles.any((a) => _tiltFromVerticalDeg(a) > maxTiltDeg)) return null;
    final down = <int>[];
    final up = <int>[];
    for (var i = 0; i < angles.length; i++) {
      if (_wrapDeg(angles[i] - 270.0).abs() <= maxTiltDeg) down.add(i);
      if (_wrapDeg(angles[i] - 90.0).abs() <= maxTiltDeg) up.add(i);
    }
    if (down.length != 1 || up.length != 1) return null;
    return down.first;
  }

  /// 折到 (−180, 180]
  static double _wrapDeg(double a) => ((a + 180.0) % 360.0) - 180.0;

  /// 葉片軸線離垂直（90° 朝上或 270° 朝下）的角度
  static double _tiltFromVerticalDeg(double angleDeg) => math.min(
      _wrapDeg(angleDeg - 90.0).abs(), _wrapDeg(angleDeg - 270.0).abs());

  static double _spread(List<double> v) {
    if (v.length < 2) return double.nan;
    final med = _median(v);
    if (med <= 1e-6) return double.infinity;
    var lo = v.first, hi = v.first;
    for (final x in v) {
      if (x < lo) lo = x;
      if (x > hi) hi = x;
    }
    return (hi - lo) / med;
  }

  static double _median(List<double> v) {
    final s = List<double>.from(v)..sort();
    final n = s.length;
    if (n == 0) return double.nan;
    return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2.0;
  }

  static double _round(double v, int digits) {
    if (!v.isFinite) return v;
    final f = math.pow(10, digits);
    return (v * f).round() / f;
  }
}
