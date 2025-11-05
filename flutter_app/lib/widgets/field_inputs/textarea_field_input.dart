import 'package:flutter/material.dart';
import '../../models/template_field.dart';

class TextAreaFieldInput extends StatelessWidget {
  final TemplateField field;
  final dynamic value;
  final ValueChanged<String> onChanged;

  const TextAreaFieldInput({
    Key? key,
    required this.field,
    required this.value,
    required this.onChanged,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: TextEditingController(text: value?.toString() ?? ''),
      decoration: InputDecoration(
        hintText: field.placeholder,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.all(16),
      ),
      maxLength: field.maxLength,
      maxLines: field.rows ?? 4,
      onChanged: onChanged,
    );
  }
}
