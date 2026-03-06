import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;

// 條件導入：Web 用 html，Mobile 用 io + share_plus
import 'file_save_service_stub.dart'
    if (dart.library.html) 'file_save_service_web.dart'
    if (dart.library.io) 'file_save_service_mobile.dart';

/// 跨平台文件儲存/分享服務
///
/// Web: 觸發瀏覽器下載
/// Mobile: 儲存到暫存目錄並開啟分享
class FileSaveService {
  static Future<void> saveAndShare({
    required Uint8List bytes,
    required String fileName,
  }) async {
    await saveFile(bytes: bytes, fileName: fileName);
  }
}
