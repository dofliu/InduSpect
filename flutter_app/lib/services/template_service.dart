import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/inspection_template.dart';

/// 模板服務 - 負責模板的讀取、儲存與管理
class TemplateService {
  static final TemplateService _instance = TemplateService._internal();
  factory TemplateService() => _instance;
  TemplateService._internal();

  // 緩存已載入的模板
  final Map<String, InspectionTemplate> _templateCache = {};

  // 是否已初始化
  bool _initialized = false;

  /// 初始化 - 載入預設模板
  Future<void> init() async {
    if (_initialized) return;

    print('📋 TemplateService: Initializing...');

    try {
      // 載入內建範例模板
      await loadBuiltInTemplates();

      _initialized = true;
      print('✅ TemplateService: Initialized successfully');
    } catch (e) {
      print('❌ TemplateService: Initialization failed: $e');
      rethrow;
    }
  }

  /// 載入內建範例模板
  Future<void> loadBuiltInTemplates() async {
    try {
      // 載入電機設備定期檢查表
      final motorTemplate = await loadTemplateFromAsset(
        'assets/templates/motor_inspection_template.json',
      );
      _templateCache[motorTemplate.templateId] = motorTemplate;

      print('✅ Loaded built-in template: ${motorTemplate.templateName}');
    } catch (e) {
      print('⚠️ Failed to load built-in templates: $e');
      // 不拋出錯誤，允許 App 繼續運行
    }
  }

  /// 從 Asset 載入模板
  Future<InspectionTemplate> loadTemplateFromAsset(String assetPath) async {
    try {
      final jsonString = await rootBundle.loadString(assetPath);
      final jsonData = json.decode(jsonString);
      return InspectionTemplate.fromJson(jsonData);
    } catch (e) {
      print('❌ Failed to load template from asset: $assetPath');
      print('   Error: $e');
      rethrow;
    }
  }

  /// 從 JSON 字串載入模板
  Future<InspectionTemplate> loadTemplateFromJson(String jsonString) async {
    try {
      final jsonData = json.decode(jsonString);
      final template = InspectionTemplate.fromJson(jsonData);

      // 加入緩存
      _templateCache[template.templateId] = template;

      // 儲存到本地
      await saveTemplateToLocal(template);

      return template;
    } catch (e) {
      print('❌ Failed to load template from JSON: $e');
      rethrow;
    }
  }

  /// 儲存模板到本地 SharedPreferences
  Future<void> saveTemplateToLocal(InspectionTemplate template) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final templateJson = json.encode(template.toJson());

      // 儲存模板
      await prefs.setString(
        'template_${template.templateId}',
        templateJson,
      );

      // 更新模板列表
      final templateIds = getTemplateIds();
      if (!templateIds.contains(template.templateId)) {
        templateIds.add(template.templateId);
        await prefs.setStringList('template_ids', templateIds);
      }

      print('✅ Template saved to local: ${template.templateName}');
    } catch (e) {
      print('❌ Failed to save template to local: $e');
    }
  }

  /// 從本地載入模板
  Future<InspectionTemplate?> loadTemplateFromLocal(String templateId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final templateJson = prefs.getString('template_$templateId');

      if (templateJson == null) return null;

      final jsonData = json.decode(templateJson);
      final template = InspectionTemplate.fromJson(jsonData);

      // 加入緩存
      _templateCache[templateId] = template;

      return template;
    } catch (e) {
      print('❌ Failed to load template from local: $e');
      return null;
    }
  }

  /// 取得模板 ID 列表
  List<String> getTemplateIds() {
    // 從緩存取得
    if (_templateCache.isNotEmpty) {
      return _templateCache.keys.toList();
    }

    // 從 SharedPreferences 取得
    return SharedPreferences.getInstance().then((prefs) {
      return prefs.getStringList('template_ids') ?? [];
    }) as List<String>;
  }

  /// 取得所有模板
  Future<List<InspectionTemplate>> getAllTemplates() async {
    try {
      final templateIds = await SharedPreferences.getInstance().then(
        (prefs) => prefs.getStringList('template_ids') ?? [],
      );

      final templates = <InspectionTemplate>[];

      for (final id in templateIds) {
        // 先從緩存取
        if (_templateCache.containsKey(id)) {
          templates.add(_templateCache[id]!);
          continue;
        }

        // 從本地載入
        final template = await loadTemplateFromLocal(id);
        if (template != null) {
          templates.add(template);
        }
      }

      // 如果沒有任何模板，返回緩存中的
      if (templates.isEmpty && _templateCache.isNotEmpty) {
        templates.addAll(_templateCache.values);
      }

      return templates;
    } catch (e) {
      print('❌ Failed to get all templates: $e');
      return _templateCache.values.toList();
    }
  }

  /// 根據 ID 取得模板
  Future<InspectionTemplate?> getTemplate(String templateId) async {
    // 先從緩存取
    if (_templateCache.containsKey(templateId)) {
      return _templateCache[templateId];
    }

    // 從本地載入
    return await loadTemplateFromLocal(templateId);
  }

  /// 根據 ID 取得模板（別名方法）
  Future<InspectionTemplate?> getTemplateById(String templateId) async {
    return await getTemplate(templateId);
  }

  /// 根據類別取得模板列表
  Future<List<InspectionTemplate>> getTemplatesByCategory(String category) async {
    final allTemplates = await getAllTemplates();
    return allTemplates.where((t) => t.category == category).toList();
  }

  /// 搜尋模板
  Future<List<InspectionTemplate>> searchTemplates(String keyword) async {
    final allTemplates = await getAllTemplates();
    final lowerKeyword = keyword.toLowerCase();

    return allTemplates.where((t) {
      return t.templateName.toLowerCase().contains(lowerKeyword) ||
          t.category.toLowerCase().contains(lowerKeyword);
    }).toList();
  }

  /// 刪除模板
  Future<bool> deleteTemplate(String templateId) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // 從 SharedPreferences 刪除
      await prefs.remove('template_$templateId');

      // 從模板列表移除
      final templateIds = prefs.getStringList('template_ids') ?? [];
      templateIds.remove(templateId);
      await prefs.setStringList('template_ids', templateIds);

      // 從緩存移除
      _templateCache.remove(templateId);

      print('✅ Template deleted: $templateId');
      return true;
    } catch (e) {
      print('❌ Failed to delete template: $e');
      return false;
    }
  }

  /// 清除所有模板（慎用！）
  Future<void> clearAllTemplates() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final templateIds = prefs.getStringList('template_ids') ?? [];

      // 刪除所有模板
      for (final id in templateIds) {
        await prefs.remove('template_$id');
      }

      // 清空列表
      await prefs.remove('template_ids');

      // 清空緩存
      _templateCache.clear();

      print('✅ All templates cleared');
    } catch (e) {
      print('❌ Failed to clear templates: $e');
    }
  }

  /// 取得模板統計資訊
  Future<Map<String, dynamic>> getTemplateStats() async {
    final templates = await getAllTemplates();

    final stats = <String, dynamic>{
      'total': templates.length,
      'categories': <String, int>{},
    };

    for (final template in templates) {
      final category = template.category;
      stats['categories'][category] = (stats['categories'][category] ?? 0) + 1;
    }

    return stats;
  }

  /// 驗證模板 JSON 格式
  bool validateTemplateJson(String jsonString) {
    try {
      final jsonData = json.decode(jsonString);

      // 檢查必要欄位
      if (!jsonData.containsKey('template_id')) return false;
      if (!jsonData.containsKey('template_name')) return false;
      if (!jsonData.containsKey('sections')) return false;

      // 檢查 sections 是否為陣列
      if (jsonData['sections'] is! List) return false;

      // 檢查每個 section 是否包含 fields
      for (final section in jsonData['sections']) {
        if (!section.containsKey('fields')) return false;
        if (section['fields'] is! List) return false;
      }

      return true;
    } catch (e) {
      print('❌ Invalid template JSON: $e');
      return false;
    }
  }

  /// 匯出模板為 JSON 字串
  String exportTemplateToJson(InspectionTemplate template) {
    return json.encode(template.toJson());
  }

  /// 複製模板（建立副本）
  Future<InspectionTemplate> duplicateTemplate(
    String sourceTemplateId, {
    String? newName,
  }) async {
    final sourceTemplate = await getTemplate(sourceTemplateId);
    if (sourceTemplate == null) {
      throw Exception('Source template not found');
    }

    final newTemplateId = 'TEMP-${DateTime.now().millisecondsSinceEpoch}';
    final newTemplate = InspectionTemplate(
      templateId: newTemplateId,
      templateName: newName ?? '${sourceTemplate.templateName} (副本)',
      templateVersion: '1.0',
      category: sourceTemplate.category,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      metadata: sourceTemplate.metadata,
      sections: sourceTemplate.sections,
    );

    await saveTemplateToLocal(newTemplate);

    return newTemplate;
  }

  /// 更新模板
  Future<void> updateTemplate(InspectionTemplate template) async {
    final updatedTemplate = InspectionTemplate(
      templateId: template.templateId,
      templateName: template.templateName,
      templateVersion: template.templateVersion,
      category: template.category,
      createdAt: template.createdAt,
      updatedAt: DateTime.now(), // 更新時間
      metadata: template.metadata,
      sections: template.sections,
    );

    await saveTemplateToLocal(updatedTemplate);

    // 更新緩存
    _templateCache[updatedTemplate.templateId] = updatedTemplate;
  }
}
