import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/wt_asset.dart';
import '../models/wt_capture_session.dart';
import '../models/wt_detection.dart';
import 'blade_report_builder.dart';
import 'database_service.dart';
import 'file_save_service.dart';
import 'pdf_report_service.dart';

/// 葉片報告的產生與分享。
///
/// 抽出來是因為**兩個畫面都要**（完成頁與歷史紀錄），而路徑與檔名規則只該有一份；
/// 兩邊各寫一次的話歷史紀錄匯出的檔案會跑到別的目錄，使用者找不到。
class BladeReportExport {
  BladeReportExport._();

  /// 產生 PDF、寫進 app 文件目錄、記錄路徑，然後開系統分享。
  ///
  /// 回傳寫出的檔案路徑。`pendingShare` 由呼叫端依連線狀態決定——
  /// 這裡不猜：離線佇列的語意屬於 `share_queue_service`。
  static Future<String> exportAndShare({
    required WtAsset asset,
    required WtCaptureSession session,
    required List<WtDetection> detections,
    String? summary,
    bool share = true,
    DatabaseService? db,
  }) async {
    final data = BladeReportBuilder.buildData(
      asset: asset,
      session: session,
      detections: detections,
      summary: summary,
    );
    final bytes = await PdfReportService.build(data);

    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'induspect_exports'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final name = PdfReportService.suggestedFileName(data);
    final path = p.join(dir.path, name);
    await File(path).writeAsBytes(bytes);

    session.reportPath = path;
    await (db ?? DatabaseService()).saveWtSession(session);

    if (share) {
      await FileSaveService.saveAndShare(bytes: bytes, fileName: name);
    }
    return path;
  }
}
