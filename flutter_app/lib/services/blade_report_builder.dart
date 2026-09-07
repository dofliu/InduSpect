import 'dart:typed_data';

import '../models/wt_asset.dart';
import '../models/wt_capture_session.dart';
import '../models/wt_detection.dart';
import 'pdf_report_service.dart';

/// 把葉片檢測的偵測結果組成 PDF 報告資料，交給既有的 `PdfReportService` 排版
/// （規格 §8：不另寫排版，重用定檢那條已經在跑的路徑）。
///
/// **這是篩檢報告，不下合格判定。** 手機地面拍攝屬 Level 1 目視篩檢，受解析度物理
/// 限制看不到髮絲裂縫與早期蝕點；「沒檢出」不等於「沒問題」。所以 verdict 只用
/// 不合格／警告／待判定，`合格` 一次都不會出現——這一點有測試守著。
class BladeReportBuilder {
  BladeReportBuilder._();

  /// 篩檢報告不下合格判定，這裡列出允許出現的 verdict
  static const Set<String> allowedVerdicts = {'不合格', '警告', '待判定'};

  static const String screeningDisclaimer =
      '本報告為演算法初判，需人工確認。未檢出異常不等於沒有異常——手機地面拍攝屬 '
      'Level 1 目視篩檢，受解析度物理限制，無法取代無人機定檢或近距離檢測。';

  /// severity（1–5）→ verdict。沒有 severity 的一律「待判定」。
  static String verdictOf(WtDetection d) {
    if (d.humanStatus == WtHumanStatus.rejected) return '待判定';
    final s = d.severity;
    if (s == null) return '待判定';
    if (s >= 4) return '不合格';
    if (s >= 2) return '警告';
    return '待判定';
  }

  static const Map<WtLayer, String> _layerLabel = {
    WtLayer.surface: '表面層',
    WtLayer.geometry: '幾何層',
    WtLayer.dynamic_: '動態層',
    WtLayer.periphery: '周邊',
  };

  static const Map<String, String> _zoneLabel = {
    'root': '根部段',
    'mid': '中段',
    'tip': '葉尖段',
    'root_LE': '根部段前緣',
    'mid_LE': '中段前緣',
    'tip_LE': '葉尖段前緣',
    'root_TE': '根部段後緣',
    'mid_TE': '中段後緣',
    'tip_TE': '葉尖段後緣',
  };

  static const Map<String, String> _defectLabel = {
    'leading_edge_erosion': '前緣侵蝕',
    'trailing_edge_crack': '後緣開裂',
    'surface_roughness': '表面粗糙',
    'tip_deflection': '葉尖偏移異常',
    'blade_mismatch': '三片形狀不一致',
    'attachment_missing': '附加件缺失',
    'oil_stain': '塔身油污',
    'capture_quality': '拍攝品質不足',
  };

  /// 一筆偵測的顯示標題：「葉片 A · 中段前緣 · 前緣侵蝕」
  static String labelOf(WtDetection d) {
    final parts = <String>[];
    if (d.blade != null) parts.add('葉片 ${d.blade}');
    final zone = d.zone;
    if (zone != null) parts.add(_zoneLabel[zone] ?? zone);
    parts.add(_defectLabel[d.defectClass] ?? d.defectClass ?? '未分類發現');
    return parts.join(' · ');
  }

  /// 關鍵數值的一行摘要。演算法算的數字要看得到，不能只留一個等級。
  static String? valueOf(WtDetection d) {
    final m = d.metricJson;
    final bits = <String>[];
    void add(String key, String label, {int digits = 2, String unit = ''}) {
      final v = m[key];
      if (v is num) bits.add('$label ${v.toStringAsFixed(digits)}$unit');
    }

    add('le_over_te_rms_ratio', '前緣/後緣粗糙度比');
    add('inward_p95_px', '往內凹 p95', digits: 2, unit: ' px');
    add('inward_p95_cm', '往內凹 p95', digits: 1, unit: ' cm');
    add('pit_count', '凹坑', digits: 0, unit: ' 處');
    add('tip_deflection_px', '葉尖偏移', digits: 1, unit: ' px');
    add('tip_deflection_cm', '葉尖偏移', digits: 0, unit: ' cm');
    add('rpm', '轉速', digits: 1, unit: ' rpm');
    if (d.confidence != null) {
      bits.add('信賴度 ${(d.confidence! * 100).toStringAsFixed(0)}%');
    }
    return bits.isEmpty ? null : bits.join('；');
  }

  /// 判定依據：寫的是**演算法的判據**，不是法規——葉片檢測沒有對應的法規門檻，
  /// 硬套一條會誤導稽核。
  static String? basisOf(WtDetection d) {
    switch (d.defectClass) {
      case 'leading_edge_erosion':
        return '同一張照片內前緣與後緣互比，rms 比 ≥ 2 且往內凹 p95 ≥ 3× 乾淨值';
      case 'tip_deflection':
      case 'blade_mismatch':
        return '三片同批同型，同一轉子位置的剪影應一致；偏差 ≥ 3× 量測雜訊底';
      case 'capture_quality':
        return '拍攝品質閘門：結構定位可信度不足，數值不可採信';
      default:
        return null;
    }
  }

  /// 組報告資料。`detections` 只放要列進報告的（通常是未被人工駁回的）。
  static PdfReportData buildData({
    required WtAsset asset,
    required WtCaptureSession session,
    required List<WtDetection> detections,
    String? summary,
  }) {
    final items = <PdfReportItem>[];
    for (final d in detections) {
      if (d.humanStatus == WtHumanStatus.rejected) continue; // 人工駁回的不列
      items.add(PdfReportItem(
        fieldId: d.detectionId,
        label: '${_layerLabel[d.layer] ?? ''}｜${labelOf(d)}',
        value: valueOf(d),
        verdict: verdictOf(d),
        standardBasis: basisOf(d),
        anomalyDescription: d.aiDescription,
        photoPath: d.mediaPath,
      ));
    }

    // 沒有任何發現時**不能留白**，也不能寫「合格」——要明確講清楚這代表什麼
    final head = items.isEmpty
        ? '本次未檢出超出門檻的異常。這不等於葉片沒有問題：$screeningDisclaimer'
        : screeningDisclaimer;

    return PdfReportData(
      title: _titleOf(asset, session),
      inspectionDate: session.capturedAt,
      locationName: asset.siteName.isEmpty ? null : asset.siteName,
      latitude: session.latitude,
      longitude: session.longitude,
      recordId: session.sessionId,
      items: items,
      summaryReport: summary == null || summary.isEmpty ? head : '$head\n\n$summary',
      extraPhotoPaths: _unusedPhotos(session, detections),
    );
  }

  static Future<Uint8List> build({
    required WtAsset asset,
    required WtCaptureSession session,
    required List<WtDetection> detections,
    String? summary,
    bool includePhotos = true,
    ByteData? fontData,
    PdfPhotoLoader? photoLoader,
  }) =>
      PdfReportService.build(
        buildData(
            asset: asset, session: session, detections: detections, summary: summary),
        includePhotos: includePhotos,
        fontData: fontData,
        photoLoader: photoLoader,
      );

  static String _titleOf(WtAsset asset, WtCaptureSession session) {
    if (session.title.isNotEmpty) return session.title;
    final d = session.capturedAt;
    final date = '${d.year}-${_two(d.month)}-${_two(d.day)}';
    return '${asset.assetId} 葉片檢測 $date';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// 沒有被任何偵測引用的照片。**照樣附進報告**——現場拍了什麼要留得下來，
  /// 而且「哪些照片沒有產生發現」本身就是資訊。
  ///
  /// 「已引用」只算**真的列進報告**的那些發現。人工駁回的發現不成列，
  /// 若把它的照片也算成已引用，那張照片就會從報告上整個消失——
  /// 駁回的是「這是缺陷」這個判斷，不是「這張照片存在」這件事。
  static List<String> _unusedPhotos(
      WtCaptureSession session, List<WtDetection> detections) {
    final used = detections
        .where((d) => d.humanStatus != WtHumanStatus.rejected)
        .map((d) => d.mediaPath)
        .whereType<String>()
        .toSet();
    return session.media
        .where((m) => m.kind == WtMediaKind.photo && !used.contains(m.path))
        .map((m) => m.path)
        .toList();
  }
}
