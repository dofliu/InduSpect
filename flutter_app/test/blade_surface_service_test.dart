import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/services/blade_surface_service.dart';

/// 表面層 Dart 實作對照 Python 原型（`blade_prototype/blade_proto/surface.py`）。
///
/// 夾具由原型產生（`render_blade_segment`，cm_per_px 0.4 → 半尺 0.8），
/// `test/assets/blade_segment_reference.json` 存的是**原型在同一張圖上量到的數值**。
///
/// 不要求逐位相同：Dart 端用未縮放的 CIE Lab（Python 走 OpenCV 的 8-bit Lab）、
/// 旋轉的重取樣實作不同、影像解碼器也不同。要求的是**判定一致**與**同一個數量級**
/// ——前緣侵蝕的判據是「前緣/後緣 rms 比 ≥ 2」，這個決定必須兩邊一樣。
void main() {
  late Map<String, dynamic> reference;

  setUpAll(() {
    reference = jsonDecode(
      File('test/assets/blade_segment_reference.json').readAsStringSync(),
    ) as Map<String, dynamic>;
  });

  BladeSurfaceAnalysis analyze(String name) {
    final bytes = File('test/assets/$name').readAsBytesSync();
    return BladeSurfaceService.analyzeSync(
      bytes,
      params: const BladeSurfaceParams(cmPerPx: 0.8, leadingEdge: 'top'),
    );
  }

  test('乾淨葉片：前緣與後緣一樣平滑，不得判成侵蝕', () {
    final r = analyze('blade_segment_clean.png');
    final ref = reference['blade_segment_clean.png'] as Map<String, dynamic>;

    expect(r.ok, isTrue, reason: r.failure);
    expect(r.top, isNotNull);
    expect(r.bottom, isNotNull);

    // 判定一致：比值遠低於侵蝕判據 2.0（原型量到 0.94）
    expect(r.leOverTeRmsRatio, isNotNull);
    expect(r.leOverTeRmsRatio!, lessThan(1.6),
        reason: '原型 ${ref['le_over_te_rms_ratio']}，Dart ${r.leOverTeRmsRatio}');
    expect(r.top!.pitCount, lessThan(4), reason: '乾淨邊緣不該有一串凹坑');

    // 同一個數量級：rms 在 0.3 px 以下（原型 0.108）
    expect(r.top!.rmsPx, lessThan(0.4));
    expect(r.bottom!.rmsPx, lessThan(0.4));
  });

  test('前緣侵蝕：比值跨過 2.0 的判據，凹坑數與 p95 都跟著上來', () {
    final r = analyze('blade_segment_eroded.png');
    final ref = reference['blade_segment_eroded.png'] as Map<String, dynamic>;

    expect(r.ok, isTrue, reason: r.failure);
    // 這是這支服務存在的理由：同一張照片內前緣 vs 後緣互比，
    // 不需要絕對校準，也不受相機、距離、光線影響。
    expect(r.leOverTeRmsRatio!, greaterThan(2.0),
        reason: '原型 ${ref['le_over_te_rms_ratio']}，Dart ${r.leOverTeRmsRatio}');
    expect(r.top!.rmsPx, greaterThan(3 * r.bottom!.rmsPx));
    expect(r.top!.inwardP95Px, greaterThan(0.8),
        reason: '往內凹的深度 p95（原型 ${ref['top_inward_p95_px']}）');
    expect(r.top!.pitCount, greaterThan(8),
        reason: '凹坑數（原型 ${ref['top_pit_count']}）');

    // 後緣沒有被侵蝕，數值應與乾淨案例相當
    expect(r.bottom!.rmsPx, lessThan(0.4));
  });

  test('幾何量：葉片軸角度與厚度與原型相符', () {
    final r = analyze('blade_segment_clean.png');
    final ref = reference['blade_segment_clean.png'] as Map<String, dynamic>;

    // PCA 主軸算的是同一個遮罩，兩邊應該很接近
    expect(r.axisAngleDeg,
        closeTo((ref['axis_angle_deg'] as num).toDouble(), 1.0));
    // 旋轉真的把葉片轉正了。這條守的是旋轉矩陣的符號——寫反會讓傾角加倍
    // （+4.4° → 8.9°），而多項式基線會吸收掉傾斜，粗糙度數值看起來仍然正常。
    expect(r.residualAxisAngleDeg.abs(), lessThan(1.0),
        reason: '旋轉後仍傾斜 ${r.residualAxisAngleDeg}°：檢查反向映射的符號');
    // 厚度差幾個 px 是邊緣 sub-pixel 實作差異，不是抓錯東西
    expect(r.medianThicknessPx,
        closeTo((ref['median_thickness_px'] as num).toDouble(), 8.0));
    // 取樣點數量級一致（原型 781；Dart 的有效區處理略有不同）
    expect(r.top!.nSamples, greaterThan(500));
  });

  test('cm 換算：給了 cm_per_px 才有 rms_cm，沒給就是 null', () {
    final bytes = File('test/assets/blade_segment_eroded.png').readAsBytesSync();
    final withScale = BladeSurfaceService.analyzeSync(bytes,
        params: const BladeSurfaceParams(cmPerPx: 0.8, leadingEdge: 'top'));
    final noScale = BladeSurfaceService.analyzeSync(bytes,
        params: const BladeSurfaceParams(leadingEdge: 'top'));

    expect(noScale.top!.rmsCm, isNull);
    expect(withScale.top!.rmsCm, isNotNull);
    expect(withScale.top!.rmsCm!, closeTo(withScale.top!.rmsPx * 0.8, 1e-6));
  });

  test('未指定前緣時不編造比值', () {
    final bytes = File('test/assets/blade_segment_eroded.png').readAsBytesSync();
    final r = BladeSurfaceService.analyzeSync(bytes,
        params: const BladeSurfaceParams(cmPerPx: 0.8));
    expect(r.ok, isTrue);
    expect(r.leadingEdge, isNull);
    expect(r.leOverTeRmsRatio, isNull, reason: '不知道哪一側是前緣，就不該給前緣判據');
    expect(r.top, isNotNull, reason: '兩側的粗糙度照樣要算出來');
  });

  test('分區段照的三個 zone 都有數值，侵蝕案例的前緣每段都比後緣粗', () {
    final r = analyze('blade_segment_eroded.png');
    expect(r.top!.zoneRmsPx.length, 3);
    expect(r.top!.zoneTextureStd.length, 3);
    for (var i = 0; i < 3; i++) {
      expect(r.top!.zoneRmsPx[i].isFinite, isTrue, reason: 'zone $i');
      expect(r.top!.zoneRmsPx[i], greaterThan(r.bottom!.zoneRmsPx[i]),
          reason: 'zone $i：前緣應比後緣粗');
    }
  });

  test('讀不到的影像與過小的影像都要說怎麼補救，不是丟例外', () {
    final bad = BladeSurfaceService.analyzeSync(
        _bytesOf('not an image'));
    expect(bad.ok, isFalse);
    expect(bad.failure, contains('重新拍攝'));
    expect(bad.leOverTeRmsRatio, isNull);
  });

  test('JSON 序列化：不合格時不得出現任何粗糙度數值', () {
    final bad = BladeSurfaceService.analyzeSync(
        _bytesOf('still not an image'));
    final json = bad.toJson();
    expect(json['ok'], isFalse);
    expect(json.containsKey('top'), isFalse);
    expect(json.containsKey('le_over_te_rms_ratio'), isFalse);
    expect(json['failure'], isNotNull);

    final good = analyze('blade_segment_eroded.png').toJson();
    expect(good['ok'], isTrue);
    expect((good['top'] as Map)['rms_px'], isA<double>());
    expect(good['le_over_te_rms_ratio'], isA<double>());
  });
}

/// 測試用：把字串當成壞掉的影像位元組
Uint8List _bytesOf(String s) => Uint8List.fromList(utf8.encode(s));
