import 'package:flutter/material.dart';
import '../../models/template_field.dart';

class CheckboxFieldInput extends StatelessWidget {
  final TemplateField field;
  final dynamic value;
  final ValueChanged<List<String>> onChanged;

  const CheckboxFieldInput({
    Key? key,
    required this.field,
    required this.value,
    required this.onChanged,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final selectedValues = value is List
        ? List<String>.from(value)
        : <String>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: field.options!.map((option) {
        final isChecked = selectedValues.contains(option.value);

        return CheckboxListTile(
          title: Text(option.label),
          value: isChecked,
          onChanged: (checked) {
            final newValues = List<String>.from(selectedValues);
            if (checked == true) {
              newValues.add(option.value);
            } else {
              newValues.remove(option.value);
            }
            onChanged(newValues);
          },
          contentPadding: EdgeInsets.zero,
        );
      }).toList(),
    );
  }
}
