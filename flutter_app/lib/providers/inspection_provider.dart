import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';
import '../models/inspection_item.dart';
import '../models/inspection_record.dart';
import '../models/analysis_result.dart';
import '../services/storage_service.dart';
import '../services/gemini_service.dart';
import '../services/image_service.dart';
import '../utils/constants.dart';

/// 巡檢數據管理
/// 管理巡檢項目、分析結果和巡檢記錄
class InspectionProvider with ChangeNotifier {
  final StorageService _storageService = StorageService();
  final GeminiService _geminiService = GeminiService();
  final ImageService _imageService = ImageService();
  final Uuid _uuid = const Uuid();

  List<InspectionItem> _inspectionItems = [];
  Map<String, AnalysisResult> _analysisResults = {};
  List<InspectionRecord> _inspectionRecords = [];

  bool _isAnalyzing = false;
  String? _currentAnalyzingItemId;
  String? _errorMessage;
  String? _summaryReport;

  // Getters
  List<InspectionItem> get inspectionItems => _inspectionItems;
  Map<String, AnalysisResult> get analysisResults => _analysisResults;
  List<InspectionRecord> get inspectionRecords => _inspectionRecords;
  bool get isAnalyzing => _isAnalyzing;
  String? get currentAnalyzingItemId => _currentAnalyzingItemId;
  String? get errorMessage => _errorMessage;
  String? get summaryReport => _summaryReport;

  /// 獲取已完成拍攝的項目數量
  int get completedItemsCount =>
      _inspectionItems.where((item) => item.isCompleted).length;

  /// 獲取待審核的分析結果數量
  int get pendingReviewCount => _analysisResults.values
      .where((result) => result.status == AnalysisStatus.completed)
      .length;

  /// 初始化（從本地存儲恢復數據）
  Future<void> init() async {
    try {
      _inspectionItems = _storageService.getInspectionItems();
      _analysisResults = _storageService.getAnalysisResults();
      _inspectionRecords = _storageService.getInspectionRecords();
      notifyListeners();
    } catch (e) {
      print('Error initializing inspection data: $e');
      setError('初始化數據失敗：$e');
    }
  }

  // ========== 步驟 1: 上傳定檢表 ==========

  /// 上傳並分析定檢表照片（從 XFile）
  Future<void> uploadChecklistFromXFile(XFile imageFile) async {
    try {
      setAnalyzing(true);
      clearError();

      // 讀取圖片字節
      final imageBytes = await imageFile.readAsBytes();

      // 壓縮並保存圖片（使用字節方法）
      final savedPath = await _imageService.compressAndSaveImageFromBytes(imageBytes);

      // 獲取壓縮後的字節用於 API
      final compressedBytes = await _imageService.getImageBytes(savedPath);

      // 呼叫 Gemini API 提取項目
      final items = await _geminiService.extractChecklistItems(compressedBytes);

      // 創建 InspectionItem 列表
      _inspectionItems = items
          .map((description) => InspectionItem(
                id: _uuid.v4(),
                description: description,
              ))
          .toList();

      // 保存到本地存儲
      await _storageService.saveInspectionItems(_inspectionItems);

      setAnalyzing(false);
      notifyListeners();
    } catch (e) {
      print('Error uploading checklist: $e');
      setError('定檢表分析失敗：$e');
      setAnalyzing(false);
    }
  }


  // ========== 步驟 2: 拍攝巡檢照片 ==========

  /// 為特定項目添加照片（從 XFile）
  Future<void> addPhotoToItemFromXFile(String itemId, XFile imageFile) async {
    try {
      // 讀取圖片字節
      final imageBytes = await imageFile.readAsBytes();

      // 壓縮並保存圖片
      final savedPath = await _imageService.compressAndSaveImageFromBytes(imageBytes);

      // 更新項目
      final index = _inspectionItems.indexWhere((item) => item.id == itemId);
      if (index != -1) {
        _inspectionItems[index] = _inspectionItems[index].copyWith(
          photoPath: savedPath,
          isCompleted: true,
        );

        // 保存到本地存儲
        await _storageService.saveInspectionItems(_inspectionItems);

        notifyListeners();
      }
    } catch (e) {
      print('Error adding photo to item: $e');
      setError('照片保存失敗：$e');
    }
  }


  /// 分析所有已拍攝的照片
  Future<void> analyzeAllPhotos() async {
    try {
      setAnalyzing(true);
      clearError();

      _geminiService.init();

      for (var item in _inspectionItems) {
        if (item.isCompleted && item.photoPath != null) {
          _currentAnalyzingItemId = item.id;
          notifyListeners();

          // 獲取圖片字節
          final imageBytes =
              await _imageService.getImageBytes(item.photoPath!);

          // 呼叫 Gemini API 分析
          final result = await _geminiService.analyzeInspectionPhoto(
            itemId: item.id,
            itemDescription: item.description,
            imageBytes: imageBytes,
            photoPath: item.photoPath!,
          );

          _analysisResults[item.id] = result;
        }
      }

      // 保存分析結果
      await _storageService.saveAnalysisResults(_analysisResults);

      _currentAnalyzingItemId = null;
      setAnalyzing(false);
    } catch (e) {
      print('Error analyzing photos: $e');
      setError('照片分析失敗：$e');
      _currentAnalyzingItemId = null;
      setAnalyzing(false);
    }
  }

  // ========== 步驟 3: 審核結果 ==========

  /// 更新分析結果（手動編輯）
  void updateAnalysisResult(String itemId, AnalysisResult updatedResult) {
    _analysisResults[itemId] = updatedResult;
    _storageService.saveAnalysisResults(_analysisResults);
    notifyListeners();
  }

  /// 確認單個分析結果，添加到記錄
  Future<void> confirmAnalysisResult(String itemId) async {
    try {
      final result = _analysisResults[itemId];
      final item =
          _inspectionItems.firstWhere((item) => item.id == itemId);

      if (result != null) {
        final record =
            InspectionRecord.fromAnalysisResult(result, item.description);
        _inspectionRecords.add(record);

        // 從待審核列表中移除
        _analysisResults.remove(itemId);

        // 保存
        await _storageService.saveInspectionRecords(_inspectionRecords);
        await _storageService.saveAnalysisResults(_analysisResults);

        notifyListeners();
      }
    } catch (e) {
      print('Error confirming analysis result: $e');
      setError('確認記錄失敗：$e');
    }
  }

  /// 批量確認所有已完成的分析結果
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

  /// 重新分析（帶補充提示）
  Future<void> reanalyzeWithSupplementalPrompt(
    String itemId,
    String supplementalPrompt,
  ) async {
    try {
      setAnalyzing(true);
      _currentAnalyzingItemId = itemId;

      final item = _inspectionItems.firstWhere((item) => item.id == itemId);
      final imageBytes = await _imageService.getImageBytes(item.photoPath!);

      final result = await _geminiService.reanalyzeWithPrompt(
        itemId: itemId,
        itemDescription: item.description,
        imageBytes: imageBytes,
        photoPath: item.photoPath!,
        supplementalPrompt: supplementalPrompt,
      );

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

  // ========== 步驟 4: 生成報告 ==========

  /// 生成巡檢摘要報告
  Future<void> generateSummaryReport() async {
    try {
      setAnalyzing(true);
      clearError();

      // 將記錄轉換為報告格式
      final recordsForReport =
          _inspectionRecords.map((r) => r.toReportFormat()).toList();
      final recordsJson = recordsForReport.toString();

      // 呼叫 Gemini Pro 生成報告
      _summaryReport = await _geminiService.generateSummaryReport(recordsJson);

      setAnalyzing(false);
      notifyListeners();
    } catch (e) {
      print('Error generating summary report: $e');
      setError('報告生成失敗：$e');
      setAnalyzing(false);
    }
  }

  // ========== 快速分析模式 ==========

  /// 快速分析單張照片（從 XFile）
  Future<AnalysisResult?> quickAnalyzeFromXFile(XFile imageFile) async {
    try {
      setAnalyzing(true);
      clearError();

      _geminiService.init();

      // 讀取圖片字節
      final imageBytes = await imageFile.readAsBytes();

      // 壓縮並保存圖片
      final savedPath = await _imageService.compressAndSaveImageFromBytes(imageBytes);

      // 獲取壓縮後的字節
      final compressedBytes = await _imageService.getImageBytes(savedPath);

      // 生成臨時 ID
      final tempId = _uuid.v4();

      // 快速分析
      final result = await _geminiService.quickAnalyze(
        itemId: tempId,
        imageBytes: compressedBytes,
        photoPath: savedPath,
      );

      setAnalyzing(false);
      return result;
    } catch (e) {
      print('Error in quick analysis: $e');
      setError('快速分析失敗：$e');
      setAnalyzing(false);
      return null;
    }
  }


  /// 保存快速分析結果到記錄
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

  // ========== 工具方法 ==========

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

  /// 清除所有巡檢數據
  Future<void> clearAllData() async {
    _inspectionItems.clear();
    _analysisResults.clear();
    _inspectionRecords.clear();
    _summaryReport = null;

    await _storageService.clearAllData();
    notifyListeners();
  }

  /// 刪除單個記錄
  Future<void> deleteRecord(String recordId) async {
    _inspectionRecords.removeWhere((record) => record.id == recordId);
    await _storageService.saveInspectionRecords(_inspectionRecords);
    notifyListeners();
  }
}
