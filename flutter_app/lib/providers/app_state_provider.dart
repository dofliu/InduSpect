import 'package:flutter/material.dart';
import '../utils/constants.dart';
import '../services/storage_service.dart';

/// 應用狀態管理
/// 管理全局應用狀態，如當前步驟、快速分析模式等
class AppStateProvider with ChangeNotifier {
  final StorageService _storageService = StorageService();

  InspectionStep _currentStep = InspectionStep.uploadChecklist;
  bool _isQuickAnalysisMode = false;
  bool _isLoading = false;
  String? _errorMessage;

  // Getters
  InspectionStep get currentStep => _currentStep;
  bool get isQuickAnalysisMode => _isQuickAnalysisMode;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  /// 初始化應用狀態（從本地存儲恢復）
  Future<void> init() async {
    try {
      await _storageService.init();

      // 恢復當前步驟
      final savedStep = _storageService.getCurrentStep();
      _currentStep = InspectionStep.values.firstWhere(
        (step) => step.number == savedStep,
        orElse: () => InspectionStep.uploadChecklist,
      );

      // 恢復快速分析模式狀態
      _isQuickAnalysisMode = _storageService.getQuickAnalysisMode();

      notifyListeners();
    } catch (e) {
      print('Error initializing app state: $e');
      setError('初始化失敗：$e');
    }
  }

  /// 設置當前步驟
  Future<void> setStep(InspectionStep step) async {
    _currentStep = step;
    await _storageService.saveCurrentStep(step.number);
    notifyListeners();
  }

  /// 前進到下一步
  Future<void> nextStep() async {
    if (_currentStep.number < InspectionStep.values.length) {
      final nextStepNumber = _currentStep.number + 1;
      final nextStep = InspectionStep.values.firstWhere(
        (step) => step.number == nextStepNumber,
      );
      await setStep(nextStep);
    }
  }

  /// 返回到上一步
  Future<void> previousStep() async {
    if (_currentStep.number > 1) {
      final prevStepNumber = _currentStep.number - 1;
      final prevStep = InspectionStep.values.firstWhere(
        (step) => step.number == prevStepNumber,
      );
      await setStep(prevStep);
    }
  }

  /// 重置到第一步
  Future<void> resetToFirstStep() async {
    await setStep(InspectionStep.uploadChecklist);
  }

  /// 進入快速分析模式
  Future<void> enterQuickAnalysisMode() async {
    _isQuickAnalysisMode = true;
    await _storageService.saveQuickAnalysisMode(true);
    notifyListeners();
  }

  /// 退出快速分析模式
  Future<void> exitQuickAnalysisMode() async {
    _isQuickAnalysisMode = false;
    await _storageService.saveQuickAnalysisMode(false);
    notifyListeners();
  }

  /// 設置載入狀態
  void setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  /// 設置錯誤消息
  void setError(String? error) {
    _errorMessage = error;
    notifyListeners();
  }

  /// 清除錯誤消息
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// 重置應用（清除所有數據）
  Future<void> resetApp() async {
    try {
      setLoading(true);
      await _storageService.clearAllData();
      await resetToFirstStep();
      _isQuickAnalysisMode = false;
      _errorMessage = null;
      setLoading(false);
    } catch (e) {
      setError('重置失敗：$e');
      setLoading(false);
    }
  }

  /// 檢查是否可以前進到下一步
  bool canProceedToNextStep(int completedItemsCount, int totalItemsCount) {
    switch (_currentStep) {
      case InspectionStep.uploadChecklist:
        return totalItemsCount > 0;
      case InspectionStep.capturePhotos:
        return completedItemsCount == totalItemsCount && totalItemsCount > 0;
      case InspectionStep.reviewResults:
        return true; // 可以隨時前往記錄頁面
      case InspectionStep.viewRecords:
        return false; // 已經是最後一步
    }
  }
}
