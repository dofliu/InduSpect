import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
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

  /// 取得所有知識庫項目
  Future<List<Map<String, dynamic>>> getAllItems({int skip = 0, int limit = 100}) async {
    if (!await _connectivity.checkConnection()) return [];

    try {
      final response = await _dio.get(
        '/api/rag/items',
        queryParameters: {'skip': skip, 'limit': limit},
      );
      
      if (response.data is List) {
        return List<Map<String, dynamic>>.from(response.data);
      }
      return [];
    } catch (e) {
      print('Error getting items: $e');
      return [];
    }
  }

  /// 刪除知識庫項目
  Future<bool> deleteItem(String itemId) async {
    if (!await _connectivity.checkConnection()) return false;

    try {
      final response = await _dio.delete('/api/rag/items/$itemId');
      return response.data['success'] == true;
    } catch (e) {
      print('Error deleting item: $e');
      return false;
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



  /// 上傳維修手冊
  Future<Map<String, dynamic>> uploadDocument(PlatformFile file) async {
    if (!await _connectivity.checkConnection()) {
      return {'success': false, 'error': 'offline'};
    }

    try {
      MultipartFile multipartFile;
      
      // 根據平台選擇讀取方式
      if (file.path != null) {
        // Mobile / Desktop
        multipartFile = await MultipartFile.fromFile(file.path!, filename: file.name);
      } else if (file.bytes != null) {
        // Web
        multipartFile = MultipartFile.fromBytes(file.bytes!, filename: file.name);
      } else {
        return {'success': false, 'error': '無法讀取檔案內容'};
      }

      final formData = FormData.fromMap({
        'file': multipartFile,
      });

      print('📄 Uploading file: ${file.name}');

      final response = await _dio.post(
        '/api/rag/upload',
        data: formData,
        onSendProgress: (count, total) {
          // 可以通知進度，但這裡先簡單 log
          if (total > 0) {
            print('Upload progress: ${(count / total * 100).toStringAsFixed(0)}%');
          }
        },
      );

      return response.data;
    } catch (e) {
      print('❌ Upload error: $e');
      if (e is DioException) {
         return {'success': false, 'error': e.message};
      }
      return {'success': false, 'error': e.toString()};
    }
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

  // ============ 動態模板建立 API ============

  /// 從真實廠商表單自動建立檢測模板
  ///
  /// 上傳 Excel/Word 定檢表格，AI 自動分析結構並產生
  /// InspectionTemplate JSON，可直接用於 App 端引導式填寫。
  Future<Map<String, dynamic>> createTemplateFromFile({
    required PlatformFile file,
    required String templateName,
    String category = '一般設備',
    String company = '',
    String department = '',
  }) async {
    if (!await _connectivity.checkConnection()) {
      return {'success': false, 'error': '目前離線中，無法建立模板'};
    }

    try {
      MultipartFile multipartFile;
      if (file.path != null) {
        multipartFile = await MultipartFile.fromFile(file.path!, filename: file.name);
      } else if (file.bytes != null) {
        multipartFile = MultipartFile.fromBytes(file.bytes!, filename: file.name);
      } else {
        return {'success': false, 'error': '無法讀取檔案內容'};
      }

      final formData = FormData.fromMap({
        'file': multipartFile,
        'template_name': templateName,
        'category': category,
        'company': company,
        'department': department,
      });

      print('📋 Creating template from file: ${file.name}');

      final response = await _dio.post(
        '/api/templates/create-from-file',
        data: formData,
        options: Options(
          receiveTimeout: const Duration(seconds: 60), // AI 分析需要較長時間
        ),
      );

      print('✅ Template created: ${response.data}');
      return Map<String, dynamic>.from(response.data);
    } on DioException catch (e) {
      print('❌ Create template error: ${e.message}');
      if (e.response != null) {
        final detail = e.response?.data?['detail'] ?? e.message;
        return {'success': false, 'error': detail};
      }
      return {'success': false, 'error': e.message};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ============ 自動回填 API ============

  /// 分析定檢文件結構（Excel/Word）
  /// 回傳 Field Position Map
  Future<Map<String, dynamic>> analyzeFileStructure(PlatformFile file) async {
    if (!await _connectivity.checkConnection()) {
      return {'success': false, 'error': 'offline'};
    }

    try {
      MultipartFile multipartFile;
      if (file.path != null) {
        multipartFile = await MultipartFile.fromFile(file.path!, filename: file.name);
      } else if (file.bytes != null) {
        multipartFile = MultipartFile.fromBytes(file.bytes!, filename: file.name);
      } else {
        return {'success': false, 'error': '無法讀取檔案內容'};
      }

      final formData = FormData.fromMap({'file': multipartFile});

      final response = await _dio.post(
        '/api/auto-fill/analyze-structure',
        data: formData,
      );

      return Map<String, dynamic>.from(response.data);
    } catch (e) {
      if (e is DioException) {
        return {'success': false, 'error': e.message};
      }
      return {'success': false, 'error': e.toString()};
    }
  }

  /// AI 自動映射檢查結果到表格欄位
  Future<Map<String, dynamic>> mapFieldsWithAI({
    required List<Map<String, dynamic>> fieldMap,
    required List<Map<String, dynamic>> inspectionResults,
  }) async {
    if (!await _connectivity.checkConnection()) {
      return {'success': false, 'error': 'offline'};
    }

    try {
      final response = await _dio.post('/api/auto-fill/map-fields', data: {
        'field_map': fieldMap,
        'inspection_results': inspectionResults,
      });

      return Map<String, dynamic>.from(response.data);
    } catch (e) {
      if (e is DioException) {
        return {'success': false, 'error': e.message};
      }
      return {'success': false, 'error': e.toString()};
    }
  }

  /// 預覽自動回填結果
  Future<Map<String, dynamic>> previewAutoFill({
    required List<Map<String, dynamic>> fieldMap,
    required List<Map<String, dynamic>> fillValues,
  }) async {
    if (!await _connectivity.checkConnection()) {
      return {'success': false, 'error': 'offline'};
    }

    try {
      final response = await _dio.post('/api/auto-fill/preview', data: {
        'field_map': fieldMap,
        'fill_values': fillValues,
      });

      return Map<String, dynamic>.from(response.data);
    } catch (e) {
      if (e is DioException) {
        return {'success': false, 'error': e.message};
      }
      return {'success': false, 'error': e.toString()};
    }
  }

  /// 執行自動回填，回傳填好的文件 bytes
  Future<List<int>?> executeAutoFill({
    required PlatformFile file,
    required List<Map<String, dynamic>> fieldMap,
    required List<Map<String, dynamic>> fillValues,
  }) async {
    if (!await _connectivity.checkConnection()) return null;

    try {
      MultipartFile multipartFile;
      if (file.path != null) {
        multipartFile = await MultipartFile.fromFile(file.path!, filename: file.name);
      } else if (file.bytes != null) {
        multipartFile = MultipartFile.fromBytes(file.bytes!, filename: file.name);
      } else {
        return null;
      }

      final formData = FormData.fromMap({
        'file': multipartFile,
        'field_map_json': jsonEncode(fieldMap),
        'fill_values_json': jsonEncode(fillValues),
      });

      final response = await _dio.post(
        '/api/auto-fill/execute',
        data: formData,
        options: Options(responseType: ResponseType.bytes),
      );

      return response.data;
    } catch (e) {
      print('Auto-fill execute error: $e');
      return null;
    }
  }

  /// 標準判定：將 AI 辨識到的數值讀數送後端依法規標準自動判定合格/不合格
  ///
  /// 用於「一鍵自動檢測」批次分析後，對量測類欄位進行標準化判定。
  /// 後端會在判定前自動換算單位（例：500 kΩ → 0.5 MΩ）以避免誤判。
  /// 離線時回傳 success=false / error=offline，呼叫端應降級為「待判定」。
  ///
  /// [readings] 每筆格式：{'field_name': '絕緣電阻 R相', 'value': 52.3, 'unit': 'MΩ'}
  Future<Map<String, dynamic>> judgeReadings({
    required List<Map<String, dynamic>> readings,
    String equipmentType = '',
  }) async {
    if (!await _connectivity.checkConnection()) {
      return {'success': false, 'error': 'offline'};
    }

    try {
      final response = await _dio.post('/api/auto-fill/judge-readings', data: {
        'readings': readings,
        'equipment_type': equipmentType,
      });

      return Map<String, dynamic>.from(response.data);
    } catch (e) {
      if (e is DioException) {
        return {'success': false, 'error': e.message};
      }
      return {'success': false, 'error': e.toString()};
    }
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
