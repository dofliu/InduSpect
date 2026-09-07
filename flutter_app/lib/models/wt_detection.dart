import 'dart:convert';

/// 偵測層。對應規格 §4 的四層。
enum WtLayer { surface, geometry, dynamic_, periphery }

/// 產出來源。離線時演算法照跑、AI 解讀掛在佇列裡等連線（規格 §6）。
enum WtDetectionSource { algorithm, gemini, geminiOfflinePending }

/// 人工確認狀態。**演算法與 AI 都只是初判**，簽核前不具效力。
enum WtHumanStatus { pending, confirmed, rejected }

/// 一筆偵測結果 — 對應 SQLite `wt_detections` 表（v5 新增，規格 §7）。
///
/// 一筆一個發現。同一張照片可以有多筆（不同 zone、不同缺陷類別）。
class WtDetection {
  final int? id;
  final String detectionId;
  final String sessionId;
  final WtLayer layer;
  final String? blade; // 'A' | 'B' | 'C'
  final String? zone; // 'root' | 'mid' | 'tip'（可加 '_LE' / '_TE'）
  final String? defectClass;
  final int? severity; // 1–5
  final double? confidence;
  final Map<String, dynamic> metricJson; // 演算法數值：粗糙度、比值、rpm…
  final Map<String, dynamic> bboxJson;
  final String? mediaPath;
  final WtDetectionSource source;
  WtHumanStatus humanStatus;
  String? humanNote;
  String? aiDescription;
  final DateTime createdAt;

  WtDetection({
    this.id,
    required this.detectionId,
    required this.sessionId,
    required this.layer,
    this.blade,
    this.zone,
    this.defectClass,
    this.severity,
    this.confidence,
    Map<String, dynamic>? metricJson,
    Map<String, dynamic>? bboxJson,
    this.mediaPath,
    this.source = WtDetectionSource.algorithm,
    this.humanStatus = WtHumanStatus.pending,
    this.humanNote,
    this.aiDescription,
    DateTime? createdAt,
  })  : metricJson = metricJson ?? {},
        bboxJson = bboxJson ?? {},
        createdAt = createdAt ?? DateTime.now();

  /// 是否還等著人工確認。報告上的「☐ 待確認」欄看這個。
  bool get needsConfirmation => humanStatus == WtHumanStatus.pending;

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'detection_id': detectionId,
      'session_id': sessionId,
      'layer': layer.name,
      'blade': blade,
      'zone': zone,
      'defect_class': defectClass,
      'severity': severity,
      'confidence': confidence,
      'metric_json': jsonEncode(metricJson),
      'bbox_json': jsonEncode(bboxJson),
      'media_path': mediaPath,
      'source': source.name,
      'human_status': humanStatus.name,
      'human_note': humanNote,
      'ai_description': aiDescription,
      'created_at': createdAt.toIso8601String(),
    };
    if (id != null) map['id'] = id;
    return map;
  }

  factory WtDetection.fromMap(Map<String, dynamic> map) => WtDetection(
        id: map['id'] as int?,
        detectionId: map['detection_id'] as String,
        sessionId: map['session_id'] as String,
        layer: _enumOf(WtLayer.values, map['layer'], WtLayer.surface),
        blade: map['blade'] as String?,
        zone: map['zone'] as String?,
        defectClass: map['defect_class'] as String?,
        severity: map['severity'] as int?,
        confidence: (map['confidence'] as num?)?.toDouble(),
        metricJson: _decodeJson(map['metric_json']),
        bboxJson: _decodeJson(map['bbox_json']),
        mediaPath: map['media_path'] as String?,
        source: _enumOf(
            WtDetectionSource.values, map['source'], WtDetectionSource.algorithm),
        humanStatus:
            _enumOf(WtHumanStatus.values, map['human_status'], WtHumanStatus.pending),
        humanNote: map['human_note'] as String?,
        aiDescription: map['ai_description'] as String?,
        createdAt:
            DateTime.tryParse(map['created_at'] as String? ?? '') ?? DateTime.now(),
      );

  static Map<String, dynamic> _decodeJson(dynamic raw) {
    if (raw == null || (raw is String && raw.isEmpty)) return {};
    try {
      final decoded = jsonDecode(raw as String);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {
      // 同既有 model：壞掉的 JSON 回空 map，不讓整筆偵測讀不出來
    }
    return {};
  }
}

T _enumOf<T extends Enum>(List<T> values, dynamic raw, T fallback) {
  final name = raw as String?;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}
