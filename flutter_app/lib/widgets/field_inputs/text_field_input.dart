import 'package:flutter/material.dart';
import '../../models/template_field.dart';

class TextFieldInput extends StatelessWidget {
  final TemplateField field;
  final dynamic value;
  final ValueChanged<String> onChanged;

  const TextFieldInput({
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
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
      ),
      maxLength: field.maxLength,
      onChanged: onChanged,
    );
  }
}
