import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Mobile 實作：儲存到暫存目錄並開啟系統分享
Future<void> saveFile({
  required Uint8List bytes,
  required String fileName,
}) async {
  final dir = await getTemporaryDirectory();
  final filePath = '${dir.path}/$fileName';
  final file = File(filePath);
  await file.writeAsBytes(bytes);

  await Share.shareXFiles(
    [XFile(filePath)],
    subject: '已回填的定檢表格',
  );
}
