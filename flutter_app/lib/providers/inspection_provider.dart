import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';
import '../models/inspection_item.dart';
import '../models/inspection_record.dart';
import '../models/analysis_result.dart';
import '../models/auth_tokens.dart';
import '../models/inspection_job.dart';
import '../models/pending_upload_task.dart';
import '../services/storage_service.dart';
import '../services/gemini_service.dart';
import '../services/image_service.dart';
import '../services/cloud_run_api_service.dart';
import '../utils/constants.dart';
import 'settings_provider.dart';

class InspectionProvider with ChangeNotifier {
  final StorageService _storageService = StorageService();
  final GeminiService _geminiService = GeminiService();
  final ImageService _imageService = ImageService();
  final CloudRunApiService _cloudRunService = CloudRunApiService();
  final Uuid _uuid = const Uuid();

  SettingsProvider? _settingsProvider;

  List<InspectionItem> _inspectionItems = [];
  Map<String, AnalysisResult> _analysisResults = {};
  List<InspectionRecord> _inspectionRecords = [];
  List<InspectionJob> _assignedJobs = [];
  List<PendingUploadTask> _pendingUploadTasks = [];
  InspectionJob? _selectedJob;
  AuthTokens? _authTokens;

  bool _isAnalyzing = false;
  bool _isJobLoading = false;
  bool _isSyncingUploads = false;
  bool _cloudRunInitialized = false;
  bool _isLoggedIn = false;

  String? _currentAnalyzingItemId;
  String? _errorMessage;
  String? _summaryReport;

  SettingsProvider? get settingsProvider => _settingsProvider;
  List<InspectionItem> get inspectionItems => _inspectionItems;
  Map<String, AnalysisResult> get analysisResults => _analysisResults;
  List<InspectionRecord> get inspectionRecords => _inspectionRecords;
  List<InspectionJob> get assignedJobs => _assignedJobs;
  InspectionJob? get selectedJob => _selectedJob;
  List<PendingUploadTask> get pendingUploadTasks => _pendingUploadTasks;
  Set<String> get pendingUploadItemIds =>
      _pendingUploadTasks.map((task) => task.pointId).toSet();
  bool get hasPendingUploads => _pendingUploadTasks.isNotEmpty;
  bool get isLoggedIn => _isLoggedIn;
  bool get isAnalyzing => _isAnalyzing;
  bool get isJobLoading => _isJobLoading;
  bool get isSyncingUploads => _isSyncingUploads;
  String? get currentAnalyzingItemId => _currentAnalyzingItemId;
  String? get errorMessage => _errorMessage;
  String? get summaryReport => _summaryReport;

  int get completedItemsCount =>
      _inspectionItems.where((item) => item.isCompleted).length;

  int get pendingReviewCount => _analysisResults.values
      .where((result) => result.status == AnalysisStatus.completed)
      .length;

  void setSettingsProvider(SettingsProvider provider) {
    _settingsProvider = provider;
  }

  Future<void> init() async {
    try {
      await _storageService.init();
      _inspectionItems = _storageService.getInspectionItems();
      _analysisResults = _storageService.getAnalysisResults();
      _inspectionRecords = _storageService.getInspectionRecords();
      _pendingUploadTasks = _storageService.getPendingUploadTasks();
      _assignedJobs = _storageService.getAssignedJobs();
      _authTokens = _storageService.getAuthTokens();
      await _ensureCloudRunInitialized();
      _isLoggedIn = _authTokens != null && !_authTokens!.isExpired;

      final selectedJobId = _storageService.getSelectedJobId();
      if (selectedJobId != null) {
        try {
          _selectedJob =
              _assignedJobs.firstWhere((job) => job.id == selectedJobId);
        } catch (_) {
          _selectedJob = null;
        }
      }

      notifyListeners();

      if (_pendingUploadTasks.isNotEmpty) {
        await processPendingUploads();
      }
    } catch (e) {
      print('Error initializing inspection data: $e');
      setError('初始化數據失敗：$e');
    }
  }

  Future<void> _ensureCloudRunInitialized() async {
    if (_cloudRunInitialized) {
      _cloudRunService.updateTokens(_authTokens);
      return;
    }
    await _cloudRunService.init(tokens: _authTokens);
    _cloudRunInitialized = true;
  }

  Future<void> loginAndLoadJobs(String email, String password) async {
    try {
      setAnalyzing(true);
      clearError();
      await _ensureCloudRunInitialized();
      final tokens = await _cloudRunService.login(email, password);
      _authTokens = tokens;
      _isLoggedIn = true;
      await _storageService.saveAuthTokens(tokens);
      _cloudRunService.updateTokens(tokens);

      final jobs = await _cloudRunService.fetchJobs();
      _assignedJobs = jobs;
      await _storageService.saveAssignedJobs(jobs);
      notifyListeners();
    } catch (e) {
      setError('登入失敗：$e');
    } finally {
      setAnalyzing(false);
    }
  }

  Future<void> refreshAssignedJobs({bool forceRemote = false}) async {
    if (!_isLoggedIn && !forceRemote) return;
    try {
      _isJobLoading = true;
      notifyListeners();
      await _ensureCloudRunInitialized();
      final jobs = await _cloudRunService.fetchJobs();
      _assignedJobs = jobs;
      await _storageService.saveAssignedJobs(jobs);
      notifyListeners();
    } catch (e) {
      print('Failed to refresh jobs: $e');
      setError('更新任務失敗：$e');
    } finally {
      _isJobLoading = false;
      notifyListeners();
    }
  }

  Future<void> selectJob(String jobId) async {
    try {
      _isJobLoading = true;
      clearError();
      notifyListeners();
      await _ensureCloudRunInitialized();
      if (!_isLoggedIn) {
        throw Exception('請先登入 Cloud Run API');
      }
      final items = await _cloudRunService.fetchChecklist(jobId);
      _inspectionItems = items;
      await _storageService.saveInspectionItems(items);
      await _storageService.saveSelectedJobId(jobId);
      try {
        _selectedJob =
            _assignedJobs.firstWhere((job) => job.id == jobId);
      } catch (_) {
        _selectedJob = null;
      }
      notifyListeners();
    } catch (e) {
      print('Failed to load checklist: $e');
      setError('載入檢查表失敗：$e');
    } finally {
      _isJobLoading = false;
      notifyListeners();
    }
  }

  Future<void> clearSelectedJob() async {
    _selectedJob = null;
    _inspectionItems = [];
    _analysisResults = {};
    await _storageService.saveInspectionItems(_inspectionItems);
    await _storageService.saveAnalysisResults(_analysisResults);
    await _storageService.saveSelectedJobId(null);
    notifyListeners();
  }

  Future<void> logout() async {
    _isLoggedIn = false;
    _authTokens = null;
    await _storageService.clearAuthTokens();
    await clearAllData();
  }

  Future<bool> _checkUsageLimit() async {
    if (_settingsProvider == null) return true;
    if (_settingsProvider!.isTrialExpired) {
      setError('試用次數已用完，請在設定中輸入您的 API Key');
      return false;
    }
    return true;
  }

  void _initGeminiService() {
    if (_settingsProvider?.hasValidApiKey == true) {
      _geminiService.init(apiKey: _settingsProvider!.customApiKey);
    } else {
      _geminiService.init();
    }
  }

  Future<void> _incrementUsage() async {
    if (_settingsProvider != null) {
      await _settingsProvider!.incrementUsageCount();
    }
  }

  Future<void> uploadChecklistFromXFile(XFile imageFile) async {
    try {
      setAnalyzing(true);
      clearError();
      if (!await _checkUsageLimit()) {
        setAnalyzing(false);
        return;
      }
      _initGeminiService();
      final imageBytes = await imageFile.readAsBytes();
      final savedPath = await _imageService.compressAndSaveImageFromBytes(imageBytes);
      final compressedBytes = await _imageService.getImageBytes(savedPath);
      final items = await _geminiService.extractChecklistItems(compressedBytes);
      await _incrementUsage();
      _inspectionItems = items
          .map((description) => InspectionItem(
                id: _uuid.v4(),
                description: description,
              ))
          .toList();
      await _storageService.saveInspectionItems(_inspectionItems);
      setAnalyzing(false);
      notifyListeners();
    } catch (e) {
      print('Error uploading checklist: $e');
      setError('定檢表分析失敗：$e');
      setAnalyzing(false);
    }
  }

  Future<void> addPhotoToItemFromXFile(String itemId, XFile imageFile) async {
    if (_selectedJob == null) {
      setError('請先選擇要執行的巡檢工作');
      return;
    }
    try {
      final imageBytes = await imageFile.readAsBytes();
      final savedPath = await _imageService.compressAndSaveImageFromBytes(imageBytes);
      final compressedBytes = await _imageService.getImageBytes(savedPath);
      final index = _inspectionItems.indexWhere((item) => item.id == itemId);
      if (index != -1) {
        _inspectionItems[index] = _inspectionItems[index].copyWith(
          photoPath: savedPath,
          isCompleted: true,
        );
        await _storageService.saveInspectionItems(_inspectionItems);
      }
      final task = PendingUploadTask(
        id: _uuid.v4(),
        jobId: _selectedJob!.id,
        pointId: itemId,
        itemDescription: index != -1
            ? _inspectionItems[index].description
            : '巡檢點',
        photoPath: savedPath,
        createdAt: DateTime.now(),
      );
      _pendingUploadTasks.add(task);
      await _storageService.savePendingUploadTasks(_pendingUploadTasks);
      notifyListeners();
      await _attemptProcessTask(task, cachedBytes: compressedBytes);
    } catch (e) {
      print('Error adding photo to item: $e');
      setError('照片保存失敗：$e');
    }
  }

  Future<void> analyzeAllPhotos() async {
    if (_pendingUploadTasks.isEmpty) {
      setError('沒有待上傳的照片');
      return;
    }
    await processPendingUploads();
  }

  Future<void> processPendingUploads() async {
    if (_isSyncingUploads || _pendingUploadTasks.isEmpty) return;
    if (!_isLoggedIn) {
      setError('請先登入以同步照片');
      return;
    }
    _isSyncingUploads = true;
    notifyListeners();
    final tasks = List<PendingUploadTask>.from(_pendingUploadTasks);
    for (final task in tasks) {
      await _attemptProcessTask(task);
    }
    _isSyncingUploads = false;
    notifyListeners();
  }

  Future<void> _attemptProcessTask(
    PendingUploadTask task, {
    Uint8List? cachedBytes,
  }) async {
    try {
      await _ensureCloudRunInitialized();
      final bytes =
          cachedBytes ?? await _imageService.getImageBytes(task.photoPath);
      final ticket = await _cloudRunService.requestUploadTicket(
        task.jobId,
        task.pointId,
      );
      await _cloudRunService.uploadBytesToSignedUrl(ticket, bytes);
      await _cloudRunService.notifyUploadComplete(
        task.jobId,
        task.pointId,
        ticket.objectPath,
      );
      final result = await _cloudRunService.waitForAnalysis(
        jobId: task.jobId,
        pointId: task.pointId,
        photoPath: task.photoPath,
      );
      if (result != null) {
        _analysisResults[task.pointId] = result;
        await _storageService.saveAnalysisResults(_analysisResults);
        await _removePendingTask(task.id);
        notifyListeners();
        return;
      }
      throw Exception('雲端分析逾時，稍後將自動重試');
    } catch (e) {
      await _handleFailedUpload(task, e.toString());
    }
  }

  Future<void> _handleFailedUpload(
    PendingUploadTask task,
    String errorMessage,
  ) async {
    final updatedTask = task.copyWith(
      retryCount: task.retryCount + 1,
      lastError: errorMessage,
      lastTriedAt: DateTime.now(),
    );
    _pendingUploadTasks = _pendingUploadTasks
        .map((t) => t.id == updatedTask.id ? updatedTask : t)
        .toList();
    await _storageService.savePendingUploadTasks(_pendingUploadTasks);
    notifyListeners();

    if (updatedTask.retryCount >= 3) {
      await _runFallbackAnalysis(updatedTask);
    } else {
      setError('照片上傳失敗，稍後將重試：$errorMessage');
    }
  }

  Future<void> _runFallbackAnalysis(PendingUploadTask task) async {
    try {
      final description = task.itemDescription.isNotEmpty
          ? task.itemDescription
          : _inspectionItems
                  .firstWhere((item) => item.id == task.pointId,
                      orElse: () => InspectionItem(
                            id: task.pointId,
                            description: '巡檢點',
                          ))
                  .description;
      final bytes = await _imageService.getImageBytes(task.photoPath);
      _initGeminiService();
      final result = await _geminiService.fallbackAnalyzeFromBytes(
        itemId: task.pointId,
        itemDescription: description,
        imageBytes: bytes,
        photoPath: task.photoPath,
      );
      _analysisResults[task.pointId] = result;
      await _storageService.saveAnalysisResults(_analysisResults);
      await _removePendingTask(task.id);
      notifyListeners();
    } catch (e) {
      print('Fallback analysis failed: $e');
    }
  }

  Future<void> _removePendingTask(String taskId) async {
    _pendingUploadTasks.removeWhere((task) => task.id == taskId);
    await _storageService.savePendingUploadTasks(_pendingUploadTasks);
  }

  String? getPendingUploadError(String itemId) {
    try {
      return _pendingUploadTasks
          .firstWhere((task) => task.pointId == itemId)
          .lastError;
    } catch (_) {
      return null;
    }
  }

  void updateAnalysisResult(String itemId, AnalysisResult updatedResult) {
    _analysisResults[itemId] = updatedResult;
    _storageService.saveAnalysisResults(_analysisResults);
    notifyListeners();
  }

  Future<void> confirmAnalysisResult(String itemId) async {
    try {
      final result = _analysisResults[itemId];
      final item = _inspectionItems.firstWhere((item) => item.id == itemId);
      if (result != null) {
        final record =
            InspectionRecord.fromAnalysisResult(result, item.description);
        _inspectionRecords.add(record);
        _analysisResults.remove(itemId);
        await _storageService.saveInspectionRecords(_inspectionRecords);
        await _storageService.saveAnalysisResults(_analysisResults);
        notifyListeners();
      }
    } catch (e) {
      print('Error confirming analysis result: $e');
      setError('確認記錄失敗：$e');
    }
  }

  Future<void> confirmAllResults() async {
    try {
      final completedResults = _analysisResults.entries
          .where((entry) => entry.value.status == AnalysisStatus.completed)
          .toList();
      for (var entry in completedResults) {
        await confirmAnalysisResult(entry.key);
      }
    } catch (e) {
      print('Error confirming all results: $e');
      setError('批量確認失敗：$e');
    }
  }

  Future<void> reanalyzeWithSupplementalPrompt(
    String itemId,
    String supplementalPrompt,
  ) async {
    try {
      setAnalyzing(true);
      clearError();
      _currentAnalyzingItemId = itemId;
      if (!await _checkUsageLimit()) {
        setAnalyzing(false);
        _currentAnalyzingItemId = null;
        return;
      }
      _initGeminiService();
      final item = _inspectionItems.firstWhere((item) => item.id == itemId);
      final imageBytes = await _imageService.getImageBytes(item.photoPath!);
      final result = await _geminiService.reanalyzeWithPrompt(
        itemId: itemId,
        itemDescription: item.description,
        imageBytes: imageBytes,
        photoPath: item.photoPath!,
        supplementalPrompt: supplementalPrompt,
      );
      await _incrementUsage();
      _analysisResults[itemId] = result;
      await _storageService.saveAnalysisResults(_analysisResults);
      _currentAnalyzingItemId = null;
      setAnalyzing(false);
    } catch (e) {
      print('Error reanalyzing: $e');
      setError('重新分析失敗：$e');
      _currentAnalyzingItemId = null;
      setAnalyzing(false);
    }
  }

  Future<void> generateSummaryReport() async {
    try {
      setAnalyzing(true);
      clearError();
      if (!await _checkUsageLimit()) {
        setAnalyzing(false);
        return;
      }
      _initGeminiService();
      final recordsForReport =
          _inspectionRecords.map((r) => r.toReportFormat()).toList();
      final recordsJson = recordsForReport.toString();
      _summaryReport = await _geminiService.generateSummaryReport(recordsJson);
      await _incrementUsage();
      setAnalyzing(false);
      notifyListeners();
    } catch (e) {
      print('Error generating summary report: $e');
      setError('報告生成失敗：$e');
      setAnalyzing(false);
    }
  }

  Future<AnalysisResult?> quickAnalyzeFromXFile(XFile imageFile) async {
    try {
      setAnalyzing(true);
      clearError();
      if (!await _checkUsageLimit()) {
        setAnalyzing(false);
        return null;
      }
      _initGeminiService();
      final imageBytes = await imageFile.readAsBytes();
      final savedPath = await _imageService.compressAndSaveImageFromBytes(imageBytes);
      final compressedBytes = await _imageService.getImageBytes(savedPath);
      final tempId = _uuid.v4();
      final result = await _geminiService.quickAnalyze(
        itemId: tempId,
        imageBytes: compressedBytes,
        photoPath: savedPath,
      );
      await _incrementUsage();
      setAnalyzing(false);
      return result;
    } catch (e) {
      print('Error in quick analysis: $e');
      setError('快速分析失敗：$e');
      setAnalyzing(false);
      return null;
    }
  }

  Future<void> saveQuickAnalysisResult(AnalysisResult result) async {
    try {
      final record = InspectionRecord.fromAnalysisResult(
        result,
        result.equipmentType ?? '快速分析項目',
      );
      _inspectionRecords.add(record);
      await _storageService.saveInspectionRecords(_inspectionRecords);
      notifyListeners();
    } catch (e) {
      print('Error saving quick analysis result: $e');
      setError('保存記錄失敗：$e');
    }
  }

  void setAnalyzing(bool analyzing) {
    _isAnalyzing = analyzing;
    notifyListeners();
  }

  void setError(String? error) {
    _errorMessage = error;
    notifyListeners();
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> clearAllData() async {
    _inspectionItems.clear();
    _analysisResults.clear();
    _inspectionRecords.clear();
    _summaryReport = null;
    _assignedJobs.clear();
    _selectedJob = null;
    _pendingUploadTasks.clear();
    _authTokens = null;
    _isLoggedIn = false;
    _cloudRunService.updateTokens(null);
    await _storageService.clearAllData();
    notifyListeners();
  }

  Future<void> deleteRecord(String recordId) async {
    _inspectionRecords.removeWhere((record) => record.id == recordId);
    await _storageService.saveInspectionRecords(_inspectionRecords);
    notifyListeners();
  }
}
