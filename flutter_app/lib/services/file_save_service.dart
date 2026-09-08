import 'dart:typed_data';

// 條件導入：Web 用 html，Mobile 用 io + share_plus
import 'file_save_service_stub.dart'
    if (dart.library.html) 'file_save_service_web.dart'
    if (dart.library.io) 'file_save_service_mobile.dart';

/// 實際把檔案送出去的動作。
///
/// 抽成 typedef 是為了測得到：`FileSaveService.saveAndShare` 是 static，
/// 測試時沒有縫可以換，於是「離線就排進佇列、上線才真的送出」這條規則
/// 在單元測試裡碰不到。
typedef ShareSink = Future<void> Function({
  required Uint8List bytes,
  required String fileName,
});

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
