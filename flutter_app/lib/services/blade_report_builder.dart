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

  /// zone key → 中文。**公開**：歷史／趨勢畫面要用同一組標籤，
  /// 各寫一份的話報告與畫面上同一個格位會出現不同名字。
  static const Map<String, String> zoneLabels = {
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
    'blade_noise': '單片寬頻噪音偏高',
    'blade_noise_hf': '單片高頻能量偏高',
    'blade_whistle': '單片窄頻哨音',
    'tip_radius_mismatch': '葉尖半徑不一致（多幀）',
    'audio_unusable': '音軌不可用',
  };

  /// 一筆偵測的顯示標題：「葉片 A · 中段前緣 · 前緣侵蝕」
  static String labelOf(WtDetection d) {
    final parts = <String>[];
    if (d.blade != null) parts.add('葉片 ${d.blade}');
    final zone = d.zone;
    if (zone != null) parts.add(zoneLabels[zone] ?? zone);
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
    add('radius_px_deviation_cm', '葉片長度差', digits: 0, unit: ' cm');
    add('mean_width_px_deviation_cm', '弦寬差', digits: 0, unit: ' cm');
    add('rpm', '轉速', digits: 1, unit: ' rpm');
    add('rpm_from_audio', '音軌轉速', digits: 1, unit: ' rpm');
    add('band_level_db_deviation', '寬頻位準高出', digits: 1, unit: ' dB');
    add('high_band_ratio_deviation', '高頻占比高出', digits: 3);
    add('tonal_freq_hz', '哨音頻率', digits: 0, unit: ' Hz');
    add('tonal_prominence_db', '哨音突出', digits: 1, unit: ' dB');
    add('tip_radius_deviation_px', '葉尖半徑差', digits: 1, unit: ' px');
    add('envelope_snr_db', '包絡訊噪比', digits: 1, unit: ' dB');
    // cm 值是怎麼換的要看得到：型錄轉子半徑 ÷ 量到的葉長。沒有它就沒有任何 cm 值。
    add('cm_per_px', '尺度', digits: 2, unit: ' cm/px');
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
      case 'blade_noise':
      case 'blade_noise_hf':
        return '三片每轉各通過觀測者一次，缺陷葉片的噪音以葉片通過週期出現；'
            '依通過時刻切分音軌後三片互比，只有**偏高**才算徵兆';
      case 'blade_whistle':
        return '窄頻峰突出本地頻譜基線 ≥ 6 dB 且只在單片的通過視窗出現';
      case 'tip_radius_mismatch':
        return '同一片在多幀取中位（抵消風吹擺動）後與另兩片互比，'
            '偏差 ≥ 3× 量測雜訊底';
      case 'audio_unusable':
        return '三重守門：轉動週期信賴度、包絡訊噪比、低頻（風噪）能量占比';
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
    final body = items.isEmpty
        ? '本次未檢出超出門檻的異常。這不等於葉片沒有問題：$screeningDisclaimer'
        : screeningDisclaimer;
    // 風機狀態／天氣／人員（規格 §10.2）寫在最前面：讀報告的人第一件要知道的
    // 是「這次是停機還是運轉拍的」——聲音層只在轉動時有意義。
    final meta = sessionMetaLine(session);
    final head = meta == null ? body : '$meta\n\n$body';

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

  /// 風機狀態的中文標籤。`unknown` 是「未記錄」不是「不知道」——沒填就是沒填。
  static String turbineStateLabel(WtTurbineState s) {
    switch (s) {
      case WtTurbineState.stopped:
        return '停機';
      case WtTurbineState.idling:
        return '怠速';
      case WtTurbineState.running:
        return '運轉';
      case WtTurbineState.unknown:
        return '未記錄';
    }
  }

  /// 本次作業的 metadata 一行：`風機狀態：停機｜天氣：晴｜檢測人員：王小明`。
  /// 三個都沒填就回 null——不要印一行「未記錄｜（空）｜（空）」。
  static String? sessionMetaLine(WtCaptureSession session) {
    final parts = <String>[
      if (session.turbineState != WtTurbineState.unknown)
        '風機狀態：${turbineStateLabel(session.turbineState)}',
      if (session.weatherNote != null && session.weatherNote!.trim().isNotEmpty)
        '天氣：${session.weatherNote!.trim()}',
      if (session.inspector != null && session.inspector!.trim().isNotEmpty)
        '檢測人員：${session.inspector!.trim()}',
    ];
    return parts.isEmpty ? null : parts.join('｜');
  }

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
