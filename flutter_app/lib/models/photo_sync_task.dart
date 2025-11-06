enum SyncStatus {
  pending,
  syncing,
  completed,
  failed,
}

class PhotoSyncTask {
  final String? id;
  final String taskId;
  final String recordId;
  final String fieldId;
  final String photoPath;
  final SyncStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? errorMessage;
  final Map<String, dynamic>? aiResult;

  PhotoSyncTask({
    this.id,
    required this.taskId,
    required this.recordId,
    required this.fieldId,
    required this.photoPath,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.errorMessage,
    this.aiResult,
  });

  factory PhotoSyncTask.fromMap(Map<String, dynamic> map) {
    return PhotoSyncTask(
      id: map['id']?.toString(),
      taskId: map['task_id'] as String,
      recordId: map['record_id'] as String,
      fieldId: map['field_id'] as String,
      photoPath: map['photo_path'] as String,
      status: SyncStatus.values.firstWhere(
        (e) => e.toString() == 'SyncStatus.${map['status']}',
        orElse: () => SyncStatus.pending,
      ),
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
      errorMessage: map['error_message'] as String?,
      aiResult: map['ai_result'] != null 
          ? Map<String, dynamic>.from(map['ai_result'] as Map)
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'task_id': taskId,
      'record_id': recordId,
      'field_id': fieldId,
      'photo_path': photoPath,
      'status': status.toString().split('.').last,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'error_message': errorMessage,
      'ai_result': aiResult != null ? aiResult.toString() : null,
    };
  }

  PhotoSyncTask copyWith({
    String? id,
    String? taskId,
    String? recordId,
    String? fieldId,
    String? photoPath,
    SyncStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? errorMessage,
    Map<String, dynamic>? aiResult,
  }) {
    return PhotoSyncTask(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      recordId: recordId ?? this.recordId,
      fieldId: fieldId ?? this.fieldId,
      photoPath: photoPath ?? this.photoPath,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      errorMessage: errorMessage ?? this.errorMessage,
      aiResult: aiResult ?? this.aiResult,
    );
  }

  bool get isPending => status == SyncStatus.pending;
  bool get isSyncing => status == SyncStatus.syncing;
  bool get isCompleted => status == SyncStatus.completed;
  bool get isFailed => status == SyncStatus.failed;

  @override
  String toString() {
    return 'PhotoSyncTask(id: $id, taskId: $taskId, recordId: $recordId, status: $status)';
  }
}
