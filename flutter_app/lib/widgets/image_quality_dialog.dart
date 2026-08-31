import 'package:flutter/material.dart';

import '../services/image_quality_service.dart';

/// 拍照品質不佳時的提醒對話框。
///
/// 回傳 true 表示使用者選擇「重拍」；false / null 表示仍要使用這張。
/// 刻意不強制擋下——現場可能就是拍不到更好的角度，最終決定權留給使用者，
/// 但會把問題與具體建議講清楚。
Future<bool> showImageQualityWarning(
  BuildContext context,
  ImageQualityReport report,
) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.blur_on, color: Colors.orange, size: 32),
      title: const Text('照片品質提醒'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...report.issues.map(
            (issue) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2, right: 8),
                    child: Icon(Icons.warning_amber_rounded,
                        size: 18, color: Colors.orange),
                  ),
                  Expanded(child: Text(issue.advice)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            report.metrics,
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('仍要使用'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(ctx, true),
          icon: const Icon(Icons.camera_alt, size: 18),
          label: const Text('重拍'),
        ),
      ],
    ),
  );
  return result ?? false;
}
