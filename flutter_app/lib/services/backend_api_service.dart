import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/rag_models.dart';
import 'connectivity_service.dart';

/// 後端 API 服務
/// 負責與 FastAPI 後端通訊
class BackendApiService {
  static BackendApiService? _instance;
  late final Dio _dio;
  late final String _baseUrl;
  final ConnectivityService _connectivity = ConnectivityService();
  
  // 離線佇列 key
  static const String _pendingItemsKey = 'pending_rag_items';

  BackendApiService._internal() {
    _baseUrl = dotenv.env['BACKEND_API_URL'] ?? 'http://localhost:8000';
    _dio = Dio(BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    ));
    
    // 添加請求攔截器 (日誌)
    _dio.interceptors.add(LogInterceptor(
      requestBody: true,
      responseBody: true,
      error: true,
    ));
  }

  factory BackendApiService() {
    _instance ??= BackendApiService._internal();
    return _instance!;
  }

  /// 查詢相似案例
  Future<RagQueryResponse> querySimilarCases({
    required String equipmentType,
    required String anomalyDescription,
    String? conditionAssessment,
    int topK = 5,
  }) async {
    print('🔍 [Frontend] RAG Query: $equipmentType - $anomalyDescription');

    // 檢查網路連線
    if (!await _connectivity.checkConnection()) {
      print('⚠️ [Frontend] Offline mode, skipping RAG query');
      return RagQueryResponse(
        results: [],
        suggestions: ['目前離線中，無法查詢相似案例'],
        error: 'offline',
      );
    }

    try {
      final response = await _dio.post('/api/rag/query', data: {
        'equipment_type': equipmentType,
        'anomaly_description': anomalyDescription,
        'condition_assessment': conditionAssessment,
        'top_k': topK,
      });

      print('✅ [Frontend] RAG Response: ${response.data}');
      return RagQueryResponse.fromJson(response.data);
    } on DioException catch (e) {
      print('❌ [Frontend] RAG Request Failed: ${e.message}');
      if (e.response != null) {
        print('❌ [Frontend] Error Data: ${e.response?.data}');
      }
      return RagQueryResponse(
        results: [],
        suggestions: ['查詢失敗: ${e.message}'],
        error: e.message,
      );
    }
  }

  /// 新增項目到知識庫
  Future<bool> addToKnowledgeBase({
    required String content,
    required String equipmentType,
    required String sourceType,
    String? sourceId,
    Map<String, dynamic>? metadata,
  }) async {
    // 檢查網路連線
    if (!await _connectivity.checkConnection()) {
      // 離線：加入待處理佇列
      await _addToPendingQueue(PendingRagItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        content: content,
        equipmentType: equipmentType,
        sourceType: sourceType,
        sourceId: sourceId,
        metadata: metadata,
        createdAt: DateTime.now(),
      ));
      return true; // 返回 true 表示已加入佇列
    }

    try {
      final response = await _dio.post('/api/rag/add', data: {
        'content': content,
        'equipment_type': equipmentType,
        'source_type': sourceType,
        'source_id': sourceId,
        'metadata': metadata,
      });

      return response.data['success'] == true;
    } on DioException {
      // 失敗時也加入佇列
      await _addToPendingQueue(PendingRagItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        content: content,
        equipmentType: equipmentType,
        sourceType: sourceType,
        sourceId: sourceId,
        metadata: metadata,
        createdAt: DateTime.now(),
      ));
      return true;
    }
  }

  /// 取得知識庫統計
  Future<Map<String, dynamic>?> getKnowledgeBaseStats() async {
    if (!await _connectivity.checkConnection()) return null;

    try {
      final response = await _dio.get('/api/rag/stats');
      return response.data;
    } catch (e) {
      return null;
    }
  }

  // ============ 離線佇列管理 ============

  /// 加入待處理佇列
  Future<void> _addToPendingQueue(PendingRagItem item) async {
    final prefs = await SharedPreferences.getInstance();
    final items = await getPendingItems();
    items.add(item);
    await prefs.setString(_pendingItemsKey, jsonEncode(
      items.map((e) => e.toJson()).toList(),
    ));
  }

  /// 取得待處理項目
  Future<List<PendingRagItem>> getPendingItems() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_pendingItemsKey);
    if (jsonStr == null) return [];

    final List<dynamic> jsonList = jsonDecode(jsonStr);
    return jsonList.map((e) => PendingRagItem.fromJson(e)).toList();
  }

  /// 取得待處理項目數量
  Future<int> getPendingCount() async {
    final items = await getPendingItems();
    return items.where((e) => e.status == PendingRagItemStatus.pending).length;
  }

  /// 同步所有待處理項目
  Future<int> syncPendingItems() async {
    if (!await _connectivity.checkConnection()) return 0;

    final items = await getPendingItems();
    int syncedCount = 0;

    for (final item in items) {
      if (item.status != PendingRagItemStatus.pending) continue;

      try {
        item.status = PendingRagItemStatus.processing;
        
        final response = await _dio.post('/api/rag/add', data: {
          'content': item.content,
          'equipment_type': item.equipmentType,
          'source_type': item.sourceType,
          'source_id': item.sourceId,
          'metadata': item.metadata,
        });

        if (response.data['success'] == true) {
          item.status = PendingRagItemStatus.completed;
          syncedCount++;
        } else {
          item.status = PendingRagItemStatus.failed;
        }
      } catch (e) {
        item.status = PendingRagItemStatus.failed;
      }
    }

    // 更新佇列狀態
    final prefs = await SharedPreferences.getInstance();
    // 只保留未完成的項目
    final remaining = items.where(
      (e) => e.status != PendingRagItemStatus.completed,
    ).toList();
    await prefs.setString(_pendingItemsKey, jsonEncode(
      remaining.map((e) => e.toJson()).toList(),
    ));

    return syncedCount;
  }

  /// 清空已完成的項目
  Future<void> clearCompletedItems() async {
    final prefs = await SharedPreferences.getInstance();
    final items = await getPendingItems();
    final remaining = items.where(
      (e) => e.status != PendingRagItemStatus.completed,
    ).toList();
    await prefs.setString(_pendingItemsKey, jsonEncode(
      remaining.map((e) => e.toJson()).toList(),
    ));
  }

  /// 健康檢查
  Future<bool> healthCheck() async {
    try {
      final response = await _dio.get('/health');
      return response.data['status'] == 'ok';
    } catch (e) {
      return false;
    }
  }
}
