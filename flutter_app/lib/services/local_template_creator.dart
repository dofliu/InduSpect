import 'dart:convert';
import 'dart:typed_data';
import 'package:excel/excel.dart';
import 'package:archive/archive.dart';

/// 本地離線模板建立服務
///
/// 當後端不可用時，直接在 App 端解析 Excel/Word 文件
/// 並產生 InspectionTemplate JSON。
class LocalTemplateCreator {
  /// 從檔案 bytes 建立模板
  Future<Map<String, dynamic>> createTemplateFromBytes({
    required Uint8List bytes,
    required String fileName,
    required String templateName,
    String category = '一般設備',
    String company = '',
    String department = '',
  }) async {
    final extension = fileName.toLowerCase().split('.').last;

    List<String> extractedTexts;

    if (extension == 'xlsx' || extension == 'xls') {
      extractedTexts = _extractExcelTexts(bytes);
    } else if (extension == 'docx') {
      extractedTexts = _extractWordTexts(bytes);
    } else {
      throw Exception('不支援的檔案格式: $extension');
    }

    if (extractedTexts.isEmpty) {
      throw Exception('無法從檔案中擷取任何文字');
    }

    // 過濾並分類欄位
    final fields = _filterAndClassifyFields(extractedTexts);

    // 產生模板 JSON
    final now = DateTime.now().toIso8601String();
    final templateId = 'TEMP-${DateTime.now().millisecondsSinceEpoch.toRadixString(16).toUpperCase()}';
    final estimatedMinutes = (fields.values.fold<int>(0, (sum, list) => sum + list.length) * 2).clamp(10, 180);

    final template = {
      'template_id': templateId,
      'template_name': templateName,
      'template_version': '1.0',
      'category': category,
      'created_at': now,
      'updated_at': now,
      'metadata': {
        'company': company,
        'department': department,
        'inspection_cycle_days': 30,
        'estimated_duration_minutes': estimatedMinutes,
        'required_tools': ['相機'],
      },
      'sections': _buildSections(fields, fileName, extension),
      'source_file': {
        'file_name': fileName,
        'file_type': extension == 'docx' ? 'word' : 'excel',
      },
    };

    final totalFields = (template['sections'] as List)
        .fold<int>(0, (sum, s) => sum + ((s as Map)['fields'] as List).length);

    return {
      'success': true,
      'template_id': templateId,
      'field_count': totalFields,
      'section_count': (template['sections'] as List).length,
      'template': template,
      'created_locally': true,
    };
  }

  /// 從 Excel 擷取文字
  List<String> _extractExcelTexts(Uint8List bytes) {
    final texts = <String>[];
    try {
      final excel = Excel.decodeBytes(bytes);
      for (final sheetName in excel.tables.keys) {
        final sheet = excel.tables[sheetName]!;
        for (final row in sheet.rows) {
          for (final cell in row) {
            if (cell != null && cell.value != null) {
              final text = cell.value.toString().trim();
              if (text.isNotEmpty) {
                texts.add(text);
              }
            }
          }
        }
      }
    } catch (e) {
      print('Excel 解析錯誤: $e');
    }
    return texts;
  }

  /// 從 Word (.docx) 擷取文字
  List<String> _extractWordTexts(Uint8List bytes) {
    final texts = <String>[];
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      // 找到 document.xml
      final documentXml = archive.files.firstWhere(
        (f) => f.name == 'word/document.xml',
        orElse: () => archive.files.first,
      );

      if (documentXml.name == 'word/document.xml') {
        final content = utf8.decode(documentXml.content as List<int>);
        // 擷取 <w:t> 標籤中的文字
        final regex = RegExp(r'<w:t[^>]*>([^<]+)</w:t>');
        final matches = regex.allMatches(content);

        // 合併同一段落中的文字片段
        final paragraphRegex = RegExp(r'<w:p[ >][\s\S]*?</w:p>');
        final paragraphs = paragraphRegex.allMatches(content);

        for (final para in paragraphs) {
          final paraContent = para.group(0)!;
          final textMatches = regex.allMatches(paraContent);
          final paraText = textMatches.map((m) => m.group(1)!).join('').trim();
          if (paraText.isNotEmpty) {
            texts.add(paraText);
          }
        }

        // 如果段落擷取失敗，用逐一擷取作為備援
        if (texts.isEmpty) {
          for (final match in matches) {
            final text = match.group(1)!.trim();
            if (text.isNotEmpty) {
              texts.add(text);
            }
          }
        }
      }
    } catch (e) {
      print('Word 解析錯誤: $e');
    }
    return texts;
  }

  /// 判斷文字是否為區段標題
  bool _isSectionHeader(String text) {
    // 中文數字編號
    if (RegExp(r'^[一二三四五六七八九十]+[、．.]').hasMatch(text)) return true;
    if (RegExp(r'^[（(][一二三四五六七八九十]+[）)]').hasMatch(text)) return true;

    // 常見表頭文字
    const headers = [
      '項次', '檢查項目', '檢查標準', '檢查要點', '量測項目',
      '量測位置', '判定', '備註/異常說明', '備註', '序號',
      '項目', '標準值', '實測值', '結果', '說明',
    ];
    if (headers.contains(text.trim())) return true;

    return false;
  }

  /// 判斷文字是否不適合作為欄位
  bool _isNonFieldItem(String text) {
    final trimmed = text.trim();
    if (trimmed.length > 50 || trimmed.length < 2) return true;
    if (_isSectionHeader(trimmed)) return true;

    // 注意事項、簽核等
    if (RegExp(r'^注意事項').hasMatch(trimmed)) return true;
    if (RegExp(r'^簽核').hasMatch(trimmed)) return true;
    if (RegExp(r'^\d+\.\s').hasMatch(trimmed)) return true;
    if (RegExp(r'^□').hasMatch(trimmed)) return true;
    // 純數字
    if (RegExp(r'^\d+$').hasMatch(trimmed)) return true;

    return false;
  }

  /// 判斷是否為日期相關欄位
  bool _isDateField(String text) {
    return RegExp(r'日期|時間|年月日|date|time', caseSensitive: false).hasMatch(text);
  }

  /// 判斷是否為基本資訊欄位
  bool _isBasicInfoField(String text) {
    return RegExp(
      r'編號|名稱|地點|位置|廠區|樓層|型號|規格|製造商|廠牌|負責人|'
      r'檢查人|日期|時間|單位|部門|公司|表單|設備|機台|系統',
    ).hasMatch(text);
  }

  /// 判斷是否為量測欄位
  bool _isMeasurementField(String text) {
    return RegExp(
      r'電壓|電流|功率|溫度|壓力|流量|轉速|頻率|振動|噪音|'
      r'濕度|阻抗|電阻|絕緣|水壓|風速|照度|'
      r'[Vv]|[Aa]|[Ww]|℃|°C|MPa|kPa|Hz|dB|mm|μm|MΩ',
    ).hasMatch(text);
  }

  /// 判斷是否為結論類欄位
  bool _isConclusionField(String text) {
    return RegExp(
      r'總[體評]|結論|建議|改善|簽名|簽章|核准|審核|主管|'
      r'綜合|overall|評語|意見',
      caseSensitive: false,
    ).hasMatch(text);
  }

  /// 偵測量測單位
  String? _detectUnit(String text) {
    final unitPatterns = {
      'V': RegExp(r'電壓|voltage', caseSensitive: false),
      'A': RegExp(r'電流|current', caseSensitive: false),
      'W': RegExp(r'功率|power', caseSensitive: false),
      '°C': RegExp(r'溫度|temperature|℃', caseSensitive: false),
      'MPa': RegExp(r'壓力|pressure|MPa', caseSensitive: false),
      'MΩ': RegExp(r'絕緣|電阻|insulation|MΩ', caseSensitive: false),
      'Hz': RegExp(r'頻率|frequency', caseSensitive: false),
      'dB': RegExp(r'噪音|noise|dB', caseSensitive: false),
      'rpm': RegExp(r'轉速|rpm', caseSensitive: false),
      'mm': RegExp(r'厚度|長度|寬度|裂縫|mm', caseSensitive: false),
      'L/min': RegExp(r'流量|flow', caseSensitive: false),
      'lux': RegExp(r'照度|lux', caseSensitive: false),
    };

    for (final entry in unitPatterns.entries) {
      if (entry.value.hasMatch(text)) return entry.key;
    }
    return null;
  }

  /// 過濾並分類欄位到四個區段
  Map<String, List<Map<String, dynamic>>> _filterAndClassifyFields(
    List<String> texts,
  ) {
    final basicInfo = <Map<String, dynamic>>[];
    final inspectionItems = <Map<String, dynamic>>[];
    final measurements = <Map<String, dynamic>>[];
    final conclusion = <Map<String, dynamic>>[];

    int fieldIndex = 0;

    for (final text in texts) {
      if (_isNonFieldItem(text)) continue;

      fieldIndex++;
      final fieldId = 'field_$fieldIndex';

      if (_isConclusionField(text)) {
        conclusion.add(_buildField(fieldId, text, 'textarea'));
      } else if (_isMeasurementField(text)) {
        final unit = _detectUnit(text);
        measurements.add(_buildField(fieldId, text, 'number', unit: unit));
      } else if (_isDateField(text)) {
        basicInfo.add(_buildField(fieldId, text, 'date'));
      } else if (_isBasicInfoField(text)) {
        basicInfo.add(_buildField(fieldId, text, 'text'));
      } else {
        // 預設歸類為檢測項目，帶有合格/不合格選項
        inspectionItems.add(_buildField(fieldId, text, 'radio', options: [
          {'value': 'pass', 'label': '合格'},
          {'value': 'fail', 'label': '不合格'},
          {'value': 'na', 'label': '不適用'},
        ]));
      }
    }

    return {
      'basic_info': basicInfo,
      'inspection_items': inspectionItems,
      'measurements': measurements,
      'conclusion': conclusion,
    };
  }

  /// 建立欄位 JSON
  Map<String, dynamic> _buildField(
    String fieldId,
    String label,
    String fieldType, {
    String? unit,
    List<Map<String, String>>? options,
  }) {
    final field = <String, dynamic>{
      'field_id': fieldId,
      'field_type': fieldType,
      'label': label,
      'required': false,
      'ai_fillable': false,
    };
    if (unit != null) field['unit'] = unit;
    if (options != null) field['options'] = options;
    return field;
  }

  /// 組建區段列表
  List<Map<String, dynamic>> _buildSections(
    Map<String, List<Map<String, dynamic>>> fields,
    String fileName,
    String extension,
  ) {
    final sections = <Map<String, dynamic>>[];
    int order = 0;

    final sectionDefs = [
      {
        'id': 'basic_info',
        'title': '基本資訊',
        'desc': '設備基本資料與檢測資訊',
        'key': 'basic_info',
      },
      {
        'id': 'inspection_items',
        'title': '檢測項目',
        'desc': '逐項檢查與判定',
        'key': 'inspection_items',
      },
      {
        'id': 'measurements',
        'title': '量測數據',
        'desc': '量測值記錄',
        'key': 'measurements',
      },
      {
        'id': 'conclusion',
        'title': '綜合評估',
        'desc': '檢測結論與建議',
        'key': 'conclusion',
      },
    ];

    for (final def in sectionDefs) {
      final sectionFields = fields[def['key']]!;
      if (sectionFields.isEmpty) continue;

      order++;

      // 每個區段加一個照片欄位
      sectionFields.add({
        'field_id': '${def['id']}_photo',
        'field_type': 'photo',
        'label': '${def['title']}相關照片',
        'required': false,
        'ai_fillable': false,
      });

      sections.add({
        'section_id': def['id'],
        'section_title': def['title'],
        'section_order': order,
        'description': def['desc'],
        'fields': sectionFields,
      });
    }

    // 如果沒有產出任何區段，建一個通用區段
    if (sections.isEmpty) {
      sections.add({
        'section_id': 'general',
        'section_title': '檢測項目',
        'section_order': 1,
        'description': '從文件中擷取的檢測項目',
        'fields': [
          {
            'field_id': 'general_note',
            'field_type': 'textarea',
            'label': '檢測備註',
            'required': false,
            'ai_fillable': false,
          },
          {
            'field_id': 'general_photo',
            'field_type': 'photo',
            'label': '現場照片',
            'required': false,
            'ai_fillable': false,
          },
        ],
      });
    }

    // 確保有簽名欄位在最後一個區段
    final lastSection = sections.last;
    final lastFields = lastSection['fields'] as List;
    final hasSignature = lastFields.any((f) => (f as Map)['field_type'] == 'signature');
    if (!hasSignature) {
      lastFields.add({
        'field_id': 'inspector_signature',
        'field_type': 'signature',
        'label': '檢查人員簽名',
        'required': false,
        'ai_fillable': false,
      });
    }

    return sections;
  }
}
