import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/inspection_item.dart';
import '../models/inspection_record.dart';
import '../models/analysis_result.dart';
import '../models/auth_tokens.dart';
import '../models/inspection_job.dart';
import '../models/pending_upload_task.dart';
import '../utils/constants.dart';

/// 本地存儲服務
/// 使用 shared_preferences 替代 Web 版本的 localStorage
class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  SharedPreferences? _prefs;

  /// 初始化存儲服務
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  SharedPreferences get prefs {
    if (_prefs == null) {
      throw Exception('StorageService not initialized. Call init() first.');
    }
    return _prefs!;
  }

  // ========== 巡檢項目相關 ==========

  /// 保存巡檢項目列表
  Future<bool> saveInspectionItems(List<InspectionItem> items) async {
    final jsonList = items.map((item) => item.toJson()).toList();
    return await prefs.setString(
      AppConstants.keyInspectionItems,
      jsonEncode(jsonList),
    );
  }

  /// 獲取巡檢項目列表
  List<InspectionItem> getInspectionItems() {
    final jsonStr = prefs.getString(AppConstants.keyInspectionItems);
    if (jsonStr == null || jsonStr.isEmpty) return [];

    try {
      final List<dynamic> jsonList = jsonDecode(jsonStr);
      return jsonList
          .map((json) => InspectionItem.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('Error parsing inspection items: $e');
      return [];
    }
  }

  /// 清除巡檢項目列表
  Future<bool> clearInspectionItems() async {
    return await prefs.remove(AppConstants.keyInspectionItems);
  }

  // ========== 巡檢記錄相關 ==========

  /// 保存巡檢記錄列表
  Future<bool> saveInspectionRecords(List<InspectionRecord> records) async {
    final jsonList = records.map((record) => record.toJson()).toList();
    return await prefs.setString(
      AppConstants.keyInspectionRecords,
      jsonEncode(jsonList),
    );
  }

  /// 獲取巡檢記錄列表
  List<InspectionRecord> getInspectionRecords() {
    final jsonStr = prefs.getString(AppConstants.keyInspectionRecords);
    if (jsonStr == null || jsonStr.isEmpty) return [];

    try {
      final List<dynamic> jsonList = jsonDecode(jsonStr);
      return jsonList
          .map((json) =>
              InspectionRecord.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('Error parsing inspection records: $e');
      return [];
    }
  }

  /// 添加單個巡檢記錄
  Future<bool> addInspectionRecord(InspectionRecord record) async {
    final records = getInspectionRecords();
    records.add(record);
    return await saveInspectionRecords(records);
  }

  /// 清除巡檢記錄列表
  Future<bool> clearInspectionRecords() async {
    return await prefs.remove(AppConstants.keyInspectionRecords);
  }

  // ========== 分析結果相關 ==========

  /// 保存分析結果（使用單獨的 key 以便區分狀態）
  Future<bool> saveAnalysisResults(Map<String, AnalysisResult> results) async {
    final jsonMap = results.map(
      (key, value) => MapEntry(key, value.toJson()),
    );
    return await prefs.setString(
      'analysis_results',
      jsonEncode(jsonMap),
    );
  }

  /// 獲取分析結果
  Map<String, AnalysisResult> getAnalysisResults() {
    final jsonStr = prefs.getString('analysis_results');
    if (jsonStr == null || jsonStr.isEmpty) return {};

    try {
      final Map<String, dynamic> jsonMap = jsonDecode(jsonStr);
      return jsonMap.map(
        (key, value) => MapEntry(
          key,
          AnalysisResult.fromJson(value as Map<String, dynamic>),
        ),
      );
    } catch (e) {
      print('Error parsing analysis results: $e');
      return {};
    }
  }

  /// 清除分析結果
  Future<bool> clearAnalysisResults() async {
    return await prefs.remove('analysis_results');
  }

  // ========== 當前步驟相關 ==========

  /// 保存當前步驟
  Future<bool> saveCurrentStep(int step) async {
    return await prefs.setInt(AppConstants.keyCurrentStep, step);
  }

  /// 獲取當前步驟
  int getCurrentStep() {
    return prefs.getInt(AppConstants.keyCurrentStep) ?? 1;
  }

  // ========== 應用狀態相關 ==========

  /// 保存應用狀態
  Future<bool> saveAppState(Map<String, dynamic> state) async {
    return await prefs.setString(
      AppConstants.keyAppState,
      jsonEncode(state),
    );
  }

  /// 獲取應用狀態
  Map<String, dynamic> getAppState() {
    final jsonStr = prefs.getString(AppConstants.keyAppState);
    if (jsonStr == null || jsonStr.isEmpty) return {};

    try {
      return jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (e) {
      print('Error parsing app state: $e');
      return {};
    }
  }

  // ========== 認證與任務相關 ==========

  Future<void> saveAuthTokens(AuthTokens tokens) async {
    await prefs.setString(
      AppConstants.keyAuthTokens,
      jsonEncode(tokens.toJson()),
    );
  }

  AuthTokens? getAuthTokens() {
    final jsonStr = prefs.getString(AppConstants.keyAuthTokens);
    if (jsonStr == null) return null;
    try {
      return AuthTokens.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
    } catch (e) {
      print('Error parsing auth tokens: $e');
      return null;
    }
  }

  Future<void> clearAuthTokens() async {
    await prefs.remove(AppConstants.keyAuthTokens);
  }

  Future<void> saveAssignedJobs(List<InspectionJob> jobs) async {
    final jsonList = jobs.map((job) => job.toJson()).toList();
    await prefs.setString(
      AppConstants.keyAssignedJobs,
      jsonEncode(jsonList),
    );
  }

  List<InspectionJob> getAssignedJobs() {
    final jsonStr = prefs.getString(AppConstants.keyAssignedJobs);
    if (jsonStr == null || jsonStr.isEmpty) return [];
    try {
      final List<dynamic> jsonList = jsonDecode(jsonStr);
      return jsonList
          .map((json) => InspectionJob.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('Error parsing assigned jobs: $e');
      return [];
    }
  }

  Future<void> saveSelectedJobId(String? jobId) async {
    if (jobId == null) {
      await prefs.remove(AppConstants.keySelectedJobId);
    } else {
      await prefs.setString(AppConstants.keySelectedJobId, jobId);
    }
  }

  String? getSelectedJobId() {
    return prefs.getString(AppConstants.keySelectedJobId);
  }

  Future<void> savePendingUploadTasks(List<PendingUploadTask> tasks) async {
    final jsonList = tasks.map((task) => task.toJson()).toList();
    await prefs.setString(
      AppConstants.keyPendingUploads,
      jsonEncode(jsonList),
    );
  }

  List<PendingUploadTask> getPendingUploadTasks() {
    final jsonStr = prefs.getString(AppConstants.keyPendingUploads);
    if (jsonStr == null || jsonStr.isEmpty) return [];
    try {
      final List<dynamic> jsonList = jsonDecode(jsonStr);
      return jsonList
          .map((json) =>
              PendingUploadTask.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('Error parsing pending uploads: $e');
      return [];
    }
  }

  // ========== 重置所有數據 ==========

  /// 清除所有數據（重置應用）
  Future<bool> clearAllData() async {
    await clearInspectionItems();
    await clearInspectionRecords();
    await clearAnalysisResults();
    await prefs.remove(AppConstants.keyCurrentStep);
    await prefs.remove(AppConstants.keyAppState);
    await prefs.remove(AppConstants.keyAuthTokens);
    await prefs.remove(AppConstants.keyAssignedJobs);
    await prefs.remove(AppConstants.keySelectedJobId);
    await prefs.remove(AppConstants.keyPendingUploads);
    return true;
  }

  // ========== 快速分析模式相關 ==========

  /// 保存快速分析模式狀態
  Future<bool> saveQuickAnalysisMode(bool isQuickMode) async {
    return await prefs.setBool('quick_analysis_mode', isQuickMode);
  }

  /// 獲取快速分析模式狀態
  bool getQuickAnalysisMode() {
    return prefs.getBool('quick_analysis_mode') ?? false;
  }
}
