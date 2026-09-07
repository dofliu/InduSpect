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
