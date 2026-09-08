import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/wt_asset.dart';
import '../models/wt_capture_session.dart';
import '../models/wt_detection.dart';
import 'blade_dataset_service.dart';
import 'database_service.dart';
import 'file_save_service.dart';

class BladeDatasetExportResult {
  final String zipPath;
  final String fileName;
  final int itemCount;
  final int copiedCount;

  /// 檔案已經不在了的筆數（外接儲存拔掉、系統清快取）。
  /// **照樣列進 manifest**——「這張照片曾經存在而且是這個標記」本身是資訊，
  /// 靜靜漏掉會讓語料的統計對不上檢測紀錄。
  final int missingCount;
  final BladeDatasetSummary summary;

  const BladeDatasetExportResult({
    required this.zipPath,
    required this.fileName,
    required this.itemCount,
    required this.copiedCount,
    required this.missingCount,
    required this.summary,
  });
}

/// 把累積下來的拍攝與人工確認打包成可搬走的訓練語料（規格 §9 Phase 4 的前置）。
///
/// 判定與標記規則在 `blade_dataset_service.dart`（純邏輯、測得到）；
/// 這一層只做檔案系統的事：複製、寫 manifest、打包、交給系統分享。
class BladeDatasetExport {
  BladeDatasetExport._();

  /// 預設會把檔案複製進包裡的標記。
  ///
  /// `unreviewed` 與 `unusable` **只進 manifest 不複製檔案**：它們對訓練沒有用，
  /// 而一次外業可能留下幾百張照片、幾百 MB。manifest 仍然完整列出它們，
  /// 這樣「有多少照片還沒人看」看得到，不會變成一個安靜的黑洞。
  static const Set<BladeDatasetLabel> defaultCopyLabels = {
    BladeDatasetLabel.defect,
    BladeDatasetLabel.falsePositive,
    BladeDatasetLabel.humanClean,
  };

  /// 只算統計不匯出。給畫面上的「還差多少」用。
  static Future<BladeDatasetSummary> summarize({DatabaseService? db}) async {
    final data = await _load(db ?? DatabaseService());
    return BladeDatasetService.summarize(
      items: BladeDatasetService.collect(
        sessions: data.sessions,
        detectionsBySession: data.detections,
        assets: data.assets,
      ),
      sessions: data.sessions,
    );
  }

  /// 匯出成 zip 並開系統分享。
  static Future<BladeDatasetExportResult> exportAndShare({
    DatabaseService? db,
    Set<BladeDatasetLabel> copyLabels = defaultCopyLabels,
    bool share = true,
    DateTime? now,
  }) async {
    final data = await _load(db ?? DatabaseService());
    final items = BladeDatasetService.collect(
      sessions: data.sessions,
      detectionsBySession: data.detections,
      assets: data.assets,
    );
    final summary =
        BladeDatasetService.summarize(items: items, sessions: data.sessions);

    final stamp = _stamp(now ?? DateTime.now());
    final appDir = await getApplicationDocumentsDirectory();
    final work = Directory(p.join(appDir.path, 'induspect_dataset', stamp));
    if (await work.exists()) await work.delete(recursive: true);
    await work.create(recursive: true);

    var copied = 0, missing = 0;
    for (final it in items) {
      if (!copyLabels.contains(it.label)) continue;
      final src = File(it.sourcePath);
      if (!await src.exists()) {
        missing++;
        continue;
      }
      final dst = File(p.join(work.path, it.relativePath));
      await dst.parent.create(recursive: true);
      await src.copy(dst.path);
      copied++;
    }

    final manifest = BladeDatasetService.buildManifest(
      items: items,
      summary: summary,
      exportedAt: now,
    );
    await File(p.join(work.path, 'manifest.json')).writeAsString(
        const JsonEncoder.withIndent(' ').convert(manifest),
        flush: true);

    final fileName = 'induspect_blade_dataset_$stamp.zip';
    final zipPath = p.join(appDir.path, 'induspect_exports', fileName);
    await Directory(p.dirname(zipPath)).create(recursive: true);
    // 非同步版：一次外業的照片可能幾百 MB，同步壓縮會把畫面凍住
    await ZipFileEncoder().zipDirectoryAsync(work, filename: zipPath);
    // 工作目錄留著只會佔一份空間，zip 已經是完整的
    await work.delete(recursive: true);

    if (share) {
      await FileSaveService.saveAndShare(
          bytes: await File(zipPath).readAsBytes(), fileName: fileName);
    }
    return BladeDatasetExportResult(
      zipPath: zipPath,
      fileName: fileName,
      itemCount: items.length,
      copiedCount: copied,
      missingCount: missing,
      summary: summary,
    );
  }

  static Future<_DatasetInput> _load(DatabaseService db) async {
    final sessions = await db.getWtSessions();
    final assets = <String, WtAsset>{};
    for (final a in await db.getAllWtAssets()) {
      assets[a.assetId] = a;
    }
    final detections = <String, List<WtDetection>>{};
    for (final s in sessions) {
      detections[s.sessionId] = await db.getWtDetections(s.sessionId);
    }
    return _DatasetInput(sessions, detections, assets);
  }

  static String _stamp(DateTime d) =>
      '${d.year}${_two(d.month)}${_two(d.day)}-${_two(d.hour)}${_two(d.minute)}';

  static String _two(int v) => v.toString().padLeft(2, '0');
}

class _DatasetInput {
  final List<WtCaptureSession> sessions;
  final Map<String, List<WtDetection>> detections;
  final Map<String, WtAsset> assets;

  const _DatasetInput(this.sessions, this.detections, this.assets);
}
