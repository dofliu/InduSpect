/// 欄位類型枚舉
enum FieldType {
  text,
  number,
  radio,
  checkbox,
  dropdown,
  datetime,
  date,
  photo,
  photoMultiple,
  textarea,
  signature,
  aiResult,
  measurement,
  calculated,
}

/// 欄位驗證規則
class FieldValidation {
  final String? pattern;
  final int? minLength;
  final int? maxLength;
  final double? min;
  final double? max;
  final int? decimalPlaces;
  final String? errorMessage;

  FieldValidation({
    this.pattern,
    this.minLength,
    this.maxLength,
    this.min,
    this.max,
    this.decimalPlaces,
    this.errorMessage,
  });

  factory FieldValidation.fromJson(Map<String, dynamic> json) {
    return FieldValidation(
      pattern: json['pattern'],
      minLength: json['min_length'],
      maxLength: json['max_length'],
      min: json['min']?.toDouble(),
      max: json['max']?.toDouble(),
      decimalPlaces: json['decimal_places'],
      errorMessage: json['error_message'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (pattern != null) 'pattern': pattern,
      if (minLength != null) 'min_length': minLength,
      if (maxLength != null) 'max_length': maxLength,
      if (min != null) 'min': min,
      if (max != null) 'max': max,
      if (decimalPlaces != null) 'decimal_places': decimalPlaces,
      if (errorMessage != null) 'error_message': errorMessage,
    };
  }
}

/// 警告閾值
class WarningThreshold {
  final double? min;
  final double? max;
  final String message;

  WarningThreshold({
    this.min,
    this.max,
    required this.message,
  });

  factory WarningThreshold.fromJson(Map<String, dynamic> json) {
    return WarningThreshold(
      min: json['min']?.toDouble(),
      max: json['max']?.toDouble(),
      message: json['message'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (min != null) 'min': min,
      if (max != null) 'max': max,
      'message': message,
    };
  }

  bool isOutOfRange(double value) {
    if (min != null && value < min!) return true;
    if (max != null && value > max!) return true;
    return false;
  }
}

/// 條件顯示規則
class ConditionalRule {
  final String field;
  final String operator; // equals, not_equals, contains, not_empty, greater_than, less_than
  final dynamic value;

  ConditionalRule({
    required this.field,
    required this.operator,
    this.value,
  });

  factory ConditionalRule.fromJson(Map<String, dynamic> json) {
    return ConditionalRule(
      field: json['field'] ?? '',
      operator: json['operator'] ?? 'equals',
      value: json['value'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'field': field,
      'operator': operator,
      if (value != null) 'value': value,
    };
  }

  bool evaluate(dynamic fieldValue) {
    switch (operator) {
      case 'equals':
        return fieldValue == value;
      case 'not_equals':
        return fieldValue != value;
      case 'contains':
        if (fieldValue is List) {
          return fieldValue.contains(value);
        }
        return fieldValue?.toString().contains(value.toString()) ?? false;
      case 'not_empty':
        if (fieldValue == null) return false;
        if (fieldValue is String) return fieldValue.isNotEmpty;
        if (fieldValue is List) return fieldValue.isNotEmpty;
        return true;
      case 'greater_than':
        if (fieldValue is num && value is num) {
          return fieldValue > value;
        }
        return false;
      case 'less_than':
        if (fieldValue is num && value is num) {
          return fieldValue < value;
        }
        return false;
      default:
        return true;
    }
  }
}

/// 選項（用於 radio, checkbox, dropdown）
class FieldOption {
  final String value;
  final String label;

  FieldOption({
    required this.value,
    required this.label,
  });

  factory FieldOption.fromJson(Map<String, dynamic> json) {
    return FieldOption(
      value: json['value'] ?? '',
      label: json['label'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'value': value,
      'label': label,
    };
  }
}

/// 圖片解析度
class ImageResolution {
  final int width;
  final int height;

  ImageResolution({
    required this.width,
    required this.height,
  });

  factory ImageResolution.fromJson(Map<String, dynamic> json) {
    return ImageResolution(
      width: json['width'] ?? 800,
      height: json['height'] ?? 600,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'width': width,
      'height': height,
    };
  }
}

/// 模板欄位定義
class TemplateField {
  final String fieldId;
  final FieldType fieldType;
  final String label;
  final String? placeholder;
  final bool required;
  final bool aiFillable;
  final String? aiSourceField;
  final String? aiAnalysisPrompt;
  final int? maxLength;
  final int? rows;
  final String? unit;
  final FieldValidation? validation;
  final WarningThreshold? warningThreshold;
  final ConditionalRule? conditional;
  final List<FieldOption>? options;
  final dynamic defaultValue;
  final String? format;
  final bool? saveAsImage;
  final bool? aiAnalyze;
  final int? maxSizeMb;
  final ImageResolution? minResolution;
  final int? minCount;
  final int? maxCount;
  final bool? photoRequired;
  final String? measurementTool;
  final String? formula;
  final String? displayFormat;
  final bool? editable;
  final List<String>? dependsOn;

  TemplateField({
    required this.fieldId,
    required this.fieldType,
    required this.label,
    this.placeholder,
    required this.required,
    required this.aiFillable,
    this.aiSourceField,
    this.aiAnalysisPrompt,
    this.maxLength,
    this.rows,
    this.unit,
    this.validation,
    this.warningThreshold,
    this.conditional,
    this.options,
    this.defaultValue,
    this.format,
    this.saveAsImage,
    this.aiAnalyze,
    this.maxSizeMb,
    this.minResolution,
    this.minCount,
    this.maxCount,
    this.photoRequired,
    this.measurementTool,
    this.formula,
    this.displayFormat,
    this.editable,
    this.dependsOn,
  });

  factory TemplateField.fromJson(Map<String, dynamic> json) {
    return TemplateField(
      fieldId: json['field_id'] ?? '',
      fieldType: _parseFieldType(json['field_type']),
      label: json['label'] ?? '',
      placeholder: json['placeholder'],
      required: json['required'] ?? false,
      aiFillable: json['ai_fillable'] ?? false,
      aiSourceField: json['ai_source_field'],
      aiAnalysisPrompt: json['ai_analysis_prompt'],
      maxLength: json['max_length'],
      rows: json['rows'],
      unit: json['unit'],
      validation: json['validation'] != null
          ? FieldValidation.fromJson(json['validation'])
          : null,
      warningThreshold: json['warning_threshold'] != null
          ? WarningThreshold.fromJson(json['warning_threshold'])
          : null,
      conditional: json['conditional']?['show_when'] != null
          ? ConditionalRule.fromJson(json['conditional']['show_when'])
          : null,
      options: json['options'] != null
          ? (json['options'] as List)
              .map((o) => FieldOption.fromJson(o))
              .toList()
          : null,
      defaultValue: json['default_value'],
      format: json['format'],
      saveAsImage: json['save_as_image'],
      aiAnalyze: json['ai_analyze'],
      maxSizeMb: json['max_size_mb'],
      minResolution: json['min_resolution'] != null
          ? ImageResolution.fromJson(json['min_resolution'])
          : null,
      minCount: json['min_count'],
      maxCount: json['max_count'],
      photoRequired: json['photo_required'],
      measurementTool: json['measurement_tool'],
      formula: json['formula'],
      displayFormat: json['display_format'],
      editable: json['editable'],
      dependsOn: json['depends_on'] != null
          ? List<String>.from(json['depends_on'])
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'field_id': fieldId,
      'field_type': fieldType.toString().split('.').last,
      'label': label,
      if (placeholder != null) 'placeholder': placeholder,
      'required': required,
      'ai_fillable': aiFillable,
      if (aiSourceField != null) 'ai_source_field': aiSourceField,
      if (aiAnalysisPrompt != null) 'ai_analysis_prompt': aiAnalysisPrompt,
      if (maxLength != null) 'max_length': maxLength,
      if (rows != null) 'rows': rows,
      if (unit != null) 'unit': unit,
      if (validation != null) 'validation': validation!.toJson(),
      if (warningThreshold != null)
        'warning_threshold': warningThreshold!.toJson(),
      if (conditional != null)
        'conditional': {'show_when': conditional!.toJson()},
      if (options != null)
        'options': options!.map((o) => o.toJson()).toList(),
      if (defaultValue != null) 'default_value': defaultValue,
      if (format != null) 'format': format,
      if (saveAsImage != null) 'save_as_image': saveAsImage,
      if (aiAnalyze != null) 'ai_analyze': aiAnalyze,
      if (maxSizeMb != null) 'max_size_mb': maxSizeMb,
      if (minResolution != null) 'min_resolution': minResolution!.toJson(),
      if (minCount != null) 'min_count': minCount,
      if (maxCount != null) 'max_count': maxCount,
      if (photoRequired != null) 'photo_required': photoRequired,
      if (measurementTool != null) 'measurement_tool': measurementTool,
      if (formula != null) 'formula': formula,
      if (displayFormat != null) 'display_format': displayFormat,
      if (editable != null) 'editable': editable,
      if (dependsOn != null) 'depends_on': dependsOn,
    };
  }

  static FieldType _parseFieldType(String? type) {
    switch (type) {
      case 'text':
        return FieldType.text;
      case 'number':
        return FieldType.number;
      case 'radio':
        return FieldType.radio;
      case 'checkbox':
        return FieldType.checkbox;
      case 'dropdown':
        return FieldType.dropdown;
      case 'datetime':
        return FieldType.datetime;
      case 'date':
        return FieldType.date;
      case 'photo':
        return FieldType.photo;
      case 'photo_multiple':
        return FieldType.photoMultiple;
      case 'textarea':
        return FieldType.textarea;
      case 'signature':
        return FieldType.signature;
      case 'ai_result':
        return FieldType.aiResult;
      case 'measurement':
        return FieldType.measurement;
      case 'calculated':
        return FieldType.calculated;
      default:
        return FieldType.text;
    }
  }

  /// 檢查此欄位是否應該顯示
  bool shouldShow(Map<String, dynamic> filledData) {
    if (conditional == null) return true;

    final fieldValue = filledData[conditional!.field];
    return conditional!.evaluate(fieldValue);
  }

  /// 驗證欄位值
  String? validate(dynamic value) {
    // 檢查必填
    if (required) {
      if (value == null) return '此欄位為必填';
      if (value is String && value.isEmpty) return '此欄位為必填';
      if (value is List && value.isEmpty) return '此欄位為必填';
    }

    // 如果沒有驗證規則，直接通過
    if (validation == null) return null;

    // 字串長度驗證
    if (value is String) {
      if (validation!.minLength != null && value.length < validation!.minLength!) {
        return validation!.errorMessage ?? '長度不得少於 ${validation!.minLength} 字元';
      }
      if (validation!.maxLength != null && value.length > validation!.maxLength!) {
        return '長度不得超過 ${validation!.maxLength} 字元';
      }
      if (validation!.pattern != null) {
        final regex = RegExp(validation!.pattern!);
        if (!regex.hasMatch(value)) {
          return validation!.errorMessage ?? '格式不正確';
        }
      }
    }

    // 數值範圍驗證
    if (value is num) {
      if (validation!.min != null && value < validation!.min!) {
        return '數值不得小於 ${validation!.min}';
      }
      if (validation!.max != null && value > validation!.max!) {
        return '數值不得大於 ${validation!.max}';
      }
    }

    return null;
  }

  /// 檢查是否超出警告閾值
  String? checkWarning(dynamic value) {
    if (warningThreshold == null || value is! num) return null;

    if (warningThreshold!.isOutOfRange(value.toDouble())) {
      return warningThreshold!.message;
    }

    return null;
  }
}
