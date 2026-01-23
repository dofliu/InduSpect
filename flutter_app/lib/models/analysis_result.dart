import '../utils/constants.dart';

/// AI 分析結果模型
/// 對應 React 版本的 AnalysisResult 介面
class AnalysisResult {
  final String itemId;
  final String? photoPath;
  String? equipmentType;
  Map<String, dynamic>? readings; // 儀表讀數
  String? conditionAssessment;
  bool? isAnomaly;
  String? anomalyDescription;
  String? measuredSize; // 測量尺寸（格式："{數值} {單位}"）
  String? aiEstimatedSize; // AI 估算尺寸
  String? analysisError;
  AnalysisStatus status;

  AnalysisResult({
    required this.itemId,
    this.photoPath,
    this.equipmentType,
    this.readings,
    this.conditionAssessment,
    this.isAnomaly,
    this.anomalyDescription,
    this.measuredSize,
    this.aiEstimatedSize,
    this.analysisError,
    this.status = AnalysisStatus.pending,
  });

  /// 從 Gemini API 的 JSON 響應創建實例
  factory AnalysisResult.fromGeminiJson(
    String itemId,
    String photoPath,
    Map<String, dynamic> json,
  ) {
    return AnalysisResult(
      itemId: itemId,
      photoPath: photoPath,
      equipmentType: json['equipment_type'] as String?,
      readings: json['readings'] as Map<String, dynamic>?,
      conditionAssessment: json['condition_assessment'] as String?,
      isAnomaly: json['is_anomaly'] as bool?,
      anomalyDescription: json['anomaly_description'] as String?,
      aiEstimatedSize: json['estimated_size'] as String?,
      status: AnalysisStatus.completed,
    );
  }

  /// 從本地存儲的 JSON 創建實例
  factory AnalysisResult.fromJson(Map<String, dynamic> json) {
    return AnalysisResult(
      itemId: json['itemId'] as String,
      photoPath: json['photoPath'] as String?,
      equipmentType: json['equipmentType'] as String?,
      readings: json['readings'] as Map<String, dynamic>?,
      conditionAssessment: json['conditionAssessment'] as String?,
      isAnomaly: json['isAnomaly'] as bool?,
      anomalyDescription: json['anomalyDescription'] as String?,
      measuredSize: json['measuredSize'] as String?,
      aiEstimatedSize: json['aiEstimatedSize'] as String?,
      analysisError: json['analysisError'] as String?,
      status: AnalysisStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => AnalysisStatus.pending,
      ),
    );
  }

  /// 轉換為 JSON
  Map<String, dynamic> toJson() {
    return {
      'itemId': itemId,
      'photoPath': photoPath,
      'equipmentType': equipmentType,
      'readings': readings,
      'conditionAssessment': conditionAssessment,
      'isAnomaly': isAnomaly,
      'anomalyDescription': anomalyDescription,
      'measuredSize': measuredSize,
      'aiEstimatedSize': aiEstimatedSize,
      'analysisError': analysisError,
      'status': status.name,
    };
  }

  /// 創建副本
  AnalysisResult copyWith({
    String? itemId,
    String? photoPath,
    String? equipmentType,
    Map<String, dynamic>? readings,
    String? conditionAssessment,
    bool? isAnomaly,
    String? anomalyDescription,
    String? measuredSize,
    String? aiEstimatedSize,
    String? analysisError,
    AnalysisStatus? status,
  }) {
    return AnalysisResult(
      itemId: itemId ?? this.itemId,
      photoPath: photoPath ?? this.photoPath,
      equipmentType: equipmentType ?? this.equipmentType,
      readings: readings ?? this.readings,
      conditionAssessment: conditionAssessment ?? this.conditionAssessment,
      isAnomaly: isAnomaly ?? this.isAnomaly,
      anomalyDescription: anomalyDescription ?? this.anomalyDescription,
      measuredSize: measuredSize ?? this.measuredSize,
      aiEstimatedSize: aiEstimatedSize ?? this.aiEstimatedSize,
      analysisError: analysisError ?? this.analysisError,
      status: status ?? this.status,
    );
  }

  /// 獲取設備狀況枚舉
  EquipmentCondition get conditionEnum {
    if (isAnomaly == true) {
      return EquipmentCondition.abnormal;
    } else if (conditionAssessment != null &&
        conditionAssessment!.contains('正常')) {
      return EquipmentCondition.normal;
    } else if (conditionAssessment != null) {
      return EquipmentCondition.warning;
    }
    return EquipmentCondition.unknown;
  }

  @override
  String toString() {
    return 'AnalysisResult(itemId: $itemId, equipmentType: $equipmentType, status: $status)';
  }
}
