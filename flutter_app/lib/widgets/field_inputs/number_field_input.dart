import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/template_field.dart';

class NumberFieldInput extends StatelessWidget {
  final TemplateField field;
  final dynamic value;
  final ValueChanged<double?> onChanged;

  const NumberFieldInput({
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
        suffixText: field.unit,
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
      ],
      onChanged: (text) {
        if (text.isEmpty) {
          onChanged(null);
        } else {
          final number = double.tryParse(text);
          onChanged(number);
        }
      },
    );
  }
}
