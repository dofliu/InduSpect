/// 巡檢項目模型
/// 對應 React 版本的 InspectionItem 介面
class InspectionItem {
  final String id;
  final String description;
  String? photoPath; // 本地照片路徑
  String? photoBase64; // base64 編碼的照片（用於 API 上傳）
  bool isCompleted;

  InspectionItem({
    required this.id,
    required this.description,
    this.photoPath,
    this.photoBase64,
    this.isCompleted = false,
  });

  /// 從 JSON 創建實例
  factory InspectionItem.fromJson(Map<String, dynamic> json) {
    return InspectionItem(
      id: json['id'] as String,
      description: json['description'] as String,
      photoPath: json['photoPath'] as String?,
      photoBase64: json['photoBase64'] as String?,
      isCompleted: json['isCompleted'] as bool? ?? false,
    );
  }

  /// 轉換為 JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'description': description,
      'photoPath': photoPath,
      'photoBase64': photoBase64,
      'isCompleted': isCompleted,
    };
  }

  /// 創建副本（用於狀態更新）
  InspectionItem copyWith({
    String? id,
    String? description,
    String? photoPath,
    String? photoBase64,
    bool? isCompleted,
  }) {
    return InspectionItem(
      id: id ?? this.id,
      description: description ?? this.description,
      photoPath: photoPath ?? this.photoPath,
      photoBase64: photoBase64 ?? this.photoBase64,
      isCompleted: isCompleted ?? this.isCompleted,
    );
  }

  @override
  String toString() {
    return 'InspectionItem(id: $id, description: $description, isCompleted: $isCompleted)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is InspectionItem &&
        other.id == id &&
        other.description == description &&
        other.photoPath == photoPath &&
        other.isCompleted == isCompleted;
  }

  @override
  int get hashCode {
    return Object.hash(id, description, photoPath, isCompleted);
  }
}
