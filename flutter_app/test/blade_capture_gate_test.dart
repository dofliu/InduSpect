import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/services/blade_capture_gate.dart';
import 'package:induspect_ai/services/image_quality_service.dart';

/// 葉片拍攝閘門的測試。
///
/// 守的是「哪些條件真的該擋」這個決定：儀表近拍那組門檻套到天空為主的畫面上
/// 會誤攔，所以只有讀不到檔與整張過暗算擋，其餘降為提醒。這是刻意的取捨，
/// 不是漏寫——所以要有測試釘住，避免哪天有人「順手補齊」。
void main() {
  ImageQualityReport report({
    List<ImageQualityIssue> issues = const [],
    double sharpness = 120,
    double brightness = 190,
    double over = 0.05,
    double under = 0.01,
  }) =>
      ImageQualityReport(
        sharpness: sharpness,
        brightness: brightness,
        overexposedRatio: over,
        underexposedRatio: under,
        issues: issues,
      );

  test('乾淨的照片放行，沒有多餘提醒', () {
    final v = BladeCaptureGate.judge(report());
    expect(v.ok, isTrue);
    expect(v.blockers, isEmpty);
    expect(v.advisories, isEmpty);
  });

  test('讀不到的檔案要擋', () {
    final v = BladeCaptureGate.judge(
        report(issues: const [ImageQualityIssue.undecodable]));
    expect(v.ok, isFalse);
    expect(v.blockers, hasLength(1));
  });

  test('整張過暗要擋，並指向換位置而不是調曝光', () {
    final v = BladeCaptureGate.judge(
        report(issues: const [ImageQualityIssue.tooDark], brightness: 20));
    expect(v.ok, isFalse);
    expect(v.blockers.join(), contains('背對太陽'));
    expect(v.blockers.join(), contains('不要靠調曝光解決'),
        reason: '逆光是硬限制，調曝光只會把問題換個樣子');
  });

  test('模糊只提醒不擋——葉片照的銳利度分數本來就被天空拉低', () {
    final v = BladeCaptureGate.judge(
        report(issues: const [ImageQualityIssue.blurry], sharpness: 22));
    expect(v.ok, isTrue, reason: '誤攔一張好照片，現場就得再走一趟');
    expect(v.advisories.join(), contains('22'), reason: '把實際分數講出來，才有校準的依據');
    expect(v.advisories.join(), contains('低估'),
        reason: '要說清楚模糊的失敗方向是漏判，不是誤判');
  });

  test('天空為主造成的過亮與死白只提醒不擋', () {
    final v = BladeCaptureGate.judge(report(
      issues: const [ImageQualityIssue.tooBright, ImageQualityIssue.glare],
      brightness: 235,
      over: 0.32,
    ));
    expect(v.ok, isTrue);
    expect(v.advisories, hasLength(2));
    expect(v.advisories.join(), contains('235'));
    expect(v.advisories.join(), contains('32%'));
  });

  test('擋與不擋同時出現時，擋的優先，ok 為 false', () {
    final v = BladeCaptureGate.judge(report(
      issues: const [ImageQualityIssue.blurry, ImageQualityIssue.tooDark],
    ));
    expect(v.ok, isFalse);
    expect(v.blockers, hasLength(1));
    expect(v.advisories, hasLength(1));
  });

  group('存進 qualityJson', () {
    test('一定帶 ok 鍵——沒有它 WtMedia 會判定成「還沒驗過」', () {
      final json = BladeCaptureGate.judge(report()).toJson();
      expect(json.containsKey('ok'), isTrue);
      expect(json['ok'], isTrue);
    });

    test('四個原始量都留著，供日後用真實語料重新定門檻', () {
      final json = BladeCaptureGate.judge(report()).toJson();
      expect(json['sharpness'], 120);
      expect(json['brightness'], 190);
      expect(json['overexposed_ratio'], 0.05);
      expect(json['underexposed_ratio'], 0.01);
    });

    test('被擋下時 ok 為 false，原因一起存', () {
      final json = BladeCaptureGate.judge(
              report(issues: const [ImageQualityIssue.tooDark]))
          .toJson();
      expect(json['ok'], isFalse);
      expect(json['blockers'], isA<List<String>>());
    });
  });
}
