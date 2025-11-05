import 'template_field.dart';

/// 模板元數據
class TemplateMetadata {
  final String company;
  final String department;
  final int inspectionCycleDays;
  final int estimatedDurationMinutes;
  final List<String> requiredTools;
  final String? safetyNotes;

  TemplateMetadata({
    required this.company,
    required this.department,
    required this.inspectionCycleDays,
    required this.estimatedDurationMinutes,
    required this.requiredTools,
    this.safetyNotes,
  });

  factory TemplateMetadata.fromJson(Map<String, dynamic> json) {
    return TemplateMetadata(
      company: json['company'] ?? '',
      department: json['department'] ?? '',
      inspectionCycleDays: json['inspection_cycle_days'] ?? 30,
      estimatedDurationMinutes: json['estimated_duration_minutes'] ?? 30,
      requiredTools: json['required_tools'] != null
          ? List<String>.from(json['required_tools'])
          : [],
      safetyNotes: json['safety_notes'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'company': company,
      'department': department,
      'inspection_cycle_days': inspectionCycleDays,
      'estimated_duration_minutes': estimatedDurationMinutes,
      'required_tools': requiredTools,
      if (safetyNotes != null) 'safety_notes': safetyNotes,
    };
  }
}

/// 模板區段
class TemplateSection {
  final String sectionId;
  final String sectionTitle;
  final int sectionOrder;
  final String? description;
  final List<TemplateField> fields;

  TemplateSection({
    required this.sectionId,
    required this.sectionTitle,
    required this.sectionOrder,
    this.description,
    required this.fields,
  });

  factory TemplateSection.fromJson(Map<String, dynamic> json) {
    return TemplateSection(
      sectionId: json['section_id'] ?? '',
      sectionTitle: json['section_title'] ?? '',
      sectionOrder: json['section_order'] ?? 0,
      description: json['description'],
      fields: json['fields'] != null
          ? (json['fields'] as List)
              .map((f) => TemplateField.fromJson(f))
              .toList()
          : [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'section_id': sectionId,
      'section_title': sectionTitle,
      'section_order': sectionOrder,
      if (description != null) 'description': description,
      'fields': fields.map((f) => f.toJson()).toList(),
    };
  }

  /// 取得此區段中應該顯示的欄位
  List<TemplateField> getVisibleFields(Map<String, dynamic> filledData) {
    return fields.where((field) => field.shouldShow(filledData)).toList();
  }

  /// 取得此區段中的必填欄位
  List<TemplateField> getRequiredFields() {
    return fields.where((field) => field.required).toList();
  }

  /// 檢查此區段是否全部填寫完成
  bool isCompleted(Map<String, dynamic> filledData) {
    final visibleFields = getVisibleFields(filledData);
    final requiredFields = visibleFields.where((f) => f.required);

    for (final field in requiredFields) {
      final value = filledData[field.fieldId];
      if (value == null) return false;
      if (value is String && value.isEmpty) return false;
      if (value is List && value.isEmpty) return false;
    }

    return true;
  }
}

/// 檢測模板
class InspectionTemplate {
  final String templateId;
  final String templateName;
  final String templateVersion;
  final String category;
  final DateTime createdAt;
  final DateTime updatedAt;
  final TemplateMetadata metadata;
  final List<TemplateSection> sections;

  InspectionTemplate({
    required this.templateId,
    required this.templateName,
    required this.templateVersion,
    required this.category,
    required this.createdAt,
    required this.updatedAt,
    required this.metadata,
    required this.sections,
  });

  factory InspectionTemplate.fromJson(Map<String, dynamic> json) {
    return InspectionTemplate(
      templateId: json['template_id'] ?? '',
      templateName: json['template_name'] ?? '',
      templateVersion: json['template_version'] ?? '1.0',
      category: json['category'] ?? '',
      createdAt: DateTime.parse(json['created_at'] ?? DateTime.now().toIso8601String()),
      updatedAt: DateTime.parse(json['updated_at'] ?? DateTime.now().toIso8601String()),
      metadata: TemplateMetadata.fromJson(json['metadata'] ?? {}),
      sections: json['sections'] != null
          ? (json['sections'] as List)
              .map((s) => TemplateSection.fromJson(s))
              .toList()
          : [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'template_id': templateId,
      'template_name': templateName,
      'template_version': templateVersion,
      'category': category,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'metadata': metadata.toJson(),
      'sections': sections.map((s) => s.toJson()).toList(),
    };
  }

  /// 取得所有欄位（扁平化）
  List<TemplateField> getAllFields() {
    return sections.expand((section) => section.fields).toList();
  }

  /// 根據 field_id 查找欄位
  TemplateField? getFieldById(String fieldId) {
    for (final section in sections) {
      for (final field in section.fields) {
        if (field.fieldId == fieldId) return field;
      }
    }
    return null;
  }

  /// 根據 section_id 查找區段
  TemplateSection? getSectionById(String sectionId) {
    return sections.firstWhere(
      (s) => s.sectionId == sectionId,
      orElse: () => sections.first,
    );
  }

  /// 計算總欄位數
  int getTotalFieldCount() {
    return getAllFields().length;
  }

  /// 計算必填欄位數
  int getRequiredFieldCount() {
    return getAllFields().where((f) => f.required).length;
  }

  /// 計算已填寫欄位數
  int getFilledFieldCount(Map<String, dynamic> filledData) {
    int count = 0;
    for (final field in getAllFields()) {
      final value = filledData[field.fieldId];
      if (value != null) {
        if (value is String && value.isNotEmpty) count++;
        else if (value is! String) count++;
      }
    }
    return count;
  }

  /// 計算完成百分比
  double getCompletionPercentage(Map<String, dynamic> filledData) {
    final total = getTotalFieldCount();
    if (total == 0) return 0.0;

    final filled = getFilledFieldCount(filledData);
    return (filled / total * 100).clamp(0.0, 100.0);
  }

  /// 驗證所有欄位
  Map<String, String> validateAll(Map<String, dynamic> filledData) {
    final errors = <String, String>{};

    for (final field in getAllFields()) {
      if (!field.shouldShow(filledData)) continue;

      final value = filledData[field.fieldId];
      final error = field.validate(value);
      if (error != null) {
        errors[field.fieldId] = error;
      }
    }

    return errors;
  }

  /// 檢查是否全部填寫完成
  bool isFullyCompleted(Map<String, dynamic> filledData) {
    return validateAll(filledData).isEmpty;
  }

  /// 取得所有警告訊息
  Map<String, String> getAllWarnings(Map<String, dynamic> filledData) {
    final warnings = <String, String>{};

    for (final field in getAllFields()) {
      final value = filledData[field.fieldId];
      final warning = field.checkWarning(value);
      if (warning != null) {
        warnings[field.fieldId] = warning;
      }
    }

    return warnings;
  }

  /// 取得所有照片欄位
  List<TemplateField> getPhotoFields() {
    return getAllFields().where((f) =>
        f.fieldType == FieldType.photo ||
        f.fieldType == FieldType.photoMultiple
    ).toList();
  }

  /// 取得所有需要 AI 分析的欄位
  List<TemplateField> getAIAnalyzableFields() {
    return getAllFields().where((f) => f.aiAnalyze == true).toList();
  }

  /// 取得所有可 AI 填入的欄位
  List<TemplateField> getAIFillableFields() {
    return getAllFields().where((f) => f.aiFillable).toList();
  }
}

/// 模板填寫記錄（與 InspectionRecord 整合）
class TemplateFillingRecord {
  final String recordId;
  final String templateId;
  final String? equipmentId;
  final String? equipmentName;
  final Map<String, dynamic> filledData;
  final String status; // draft, completed, submitted
  final DateTime createdAt;
  final DateTime? completedAt;
  final bool syncedToBackend;
  final String? pdfPath;

  TemplateFillingRecord({
    required this.recordId,
    required this.templateId,
    this.equipmentId,
    this.equipmentName,
    required this.filledData,
    required this.status,
    required this.createdAt,
    this.completedAt,
    required this.syncedToBackend,
    this.pdfPath,
  });

  factory TemplateFillingRecord.fromJson(Map<String, dynamic> json) {
    return TemplateFillingRecord(
      recordId: json['record_id'] ?? '',
      templateId: json['template_id'] ?? '',
      equipmentId: json['equipment_id'],
      equipmentName: json['equipment_name'],
      filledData: Map<String, dynamic>.from(json['filled_data'] ?? {}),
      status: json['status'] ?? 'draft',
      createdAt: DateTime.parse(json['created_at'] ?? DateTime.now().toIso8601String()),
      completedAt: json['completed_at'] != null
          ? DateTime.parse(json['completed_at'])
          : null,
      syncedToBackend: json['synced_to_backend'] ?? false,
      pdfPath: json['pdf_path'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'record_id': recordId,
      'template_id': templateId,
      if (equipmentId != null) 'equipment_id': equipmentId,
      if (equipmentName != null) 'equipment_name': equipmentName,
      'filled_data': filledData,
      'status': status,
      'created_at': createdAt.toIso8601String(),
      if (completedAt != null) 'completed_at': completedAt!.toIso8601String(),
      'synced_to_backend': syncedToBackend,
      if (pdfPath != null) 'pdf_path': pdfPath,
    };
  }

  TemplateFillingRecord copyWith({
    String? recordId,
    String? templateId,
    String? equipmentId,
    String? equipmentName,
    Map<String, dynamic>? filledData,
    String? status,
    DateTime? createdAt,
    DateTime? completedAt,
    bool? syncedToBackend,
    String? pdfPath,
  }) {
    return TemplateFillingRecord(
      recordId: recordId ?? this.recordId,
      templateId: templateId ?? this.templateId,
      equipmentId: equipmentId ?? this.equipmentId,
      equipmentName: equipmentName ?? this.equipmentName,
      filledData: filledData ?? this.filledData,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
      syncedToBackend: syncedToBackend ?? this.syncedToBackend,
      pdfPath: pdfPath ?? this.pdfPath,
    );
  }
}
