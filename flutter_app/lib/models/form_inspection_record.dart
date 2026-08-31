import 'dart:convert';

/// 表單檢測紀錄狀態
enum FormRecordStatus {
  draft,      // 草稿（檢測中）
  completed,  // 已完成（未匯出）
  exported,   // 已匯出文件
  shared,     // 已分享
}

/// 表單檢測紀錄 — 對應 SQLite form_inspection_records 表
class FormInspectionRecord {
  final int? id;
  final String recordId;
  String title;
  final String? sourceFileName;
  final String? templateJson;
  final Map<String, dynamic> filledData;
  final Map<String, dynamic> aiResults;

  /// 法規標準判定結果（fieldId → judgment map），v4 新增。
  /// judgment map 結構同後端 judge-readings 回傳：
  /// {judgment, standard_text, regulation, converted_value, converted_unit, ...}
  /// 法規判定是稽核依據，必須隨紀錄留存（Issue #44）。
  final Map<String, dynamic> standardJudgments;
  String? summaryReport;
  String? filledDocumentPath;
  FormRecordStatus status;
  final double? latitude;
  final double? longitude;
  final String? locationName;
  final List<String> photoPaths;
  final DateTime createdAt;
  DateTime updatedAt;
  bool pendingShare;

  FormInspectionRecord({
    this.id,
    required this.recordId,
    required this.title,
    this.sourceFileName,
    this.templateJson,
    Map<String, dynamic>? filledData,
    Map<String, dynamic>? aiResults,
    Map<String, dynamic>? standardJudgments,
    this.summaryReport,
    this.filledDocumentPath,
    this.status = FormRecordStatus.draft,
    this.latitude,
    this.longitude,
    this.locationName,
    List<String>? photoPaths,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.pendingShare = false,
  })  : filledData = filledData ?? {},
        aiResults = aiResults ?? {},
        standardJudgments = standardJudgments ?? {},
        photoPaths = photoPaths ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// 異常項目數
  int get anomalyCount {
    int count = 0;
    for (final result in aiResults.values) {
      if (result is Map && result['is_anomaly'] == true) {
        count++;
      }
    }
    return count;
  }

  /// 已完成項目數
  int get completedCount => filledData.length;

  /// 法規判定不合格項目數
  int get failCount => standardJudgments.values
      .where((j) => j is Map && j['judgment'] == 'fail')
      .length;

  /// 法規判定警告項目數
  int get warningCount => standardJudgments.values
      .where((j) => j is Map && j['judgment'] == 'warning')
      .length;

  /// 轉為 SQLite Map
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'record_id': recordId,
      'title': title,
      'source_file_name': sourceFileName,
      'template_json': templateJson,
      'filled_data': jsonEncode(filledData),
      'ai_results': jsonEncode(aiResults),
      'standard_judgments': jsonEncode(standardJudgments),
      'summary_report': summaryReport,
      'filled_document_path': filledDocumentPath,
      'status': status.name,
      'latitude': latitude,
      'longitude': longitude,
      'location_name': locationName,
      'photo_paths': jsonEncode(photoPaths),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'pending_share': pendingShare ? 1 : 0,
    };
    if (id != null) map['id'] = id;
    return map;
  }

  /// 從 SQLite Map 建立
  factory FormInspectionRecord.fromMap(Map<String, dynamic> map) {
    return FormInspectionRecord(
      id: map['id'] as int?,
      recordId: map['record_id'] as String,
      title: map['title'] as String,
      sourceFileName: map['source_file_name'] as String?,
      templateJson: map['template_json'] as String?,
      filledData: _decodeJson(map['filled_data']),
      aiResults: _decodeJson(map['ai_results']),
      // v3 舊紀錄無此欄位 → _decodeJson(null) 回空 map，向後相容
      standardJudgments: _decodeJson(map['standard_judgments']),
      summaryReport: map['summary_report'] as String?,
      filledDocumentPath: map['filled_document_path'] as String?,
      status: FormRecordStatus.values.firstWhere(
        (s) => s.name == (map['status'] as String? ?? 'draft'),
        orElse: () => FormRecordStatus.draft,
      ),
      latitude: map['latitude'] as double?,
      longitude: map['longitude'] as double?,
      locationName: map['location_name'] as String?,
      photoPaths: _decodePaths(map['photo_paths'] as String?),
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? '') ?? DateTime.now(),
      pendingShare: (map['pending_share'] as int? ?? 0) == 1,
    );
  }

  /// 建立副本
  FormInspectionRecord copyWith({
    int? id,
    String? recordId,
    String? title,
    String? sourceFileName,
    String? templateJson,
    Map<String, dynamic>? filledData,
    Map<String, dynamic>? aiResults,
    Map<String, dynamic>? standardJudgments,
    String? summaryReport,
    String? filledDocumentPath,
    FormRecordStatus? status,
    double? latitude,
    double? longitude,
    String? locationName,
    List<String>? photoPaths,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? pendingShare,
  }) {
    return FormInspectionRecord(
      id: id ?? this.id,
      recordId: recordId ?? this.recordId,
      title: title ?? this.title,
      sourceFileName: sourceFileName ?? this.sourceFileName,
      templateJson: templateJson ?? this.templateJson,
      filledData: filledData ?? Map.from(this.filledData),
      aiResults: aiResults ?? Map.from(this.aiResults),
      standardJudgments: standardJudgments ?? Map.from(this.standardJudgments),
      summaryReport: summaryReport ?? this.summaryReport,
      filledDocumentPath: filledDocumentPath ?? this.filledDocumentPath,
      status: status ?? this.status,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      locationName: locationName ?? this.locationName,
      photoPaths: photoPaths ?? List.from(this.photoPaths),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      pendingShare: pendingShare ?? this.pendingShare,
    );
  }

  static Map<String, dynamic> _decodeJson(dynamic value) {
    if (value == null || value == '') return {};
    if (value is String) {
      try {
        return Map<String, dynamic>.from(jsonDecode(value) as Map);
      } catch (_) {
        return {};
      }
    }
    return {};
  }

  static List<String> _decodePaths(String? value) {
    if (value == null || value.isEmpty) return [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) return decoded.cast<String>();
    } catch (_) {
      // 向後相容舊格式 (|||)
      return value.split('|||').where((s) => s.isNotEmpty).toList();
    }
    return [];
  }
}
