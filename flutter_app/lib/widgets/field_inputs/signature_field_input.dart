import 'package:flutter/material.dart';
import '../../models/template_field.dart';

class SignatureFieldInput extends StatelessWidget {
  final TemplateField field;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;

  const SignatureFieldInput({
    Key? key,
    required this.field,
    required this.value,
    required this.onChanged,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final hasSignature = value != null;

    return Column(
      children: [
        Container(
          height: 200,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey),
            borderRadius: BorderRadius.circular(8),
            color: Colors.grey[100],
          ),
          child: hasSignature
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(Icons.check_circle, color: Colors.green, size: 48),
                      SizedBox(height: 8),
                      Text('已簽名'),
                    ],
                  ),
                )
              : Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.draw, color: Colors.grey[400], size: 48),
                      const SizedBox(height: 8),
                      Text(
                        '點擊下方按鈕開始簽名',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: () => _openSignaturePad(context),
          icon: Icon(hasSignature ? Icons.edit : Icons.draw),
          label: Text(hasSignature ? '重新簽名' : '開始簽名'),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 16,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openSignaturePad(BuildContext context) async {
    // TODO: 實作簽名板功能
    // 需要使用 signature package
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('簽名功能開發中...')),
    );

    // 暫時模擬簽名完成
    onChanged({
      'signed': true,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }
}
