import 'package:flutter/material.dart';
import '../../models/inspection_template.dart';
import '../../models/template_field.dart';
import '../field_inputs/text_field_input.dart';
import '../field_inputs/number_field_input.dart';
import '../field_inputs/radio_field_input.dart';
import '../field_inputs/checkbox_field_input.dart';
import '../field_inputs/dropdown_field_input.dart';
import '../field_inputs/datetime_field_input.dart';
import '../field_inputs/photo_field_input.dart';
import '../field_inputs/textarea_field_input.dart';
import '../field_inputs/signature_field_input.dart';

/// @µaGDˆ
/// ÔUã/6o:@µgÑ@	M
class SectionCard extends StatefulWidget {
  final TemplateSection section;
  final Map<String, dynamic> filledData;
  final Function(String fieldId, dynamic value) onFieldChanged;
  final Function(String fieldId, Map<String, dynamic> aiResults) onAIAnalysis;
  final bool initiallyExpanded;

  const SectionCard({
    Key? key,
    required this.section,
    required this.filledData,
    required this.onFieldChanged,
    required this.onAIAnalysis,
    this.initiallyExpanded = false,
  }) : super(key: key);

  @override
  State<SectionCard> createState() => _SectionCardState();
}

class _SectionCardState extends State<SectionCard> {
  late bool _isExpanded;
  final Map<String, String> _validationErrors = {};
  final Map<String, String> _warnings = {};

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    final visibleFields = widget.section.getVisibleFields(widget.filledData);
    final requiredFields = visibleFields.where((f) => f.required);
    final filledRequiredCount = requiredFields.where((f) {
      final value = widget.filledData[f.fieldId];
      return value != null && (value is! String || value.isNotEmpty);
    }).length;
    final isCompleted = requiredFields.isEmpty || filledRequiredCount == requiredFields.length;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: _isExpanded ? Theme.of(context).primaryColor : Colors.grey[300]!,
          width: _isExpanded ? 2 : 1,
        ),
      ),
      child: Column(
        children: [
          // @µL
          InkWell(
            onTap: () {
              setState(() {
                _isExpanded = !_isExpanded;
              });
            },
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  // å¿K:
                  Icon(
                    isCompleted ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: isCompleted ? Colors.green : Colors.grey,
                    size: 28,
                  ),
                  const SizedBox(width: 12),

                  // L2¶
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.section.sectionTitle,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          requiredFields.isEmpty
                              ? '${visibleFields.length} M!≈k	'
                              : '$filledRequiredCount / ${requiredFields.length} ≈kÚå',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Uã/6:
                  Icon(
                    _isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 28,
                  ),
                ],
              ),
            ),
          ),

          // MhUãBo:	
          if (_isExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: visibleFields.map((field) {
                  return _buildFieldWidget(field);
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFieldWidget(TemplateField field) {
    final value = widget.filledData[field.fieldId];
    final error = _validationErrors[field.fieldId];
    final warning = _warnings[field.fieldId];

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Md
          Row(
            children: [
              Expanded(
                child: Text(
                  field.label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (field.required)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red[50],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '≈k',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.red[700],
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 8),

          // M8eDˆ
          _buildFieldInputWidget(field, value),

          // WI/§
o
          if (error != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red[50],
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error, color: Colors.red, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      error,
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // fJ
o
          if (warning != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange[50],
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning, color: Colors.orange, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      warning,
                      style: const TextStyle(color: Colors.orange, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // AI ©–:
          if (field.aiFillable) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome, color: Colors.blue, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      field.fieldType == FieldType.photo ||
                              field.fieldType == FieldType.photoMultiple
                          ? 'AI Í’êgG&ke¯‹M'
                          : 'AI ÔT©kÎdM',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.blue[700],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFieldInputWidget(TemplateField field, dynamic value) {
    void handleChange(dynamic newValue) {
      widget.onFieldChanged(field.fieldId, newValue);

      // WI
      setState(() {
        final error = field.validate(newValue);
        if (error != null) {
          _validationErrors[field.fieldId] = error;
        } else {
          _validationErrors.remove(field.fieldId);
        }

        // ¢ÂfJ
        final warning = field.checkWarning(newValue);
        if (warning != null) {
          _warnings[field.fieldId] = warning;
        } else {
          _warnings.remove(field.fieldId);
        }
      });
    }

    switch (field.fieldType) {
      case FieldType.text:
        return TextFieldInput(
          field: field,
          value: value,
          onChanged: handleChange,
        );

      case FieldType.number:
        return NumberFieldInput(
          field: field,
          value: value,
          onChanged: handleChange,
        );

      case FieldType.radio:
        return RadioFieldInput(
          field: field,
          value: value,
          onChanged: handleChange,
        );

      case FieldType.checkbox:
        return CheckboxFieldInput(
          field: field,
          value: value,
          onChanged: handleChange,
        );

      case FieldType.dropdown:
        return DropdownFieldInput(
          field: field,
          value: value,
          onChanged: handleChange,
        );

      case FieldType.datetime:
      case FieldType.date:
        return DateTimeFieldInput(
          field: field,
          value: value,
          onChanged: handleChange,
        );

      case FieldType.photo:
      case FieldType.photoMultiple:
        return PhotoFieldInput(
          field: field,
          value: value,
          onChanged: handleChange,
          onAIAnalysis: widget.onAIAnalysis,
        );

      case FieldType.textarea:
        return TextAreaFieldInput(
          field: field,
          value: value,
          onChanged: handleChange,
        );

      case FieldType.signature:
        return SignatureFieldInput(
          field: field,
          value: value,
          onChanged: handleChange,
        );

      default:
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text('dM^ã*Ê\${field.fieldType}'),
        );
    }
  }
}
