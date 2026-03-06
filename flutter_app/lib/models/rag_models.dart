/// RAG 查詢結果模型
class RagResult {
  final String id;
  final double similarity;
  final String equipmentType;
  final String content;
  final String sourceType;
  final Map<String, dynamic>? metadata;

  RagResult({
    required this.id,
    required this.similarity,
    required this.equipmentType,
    required this.content,
    required this.sourceType,
    this.metadata,
  });

  factory RagResult.fromJson(Map<String, dynamic> json) {
    return RagResult(
      id: json['id'] ?? '',
      similarity: (json['similarity'] ?? 0).toDouble(),
      equipmentType: json['equipment_type'] ?? '',
      content: json['content'] ?? '',
      sourceType: json['source_type'] ?? '',
      metadata: json['metadata'],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'similarity': similarity,
    'equipment_type': equipmentType,
    'content': content,
    'source_type': sourceType,
    'metadata': metadata,
  };
}

/// RAG 查詢回應
class RagQueryResponse {
  final List<RagResult> results;
  final List<String> suggestions;
  final String? error;

  RagQueryResponse({
    required this.results,
    required this.suggestions,
    this.error,
  });

  factory RagQueryResponse.fromJson(Map<String, dynamic> json) {
    return RagQueryResponse(
      results: (json['results'] as List?)
          ?.map((e) => RagResult.fromJson(e))
          .toList() ?? [],
      suggestions: (json['suggestions'] as List?)
          ?.map((e) => e.toString())
          .toList() ?? [],
      error: json['error'],
    );
  }

  bool get hasResults => results.isNotEmpty;
  bool get hasSuggestions => suggestions.isNotEmpty;
}

/// 待處理的 RAG 項目 (離線佇列)
class PendingRagItem {
  final String id;
  final String content;
  final String equipmentType;
  final String sourceType;
  final String? sourceId;
  final Map<String, dynamic>? metadata;
  final DateTime createdAt;
  PendingRagItemStatus status;

  PendingRagItem({
    required this.id,
    required this.content,
    required this.equipmentType,
    required this.sourceType,
    this.sourceId,
    this.metadata,
    required this.createdAt,
    this.status = PendingRagItemStatus.pending,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'equipment_type': equipmentType,
    'source_type': sourceType,
    'source_id': sourceId,
    'metadata': metadata,
    'created_at': createdAt.toIso8601String(),
    'status': status.name,
  };

  factory PendingRagItem.fromJson(Map<String, dynamic> json) {
    return PendingRagItem(
      id: json['id'],
      content: json['content'],
      equipmentType: json['equipment_type'],
      sourceType: json['source_type'],
      sourceId: json['source_id'],
      metadata: json['metadata'],
      createdAt: DateTime.parse(json['created_at']),
      status: PendingRagItemStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => PendingRagItemStatus.pending,
      ),
    );
  }
}

enum PendingRagItemStatus {
  pending,
  processing,
  completed,
  failed,
}
