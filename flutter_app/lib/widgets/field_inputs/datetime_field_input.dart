import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/template_field.dart';

class DateTimeFieldInput extends StatelessWidget {
  final TemplateField field;
  final dynamic value;
  final ValueChanged<String> onChanged;

  const DateTimeFieldInput({
    Key? key,
    required this.field,
    required this.value,
    required this.onChanged,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final dateTime = value != null ? DateTime.tryParse(value.toString()) : null;
    final formatter = DateFormat(field.format ?? 'yyyy-MM-dd HH:mm');

    return InkWell(
      onTap: () async {
        final pickedDate = await showDatePicker(
          context: context,
          initialDate: dateTime ?? DateTime.now(),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );

        if (pickedDate != null && field.fieldType == FieldType.datetime) {
          final pickedTime = await showTimePicker(
            context: context,
            initialTime: TimeOfDay.fromDateTime(dateTime ?? DateTime.now()),
          );

          if (pickedTime != null) {
            final combined = DateTime(
              pickedDate.year,
              pickedDate.month,
              pickedDate.day,
              pickedTime.hour,
              pickedTime.minute,
            );
            onChanged(combined.toIso8601String());
          }
        } else if (pickedDate != null) {
          onChanged(pickedDate.toIso8601String());
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Icon(Icons.calendar_today, color: Colors.grey[600]),
            const SizedBox(width: 12),
            Text(
              dateTime != null ? formatter.format(dateTime) : '點擊選擇日期時間',
              style: TextStyle(
                fontSize: 16,
                color: dateTime != null ? Colors.black : Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
