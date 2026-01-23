import 'dart:ui' show Offset;

/// 測量數據模型
class Measurement {
  // 參考線（已知尺寸的物體）
  final Offset? referenceStart;
  final Offset? referenceEnd;
  final double? referenceRealLength; // 真實長度（例如：85.6）
  final String? referenceUnit; // 單位（例如：mm）

  // 測量線（要測量的目標）
  final Offset? measureStart;
  final Offset? measureEnd;

  // 計算結果
  final double? calculatedLength;
  final String? unit;

  Measurement({
    this.referenceStart,
    this.referenceEnd,
    this.referenceRealLength,
    this.referenceUnit,
    this.measureStart,
    this.measureEnd,
    this.calculatedLength,
    this.unit,
  });

  /// 是否已設置參考線
  bool get hasReference =>
      referenceStart != null &&
      referenceEnd != null &&
      referenceRealLength != null &&
      referenceUnit != null;

  /// 是否已完成測量
  bool get isComplete =>
      hasReference && measureStart != null && measureEnd != null;

  /// 計算參考線的像素長度
  double? get referencePixelLength {
    if (referenceStart == null || referenceEnd == null) return null;
    final dx = referenceEnd!.dx - referenceStart!.dx;
    final dy = referenceEnd!.dy - referenceStart!.dy;
    return (dx * dx + dy * dy).sqrt();
  }

  /// 計算測量線的像素長度
  double? get measurePixelLength {
    if (measureStart == null || measureEnd == null) return null;
    final dx = measureEnd!.dx - measureStart!.dx;
    final dy = measureEnd!.dy - measureStart!.dy;
    return (dx * dx + dy * dy).sqrt();
  }

  /// 計算比例係數（真實長度 / 像素長度）
  double? get scaleFactor {
    if (referencePixelLength == null || referenceRealLength == null) {
      return null;
    }
    if (referencePixelLength! == 0) return null;
    return referenceRealLength! / referencePixelLength!;
  }

  /// 計算目標的真實長度
  double? calculateRealLength() {
    if (scaleFactor == null || measurePixelLength == null) return null;
    return measurePixelLength! * scaleFactor!;
  }

  /// 獲取格式化的測量結果字符串
  String? getFormattedResult() {
    final length = calculatedLength ?? calculateRealLength();
    if (length == null || unit == null) return null;
    return '${length.toStringAsFixed(2)} $unit';
  }

  /// 從 JSON 創建實例
  factory Measurement.fromJson(Map<String, dynamic> json) {
    return Measurement(
      referenceStart: json['referenceStart'] != null
          ? Offset(
              json['referenceStart']['dx'] as double,
              json['referenceStart']['dy'] as double,
            )
          : null,
      referenceEnd: json['referenceEnd'] != null
          ? Offset(
              json['referenceEnd']['dx'] as double,
              json['referenceEnd']['dy'] as double,
            )
          : null,
      referenceRealLength: json['referenceRealLength'] as double?,
      referenceUnit: json['referenceUnit'] as String?,
      measureStart: json['measureStart'] != null
          ? Offset(
              json['measureStart']['dx'] as double,
              json['measureStart']['dy'] as double,
            )
          : null,
      measureEnd: json['measureEnd'] != null
          ? Offset(
              json['measureEnd']['dx'] as double,
              json['measureEnd']['dy'] as double,
            )
          : null,
      calculatedLength: json['calculatedLength'] as double?,
      unit: json['unit'] as String?,
    );
  }

  /// 轉換為 JSON
  Map<String, dynamic> toJson() {
    return {
      'referenceStart': referenceStart != null
          ? {'dx': referenceStart!.dx, 'dy': referenceStart!.dy}
          : null,
      'referenceEnd': referenceEnd != null
          ? {'dx': referenceEnd!.dx, 'dy': referenceEnd!.dy}
          : null,
      'referenceRealLength': referenceRealLength,
      'referenceUnit': referenceUnit,
      'measureStart': measureStart != null
          ? {'dx': measureStart!.dx, 'dy': measureStart!.dy}
          : null,
      'measureEnd': measureEnd != null
          ? {'dx': measureEnd!.dx, 'dy': measureEnd!.dy}
          : null,
      'calculatedLength': calculatedLength,
      'unit': unit,
    };
  }

  /// 創建副本
  Measurement copyWith({
    Offset? referenceStart,
    Offset? referenceEnd,
    double? referenceRealLength,
    String? referenceUnit,
    Offset? measureStart,
    Offset? measureEnd,
    double? calculatedLength,
    String? unit,
  }) {
    return Measurement(
      referenceStart: referenceStart ?? this.referenceStart,
      referenceEnd: referenceEnd ?? this.referenceEnd,
      referenceRealLength: referenceRealLength ?? this.referenceRealLength,
      referenceUnit: referenceUnit ?? this.referenceUnit,
      measureStart: measureStart ?? this.measureStart,
      measureEnd: measureEnd ?? this.measureEnd,
      calculatedLength: calculatedLength ?? this.calculatedLength,
      unit: unit ?? this.unit,
    );
  }

  @override
  String toString() {
    return 'Measurement(reference: ${getFormattedResult()})';
  }
}
