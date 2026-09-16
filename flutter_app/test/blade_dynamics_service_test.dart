import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/services/blade_dynamics_service.dart';
import 'package:induspect_ai/services/blade_geometry_compare.dart';

/// 動態層（影片多幀）。
///
/// **抽幀是注入的**，所以整條編排與判定邏輯測得到，不必有真影片、也不必有原生
/// 解碼器。這正是把 `BladeFrameExtractor` 做成 typedef 的目的：接上原生那天
/// 只補一個函式，而這裡的每一條測試仍然守著同一份行為。
Float64List _f(int n) => Float64List(n);

BladeProfile profile({
  required int index,
  required double axisAngleDeg,
  required double radiusPx,
}) =>
    BladeProfile(
      index: index,
      axisAngleDeg: axisAngleDeg,
      radiusPx: radiusPx,
      u: _f(4),
      center: _f(4),
      edgeLo: _f(4),
      edgeHi: _f(4),
      width: _f(4),
      bendCoeff: 0.0,
      tipDeflectionPx: 0.0,
      residualRmsPx: 0.0,
      meanWidthPx: 10.0,
      tipX: 0.0,
      tipY: 0.0,
      nContaminatedBins: 0,
    );

/// 一幀「有一片朝下」的幾何結果。三片相隔 120°。
BladeGeometryOutcome frameWithDown(double downRadius, {double offDeg = 0.0}) =>
    BladeGeometryOutcome(
      ok: true,
      profiles: [
        profile(index: 0, axisAngleDeg: 270.0 + offDeg, radiusPx: downRadius),
        profile(index: 1, axisAngleDeg: 30.0, radiusPx: 300.0),
        profile(index: 2, axisAngleDeg: 150.0, radiusPx: 300.0),
      ],
    );

void main() {
  /// 每次呼叫依序回傳一個結果；抽不到的用 null 表示
  BladeFrameExtractor extractorOf(List<Uint8List?> seq) {
    var i = 0;
    return (path, at) async => i < seq.length ? seq[i++] : null;
  }

  BladeGeometryAnalyzer analyzerOf(List<BladeGeometryOutcome> seq) {
    var i = 0;
    return (bytes, {double? rotorRadiusM, double? hubHeightM}) async =>
        i < seq.length ? seq[i++] : const BladeGeometryOutcome(ok: false);
  }

  final oneByte = Uint8List.fromList([1]);

  group('取樣時刻', () {
    test('依葉片通過週期取，不超過上限，且都落在片長內', () {
      final t = BladeDynamicsService.sixOclockTimes(
          periodS: 0.5, phaseS: 0.1, durationS: 3.0);
      expect(t.first, closeTo(0.1, 1e-12));
      expect(t.length, 6); // 0.1, 0.6, ... 2.6
      expect(t.every((v) => v >= 0 && v < 3.0), isTrue);
    });

    test('上限會截斷（不要為了一段長影片抽幾百幀）', () {
      final t = BladeDynamicsService.sixOclockTimes(
          periodS: 0.2, phaseS: 0.0, durationS: 60.0, maxFrames: 5);
      expect(t.length, 5);
    });

    test('週期無效時回空清單而不是猜一個', () {
      for (final p in [0.0, -1.0, double.nan, double.infinity]) {
        expect(
            BladeDynamicsService.sixOclockTimes(
                periodS: p, phaseS: 0.0, durationS: 10.0),
            isEmpty,
            reason: 'periodS = $p');
      }
    });
  });

  group('沒有可用素材時明確失敗', () {
    test('沒有取樣時刻 → 不 ok，理由指向「先取得通過週期」', () async {
      final r = await BladeDynamicsService.analyzeFrames(
        videoPath: 'clip.mp4',
        atSeconds: const [],
        extract: extractorOf(const []),
        geometry: analyzerOf(const []),
      );
      expect(r.ok, isFalse);
      expect(r.reasons.join(), contains('週期'));
      expect(r.radiusComparison, isNull);
    });

    test('一幀都抽不到 → 不 ok，並建議改用整機照', () async {
      final r = await BladeDynamicsService.analyzeFrames(
        videoPath: 'clip.mp4',
        atSeconds: const [0.0, 0.5, 1.0],
        extract: extractorOf(const [null, null, null]),
        geometry: analyzerOf(const []),
      );
      expect(r.ok, isFalse);
      expect(r.framesDecoded, 0);
      expect(r.reasons.join(), contains('整機照'));
    });

    test('抽到了但沒有一幀量得出朝下的葉片 → 不 ok，且說出解了幾幀', () async {
      final noDown = BladeGeometryOutcome(ok: true, profiles: [
        profile(index: 0, axisAngleDeg: 90.0, radiusPx: 300.0),
        profile(index: 1, axisAngleDeg: 210.0, radiusPx: 300.0),
        profile(index: 2, axisAngleDeg: 330.0, radiusPx: 300.0),
      ]);
      final r = await BladeDynamicsService.analyzeFrames(
        videoPath: 'clip.mp4',
        atSeconds: const [0.0, 0.5],
        extract: extractorOf([oneByte, oneByte]),
        geometry: analyzerOf([noDown, noDown]),
      );
      expect(r.ok, isFalse);
      expect(r.framesDecoded, 2);
      expect(r.framesMeasured, 0);
      expect(r.reasons.join(), contains('2 幀'));
    });

    test('抽幀丟例外時該幀算未解碼，其他幀照算', () async {
      var call = 0;
      final r = await BladeDynamicsService.analyzeFrames(
        videoPath: 'clip.mp4',
        atSeconds: const [0.0, 0.5, 1.0, 1.5, 2.0, 2.5],
        extract: (path, at) async {
          if (call++ == 0) throw StateError('decoder blew up');
          return oneByte;
        },
        geometry: analyzerOf(
            List.generate(6, (_) => frameWithDown(300.0))),
      );
      expect(r.ok, isTrue, reason: '一幀壞掉不該讓整段分析失敗');
      expect(r.framesDecoded, 5);
      expect(r.frames.first.decoded, isFalse);
    });
  });

  group('朝下的葉片', () {
    test('只挑落在 270° ± 25° 內的，超出就不算', () async {
      // 三片都離正下方很遠 → 沒有朝下的葉片
      final off = BladeGeometryOutcome(ok: true, profiles: [
        profile(index: 0, axisAngleDeg: 320.0, radiusPx: 300.0),
        profile(index: 1, axisAngleDeg: 80.0, radiusPx: 300.0),
        profile(index: 2, axisAngleDeg: 200.0, radiusPx: 300.0),
      ]);
      final r = await BladeDynamicsService.analyzeFrames(
        videoPath: 'clip.mp4',
        atSeconds: const [0.0, 0.5],
        extract: extractorOf([oneByte, oneByte]),
        geometry: analyzerOf([off, off]),
      );
      expect(r.framesMeasured, 0);
    });

    test('容差邊界內（24°）算，邊界外（26°）不算', () async {
      for (final entry in {24.0: 1, 26.0: 0}.entries) {
        final r = await BladeDynamicsService.analyzeFrames(
          videoPath: 'clip.mp4',
          atSeconds: const [0.0],
          extract: extractorOf([oneByte]),
          geometry: analyzerOf([frameWithDown(300.0, offDeg: entry.key)]),
        );
        expect(r.framesMeasured, entry.value, reason: 'off = ${entry.key}°');
      }
    });

    test('角度跨 0/360 時仍算得對（270 附近不會被繞回去坑到）', () async {
      final r = await BladeDynamicsService.analyzeFrames(
        videoPath: 'clip.mp4',
        atSeconds: const [0.0],
        extract: extractorOf([oneByte]),
        geometry: analyzerOf([
          BladeGeometryOutcome(ok: true, profiles: [
            profile(index: 0, axisAngleDeg: 265.0, radiusPx: 321.0),
            profile(index: 1, axisAngleDeg: 5.0, radiusPx: 300.0),
            profile(index: 2, axisAngleDeg: 125.0, radiusPx: 300.0),
          ])
        ]),
      );
      expect(r.framesMeasured, 1);
      expect(r.frames.first.downTipRadiusPx, 321.0);
    });
  });

  group('三片互比', () {
    /// n 幀，半徑依 [radii] 循環（模擬三片輪流通過六點鐘）
    Future<BladeDynamicsResult> runCycle(List<double> radii) {
      final times = List<double>.generate(radii.length, (i) => i * 0.5);
      return BladeDynamicsService.analyzeFrames(
        videoPath: 'clip.mp4',
        atSeconds: times,
        extract: extractorOf(List.filled(radii.length, oneByte)),
        geometry: analyzerOf(radii.map(frameWithDown).toList()),
      );
    }

    test('三片一致 → 不標記（而且真的比過了）', () async {
      final r = await runCycle([300, 300, 300, 301, 299, 300]);
      expect(r.ok, isTrue);
      expect(r.framesMeasured, 6);
      expect(r.radiusComparison, isNotNull, reason: '要比過，不是略過');
      expect(r.radiusComparison!.flagged, isFalse);
    });

    test('一片明顯短 → 標記，而且指對是哪一順位', () async {
      // 第 2 順位（index 1）短 30 px；每片各 2 幀
      final r = await runCycle([300, 270, 300, 301, 271, 299]);
      expect(r.radiusComparison, isNotNull);
      expect(r.radiusComparison!.flagged, isTrue);
      expect(r.radiusComparison!.outlierIndex, 1);
      expect(r.tipRadiusMedianPx[1], lessThan(r.tipRadiusMedianPx[0]));
    });

    test('半徑兩個方向都算異常（不限方向）', () async {
      final r = await runCycle([300, 340, 300, 301, 341, 299]);
      expect(r.radiusComparison!.flagged, isTrue);
      expect(r.radiusComparison!.direction, MetricDirection.both);
      expect(r.radiusComparison!.outlierIndex, 1);
    });

    test('每片不足 2 幀時不做互比，並說出為什麼', () async {
      final r = await runCycle([300, 270, 300]); // 每片各 1 幀
      expect(r.ok, isTrue);
      expect(r.radiusComparison, isNull,
          reason: '一幀就下結論等於把單幀雜訊當成葉片差異');
      expect(r.notes.join(), contains('中位數'));
      expect(r.tipRadiusMedianPx.every((v) => v.isNaN), isTrue);
    });

    test('缺測的幀不占標籤位置（否則後面全部錯位）', () async {
      // 第 2 幀抽不到：若缺測仍占位，第 3 幀會被標成第 3 片而不是第 2 片
      final r = await BladeDynamicsService.analyzeFrames(
        videoPath: 'clip.mp4',
        atSeconds: const [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0],
        extract: extractorOf(
            [oneByte, null, oneByte, oneByte, oneByte, oneByte, oneByte]),
        geometry: analyzerOf([300.0, 270.0, 300.0, 300.0, 270.0, 300.0]
            .map(frameWithDown)
            .toList()),
      );
      expect(r.framesMeasured, 6);
      // 量到的順序是 300,270,300,300,270,300 → 第 2 順位是短的那片
      expect(r.tipRadiusMedianPx[1], closeTo(270.0, 1e-9));
      expect(r.radiusComparison!.outlierIndex, 1);
    });

    test('未量到的幀不以內插值充當量測', () async {
      final r = await runCycle([300, 300, 300, 300, 300, 300]);
      for (final f in r.frames) {
        expect(f.measured, isTrue);
      }
      final partial = await BladeDynamicsService.analyzeFrames(
        videoPath: 'clip.mp4',
        atSeconds: const [0.0, 0.5],
        extract: extractorOf([oneByte, null]),
        geometry: analyzerOf([frameWithDown(300.0)]),
      );
      expect(partial.frames[1].downTipRadiusPx.isNaN, isTrue);
      expect(partial.notes.join(), contains('內插'));
    });

    test('閘門拒收的幀不算量測', () async {
      final r = await BladeDynamicsService.analyzeFrames(
        videoPath: 'clip.mp4',
        atSeconds: const [0.0, 0.5],
        extract: extractorOf([oneByte, oneByte]),
        geometry: analyzerOf([
          frameWithDown(300.0),
          const BladeGeometryOutcome(ok: false, reasons: ['三片半徑差太大']),
        ]),
      );
      expect(r.framesDecoded, 2);
      expect(r.framesMeasured, 1);
    });
  });

  group('標籤語意', () {
    test('備註要明講標籤是通過順序、且與聲音層同一個規則', () async {
      final r = await BladeDynamicsService.analyzeFrames(
        videoPath: 'clip.mp4',
        atSeconds: List<double>.generate(6, (i) => i * 0.5),
        extract: extractorOf(List.filled(6, oneByte)),
        geometry:
            analyzerOf(List.generate(6, (_) => frameWithDown(300.0))),
      );
      expect(r.notes.join(), contains('通過'));
      expect(r.notes.join(), contains('聲音層'));
    });
  });
}
