import 'package:flutter/material.dart';
import '../../models/template_field.dart';

class RadioFieldInput extends StatelessWidget {
  final TemplateField field;
  final dynamic value;
  final ValueChanged<String> onChanged;

  const RadioFieldInput({
    Key? key,
    required this.field,
    required this.value,
    required this.onChanged,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: field.options!.map((option) {
        return RadioListTile<String>(
          title: Text(option.label),
          value: option.value,
          groupValue: value?.toString(),
          onChanged: (newValue) {
            if (newValue != null) onChanged(newValue);
          },
          contentPadding: EdgeInsets.zero,
        );
      }).toList(),
    );
  }
}
