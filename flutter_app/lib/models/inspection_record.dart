import 'analysis_result.dart';

/// 巡檢記錄模型（已確認的記錄）
/// 對應 React 版本的 ConfirmedRecord 介面
class InspectionRecord {
  final String id;
  final String itemDescription;
  final String? photoPath;
  final String equipmentType;
  final Map<String, dynamic>? readings;
  final String conditionAssessment;
  final bool isAnomaly;
  final String? anomalyDescription;
  final String? measuredSize;
  final DateTime timestamp;

  InspectionRecord({
    required this.id,
    required this.itemDescription,
    this.photoPath,
    required this.equipmentType,
    this.readings,
    required this.conditionAssessment,
    required this.isAnomaly,
    this.anomalyDescription,
    this.measuredSize,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// 從分析結果創建記錄
  factory InspectionRecord.fromAnalysisResult(
    AnalysisResult result,
    String itemDescription,
  ) {
    return InspectionRecord(
      id: result.itemId,
      itemDescription: itemDescription,
      photoPath: result.photoPath,
      equipmentType: result.equipmentType ?? '未知',
      readings: result.readings,
      conditionAssessment: result.conditionAssessment ?? '未評估',
      isAnomaly: result.isAnomaly ?? false,
      anomalyDescription: result.anomalyDescription,
      measuredSize: result.measuredSize ?? result.aiEstimatedSize,
    );
  }

  /// 從 JSON 創建實例
  factory InspectionRecord.fromJson(Map<String, dynamic> json) {
    return InspectionRecord(
      id: json['id'] as String,
      itemDescription: json['itemDescription'] as String,
      photoPath: json['photoPath'] as String?,
      equipmentType: json['equipmentType'] as String,
      readings: json['readings'] as Map<String, dynamic>?,
      conditionAssessment: json['conditionAssessment'] as String,
      isAnomaly: json['isAnomaly'] as bool,
      anomalyDescription: json['anomalyDescription'] as String?,
      measuredSize: json['measuredSize'] as String?,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : DateTime.now(),
    );
  }

  /// 轉換為 JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'itemDescription': itemDescription,
      'photoPath': photoPath,
      'equipmentType': equipmentType,
      'readings': readings,
      'conditionAssessment': conditionAssessment,
      'isAnomaly': isAnomaly,
      'anomalyDescription': anomalyDescription,
      'measuredSize': measuredSize,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  /// 轉換為用於報告生成的格式
  Map<String, dynamic> toReportFormat() {
    final Map<String, dynamic> report = {
      '檢查項目': itemDescription,
      '設備類型': equipmentType,
      '狀況評估': conditionAssessment,
      '是否異常': isAnomaly ? '是' : '否',
    };

    if (readings != null && readings!.isNotEmpty) {
      report['儀表讀數'] = readings;
    }

    if (isAnomaly && anomalyDescription != null) {
      report['異常描述'] = anomalyDescription;
    }

    if (measuredSize != null) {
      report['測量尺寸'] = measuredSize;
    }

    return report;
  }

  /// 創建副本
  InspectionRecord copyWith({
    String? id,
    String? itemDescription,
    String? photoPath,
    String? equipmentType,
    Map<String, dynamic>? readings,
    String? conditionAssessment,
    bool? isAnomaly,
    String? anomalyDescription,
    String? measuredSize,
    DateTime? timestamp,
  }) {
    return InspectionRecord(
      id: id ?? this.id,
      itemDescription: itemDescription ?? this.itemDescription,
      photoPath: photoPath ?? this.photoPath,
      equipmentType: equipmentType ?? this.equipmentType,
      readings: readings ?? this.readings,
      conditionAssessment: conditionAssessment ?? this.conditionAssessment,
      isAnomaly: isAnomaly ?? this.isAnomaly,
      anomalyDescription: anomalyDescription ?? this.anomalyDescription,
      measuredSize: measuredSize ?? this.measuredSize,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  @override
  String toString() {
    return 'InspectionRecord(id: $id, description: $itemDescription, isAnomaly: $isAnomaly)';
  }
}
