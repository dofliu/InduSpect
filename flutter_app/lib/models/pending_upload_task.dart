class PendingUploadTask {
  final String id;
  final String jobId;
  final String pointId;
  final String itemDescription;
  final String photoPath;
  final int retryCount;
  final String? lastError;
  final DateTime createdAt;
  final DateTime? lastTriedAt;

  PendingUploadTask({
    required this.id,
    required this.jobId,
    required this.pointId,
    required this.itemDescription,
    required this.photoPath,
    this.retryCount = 0,
    this.lastError,
    required this.createdAt,
    this.lastTriedAt,
  });

  PendingUploadTask copyWith({
    String? id,
    String? jobId,
    String? pointId,
    String? itemDescription,
    String? photoPath,
    int? retryCount,
    String? lastError,
    DateTime? createdAt,
    DateTime? lastTriedAt,
  }) {
    return PendingUploadTask(
      id: id ?? this.id,
      jobId: jobId ?? this.jobId,
      pointId: pointId ?? this.pointId,
      itemDescription: itemDescription ?? this.itemDescription,
      photoPath: photoPath ?? this.photoPath,
      retryCount: retryCount ?? this.retryCount,
      lastError: lastError ?? this.lastError,
      createdAt: createdAt ?? this.createdAt,
      lastTriedAt: lastTriedAt ?? this.lastTriedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'jobId': jobId,
      'pointId': pointId,
      'itemDescription': itemDescription,
      'photoPath': photoPath,
      'retryCount': retryCount,
      'lastError': lastError,
      'createdAt': createdAt.toIso8601String(),
      'lastTriedAt': lastTriedAt?.toIso8601String(),
    };
  }

  factory PendingUploadTask.fromJson(Map<String, dynamic> json) {
    return PendingUploadTask(
      id: json['id'] as String,
      jobId: json['jobId'] as String,
      pointId: json['pointId'] as String,
      itemDescription: json['itemDescription'] as String? ?? '',
      photoPath: json['photoPath'] as String,
      retryCount: json['retryCount'] as int? ?? 0,
      lastError: json['lastError'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastTriedAt: json['lastTriedAt'] != null
          ? DateTime.tryParse(json['lastTriedAt'] as String)
          : null,
    );
  }
}
