import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/gemini_service.dart';
import '../utils/constants.dart';

class SettingsProvider with ChangeNotifier {
  static const String _apiKeyKey = 'gemini_api_key';
  static const String _selectedModelKey = 'selected_model';
  static const String _usageCountKey = 'usage_count';
  static const String _offlineAiKey = 'offline_ai_enabled';
  static const String _offlineAiWifiOnlyKey = 'offline_ai_wifi_only';
  static const int _freeTrialLimit = 5;

  // 已下架/過期的舊模型 ID → 自動遷移到現行預設（P0-6）
  static const Set<String> _retiredModels = {
    'gemini-3-flash-preview',
    'gemini-2.0-flash',
    'gemini-2.0-flash-exp',
  };

  String? _customApiKey;
  String _selectedModel = AppConstants.geminiFlashModel; // 預設模型（見 constants.dart）
  int _usageCount = 0;
  bool _isInitialized = false;
  // Tier 1b 端側 AI 初判：預設關（要下載 3.7 GB，得由使用者自己開）。
  bool _offlineAiEnabled = false;
  bool _offlineAiWifiOnly = true;

  String? get customApiKey => _customApiKey;
  String get selectedModel => _selectedModel;
  int get usageCount => _usageCount;
  bool get hasValidApiKey => _customApiKey != null && _customApiKey!.isNotEmpty;
  bool get isTrialExpired => !hasValidApiKey && _usageCount >= _freeTrialLimit;
  int get remainingTrials => hasValidApiKey ? -1 : (_freeTrialLimit - _usageCount).clamp(0, _freeTrialLimit);
  bool get isInitialized => _isInitialized;
  bool get offlineAiEnabled => _offlineAiEnabled;
  bool get offlineAiWifiOnly => _offlineAiWifiOnly;

  /// 建構子發出的那一次載入。`init()` 等的是**同一個** future。
  ///
  /// 原本建構子與 `init()` 各發一次 `_loadSettings()`，而前者沒有人 await：
  /// 使用者若在載入完成前就存了金鑰，晚完成的那一次會用 prefs 的舊值把它蓋回去。
  Future<void>? _loading;

  SettingsProvider() {
    _loading = _loadSettings();
  }

  /// 初始化設定（確保資料已載入）
  Future<void> init() async {
    if (_isInitialized) return;
    await (_loading ??= _loadSettings());
    _isInitialized = true;
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _customApiKey = prefs.getString(_apiKeyKey);
    _selectedModel =
        prefs.getString(_selectedModelKey) ?? AppConstants.geminiFlashModel;
    // 舊版儲存的已下架模型 → 遷移到現行預設並回寫，避免呼叫失效模型
    if (_retiredModels.contains(_selectedModel)) {
      _selectedModel = AppConstants.geminiFlashModel;
      await prefs.setString(_selectedModelKey, _selectedModel);
    }
    _usageCount = prefs.getInt(_usageCountKey) ?? 0;
    _offlineAiEnabled = prefs.getBool(_offlineAiKey) ?? false;
    _offlineAiWifiOnly = prefs.getBool(_offlineAiWifiOnlyKey) ?? true;
    applyToGeminiService();
    notifyListeners();
  }

  /// 把使用者的金鑰與模型推進 `GeminiService`。
  ///
  /// **這是使用者金鑰唯一的出口。** `GeminiService` 是 singleton，而金鑰只有這裡知道；
  /// 不推的話，核心 5 步驟流程與葉片線都只讀得到被 gitignore 的 `.env`——
  /// 打包進 APK 的是空檔，AI 會靜默關閉並退回手動模式。
  ///
  /// 沒有金鑰是正常狀態（試用中、還沒填），所以 `MissingGeminiKeyException` 不往外丟。
  @visibleForTesting
  void applyToGeminiService({GeminiConfigSink? sink}) {
    final apply = sink ?? GeminiService().init;
    try {
      apply(apiKey: _customApiKey, flashModel: _selectedModel);
    } on MissingGeminiKeyException {
      // 還沒填金鑰——不是錯誤，AI 功能維持關閉。
    }
  }

  Future<void> setApiKey(String? apiKey) async {
    _customApiKey = apiKey;
    final prefs = await SharedPreferences.getInstance();
    if (apiKey == null || apiKey.isEmpty) {
      await prefs.remove(_apiKeyKey);
    } else {
      await prefs.setString(_apiKeyKey, apiKey);
    }
    applyToGeminiService();
    notifyListeners();
  }

  Future<void> setOfflineAiEnabled(bool enabled) async {
    _offlineAiEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_offlineAiKey, enabled);
    notifyListeners();
  }

  Future<void> setOfflineAiWifiOnly(bool wifiOnly) async {
    _offlineAiWifiOnly = wifiOnly;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_offlineAiWifiOnlyKey, wifiOnly);
    notifyListeners();
  }

  Future<void> setSelectedModel(String model) async {
    _selectedModel = model;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedModelKey, model);
    applyToGeminiService();
    notifyListeners();
  }

  Future<bool> incrementUsageCount() async {
    // 如果已設定 API Key，不限制使用次數
    if (hasValidApiKey) {
      return true;
    }

    // 檢查試用次數
    if (_usageCount >= _freeTrialLimit) {
      return false; // 試用已用完
    }

    _usageCount++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_usageCountKey, _usageCount);
    notifyListeners();
    return true;
  }

  Future<void> resetUsageCount() async {
    _usageCount = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_usageCountKey, 0);
    notifyListeners();
  }

  Map<String, dynamic> getUsageInfo() {
    return {
      'used': _usageCount,
      'remaining': remainingTrials,
      'hasApiKey': hasValidApiKey,
      'isExpired': isTrialExpired,
    };
  }

  String getModelDisplayName(String model) {
    switch (model) {
      case 'gemini-3.6-flash':
        return 'Gemini 3.6 Flash (標準)';
      case 'gemini-3.1-pro-preview':
        return 'Gemini 3.1 Pro (進階)';
      default:
        return model;
    }
  }

  String getModelDescription(String model) {
    switch (model) {
      case 'gemini-3.6-flash':
        return '快速回應，平衡效能與成本（GA 穩定版）\n費用依 Google 官方定價';
      case 'gemini-3.1-pro-preview':
        return '最強分析能力，適合複雜檢測\n費用依 Google 官方定價';
      default:
        return '';
    }
  }

  List<Map<String, String>> getAvailableModels() {
    return [
      {
        'id': 'gemini-3.6-flash',
        'name': 'Gemini 3.6 Flash',
        'badge': '推薦',
        'description': '快速回應，平衡效能與成本（GA 穩定版）',
        'cost': '依官方定價',
      },
      {
        'id': 'gemini-3.1-pro-preview',
        'name': 'Gemini 3.1 Pro',
        'badge': '進階',
        'description': '最強分析能力，適合複雜設備檢測',
        'cost': '依官方定價',
      },
    ];
  }
}

