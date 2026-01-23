import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsProvider with ChangeNotifier {
  static const String _apiKeyKey = 'gemini_api_key';
  static const String _selectedModelKey = 'selected_model';
  static const String _usageCountKey = 'usage_count';
  static const int _freeTrialLimit = 5;

  String? _customApiKey;
  String _selectedModel = 'gemini-3-flash-preview'; // 預設模型 (2026-01 更新)
  int _usageCount = 0;
  bool _isInitialized = false;

  String? get customApiKey => _customApiKey;
  String get selectedModel => _selectedModel;
  int get usageCount => _usageCount;
  bool get hasValidApiKey => _customApiKey != null && _customApiKey!.isNotEmpty;
  bool get isTrialExpired => !hasValidApiKey && _usageCount >= _freeTrialLimit;
  int get remainingTrials => hasValidApiKey ? -1 : (_freeTrialLimit - _usageCount).clamp(0, _freeTrialLimit);
  bool get isInitialized => _isInitialized;

  SettingsProvider() {
    _loadSettings();
  }

  /// 初始化設定（確保資料已載入）
  Future<void> init() async {
    if (_isInitialized) return;
    await _loadSettings();
    _isInitialized = true;
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _customApiKey = prefs.getString(_apiKeyKey);
    _selectedModel = prefs.getString(_selectedModelKey) ?? 'gemini-3-flash-preview';
    _usageCount = prefs.getInt(_usageCountKey) ?? 0;
    notifyListeners();
  }

  Future<void> setApiKey(String? apiKey) async {
    _customApiKey = apiKey;
    final prefs = await SharedPreferences.getInstance();
    if (apiKey == null || apiKey.isEmpty) {
      await prefs.remove(_apiKeyKey);
    } else {
      await prefs.setString(_apiKeyKey, apiKey);
    }
    notifyListeners();
  }

  Future<void> setSelectedModel(String model) async {
    _selectedModel = model;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedModelKey, model);
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

  String getEffectiveApiKey(String defaultApiKey) {
    return hasValidApiKey ? _customApiKey! : defaultApiKey;
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
      case 'gemini-3-flash-preview':
        return 'Gemini 3 Flash (標準)';
      case 'gemini-3-pro-preview':
        return 'Gemini 3 Pro (進階)';
      default:
        return model;
    }
  }

  String getModelDescription(String model) {
    switch (model) {
      case 'gemini-3-flash-preview':
        return '快速回應，平衡效能與成本\n費用：\$0.50/\$3 (輸入/輸出)';
      case 'gemini-3-pro-preview':
        return '最強分析能力，適合複雜檢測\n費用：\$2/\$12 (輸入/輸出)';
      default:
        return '';
    }
  }

  List<Map<String, String>> getAvailableModels() {
    return [
      {
        'id': 'gemini-3-flash-preview',
        'name': 'Gemini 3 Flash',
        'badge': '推薦',
        'description': '快速回應，平衡效能與成本',
        'cost': '\$0.50/\$3',
      },
      {
        'id': 'gemini-3-pro-preview',
        'name': 'Gemini 3 Pro',
        'badge': '進階',
        'description': '最強分析能力，適合複雜設備檢測',
        'cost': '\$2/\$12',
      },
    ];
  }
}

