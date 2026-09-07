import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/wt_asset.dart';
import '../models/wt_capture_session.dart';
import '../models/wt_detection.dart';
import 'blade_report_builder.dart';
import 'connectivity_service.dart';
import 'database_service.dart';
import 'file_save_service.dart';
import 'pdf_report_service.dart';

/// 葉片報告的產生與分享。
///
/// 抽出來是因為**兩個畫面都要**（完成頁與歷史紀錄），而路徑與檔名規則只該有一份；
/// 兩邊各寫一次的話歷史紀錄匯出的檔案會跑到別的目錄，使用者找不到。
class BladeReportExport {
  BladeReportExport._();

  /// 產生 PDF、寫進 app 文件目錄、記錄路徑，然後**依連線狀態**決定
  /// 現在分享還是排進離線佇列。
  ///
  /// 回傳 `(path, shared)`：`shared` 為 false 表示已排進佇列，
  /// 呼叫端的提示要說「恢復網路後自動分享」而不是「已分享」。
  ///
  /// 原本這裡寫「`pendingShare` 由呼叫端依連線狀態決定」，結果**兩個呼叫端
  /// 都沒有決定**——全 app 沒有任何地方把葉片作業的 `pendingShare` 設為 true，
  /// 於是 `getWtSessionsPendingShare()` 永遠回空、佇列的葉片那半從來沒被觸發過、
  /// 歷史畫面的「待分享」標籤也永遠不會出現。政策搬進來是為了不再有第二個
  /// 忘記決定的呼叫端。
  ///
  /// 離線時**不開分享面板**：面板本身離線也開得起來，但使用者選了 email 或
  /// 通訊軟體之後那封信會卡在寄件匣，而 app 完全不知道，於是他以為已經送出。
  ///
  /// [isOnline]／[outputDir]／[shareSink] 是三個外部邊界的縫（連線狀態、
  /// 檔案位置、平台分享），為了讓上面那個決定測得到——`getApplicationDocumentsDirectory()`
  /// 在單元測試裡會炸，而 `PdfReportService.build` 本身測得起來。
  static Future<({String path, bool shared})> exportAndShare({
    required WtAsset asset,
    required WtCaptureSession session,
    required List<WtDetection> detections,
    String? summary,
    bool share = true,
    DatabaseService? db,
    Future<bool> Function()? isOnline,
    Directory? outputDir,
    ShareSink? shareSink,
  }) async {
    final data = BladeReportBuilder.buildData(
      asset: asset,
      session: session,
      detections: detections,
      summary: summary,
    );
    final bytes = await PdfReportService.build(data);

    // outputDir 給定時完全不碰 path_provider（它在單元測試裡沒有 platform 實作）
    final Directory dir;
    if (outputDir != null) {
      dir = outputDir;
    } else {
      final appDir = await getApplicationDocumentsDirectory();
      dir = Directory(p.join(appDir.path, 'induspect_exports'));
    }
    if (!await dir.exists()) await dir.create(recursive: true);
    final name = PdfReportService.suggestedFileName(data);
    final path = p.join(dir.path, name);
    await File(path).writeAsBytes(bytes);

    session.reportPath = path;

    // 連線狀態要在存檔**之前**決定，pendingShare 才會跟 reportPath 一起落地
    var shared = false;
    if (share) {
      final Future<bool> Function() check =
          isOnline ?? () => ConnectivityService().checkConnection();
      shared = await check();
      session.pendingShare = !shared;
    }
    await (db ?? DatabaseService()).saveWtSession(session);

    if (shared) {
      final ShareSink sink = shareSink ?? FileSaveService.saveAndShare;
      await sink(bytes: bytes, fileName: name);
    }
    return (path: path, shared: shared);
  }
}
