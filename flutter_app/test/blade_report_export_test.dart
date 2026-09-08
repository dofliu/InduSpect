import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:induspect_ai/models/wt_asset.dart';
import 'package:induspect_ai/models/wt_capture_session.dart';
import 'package:induspect_ai/services/blade_report_export.dart';
import 'package:induspect_ai/services/database_service.dart';
import 'package:induspect_ai/services/share_queue_service.dart';

/// 葉片報告的離線交付。
///
/// 守的是一個**已經出貨的缺口**：`exportAndShare` 原本註解寫著
/// 「`pendingShare` 由呼叫端依連線狀態決定」，而兩個呼叫端都沒有決定
/// ——全 app 沒有任何地方把葉片作業的 `pendingShare` 設為 true，於是
/// `getWtSessionsPendingShare()` 永遠回空、離線佇列的葉片那半從來沒被觸發過、
/// 歷史畫面的「待分享」標籤也永遠不會出現。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // PdfReportService 要載字型 asset

  final dbService = DatabaseService();
  final queue = ShareQueueService();

  late Directory tmpDir;
  late List<String> sharedFileNames;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('induspect_blade_export');
    final handle = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 5, onCreate: dbService.onCreate),
    );
    dbService.attachDatabaseForTesting(handle);
    sharedFileNames = [];
    queue.resetForTesting();
    queue.betweenShares = Duration.zero;

    addTearDown(() async {
      queue.resetForTesting();
      dbService.attachDatabaseForTesting(null);
      await handle.close();
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    });
  });

  final asset = WtAsset(assetId: 'WTG-07', siteName: '彰濱風場', rotorDiameterM: 150);

  WtCaptureSession newSession() => WtCaptureSession(
        sessionId: 'sess-1',
        assetId: 'WTG-07',
        capturedAt: DateTime(2026, 9, 20, 9, 40),
        status: WtSessionStatus.confirmed,
        media: [],
      );

  Future<void> recordSink({required Uint8List bytes, required String fileName}) async {
    sharedFileNames.add(fileName);
  }

  test('上線：真的送出、pendingShare 清掉、reportPath 落地', () async {
    final session = newSession();
    await dbService.saveWtAsset(asset);
    await dbService.saveWtSession(session);

    final r = await BladeReportExport.exportAndShare(
      asset: asset,
      session: session,
      detections: const [],
      db: dbService,
      isOnline: () async => true,
      outputDir: tmpDir,
      shareSink: recordSink,
    );

    expect(r.shared, isTrue);
    expect(sharedFileNames, hasLength(1));
    expect(await File(r.path).exists(), isTrue);

    final stored = await dbService.getWtSession('sess-1');
    expect(stored!.pendingShare, isFalse);
    expect(stored.reportPath, r.path);
    expect(await dbService.getWtSessionsPendingShare(), isEmpty);
  });

  test('★ 離線：不開分享面板，改標記待分享（這一段以前完全沒有人做）', () async {
    final session = newSession();
    await dbService.saveWtAsset(asset);
    await dbService.saveWtSession(session);

    final r = await BladeReportExport.exportAndShare(
      asset: asset,
      session: session,
      detections: const [],
      db: dbService,
      isOnline: () async => false,
      outputDir: tmpDir,
      shareSink: recordSink,
    );

    expect(r.shared, isFalse);
    expect(sharedFileNames, isEmpty, reason: '離線不該開分享面板');

    final stored = await dbService.getWtSession('sess-1');
    expect(stored!.pendingShare, isTrue);
    expect(stored.reportPath, r.path);

    final pending = await dbService.getWtSessionsPendingShare();
    expect(pending.map((s) => s.sessionId), ['sess-1'],
        reason: '佇列必須看得到它，否則整條離線交付是死的');
  });

  test('★ 離線匯出 → 恢復連線 → 佇列真的把報告送出去（Issue #43 第二項的整條路）',
      () async {
    final session = newSession();
    await dbService.saveWtAsset(asset);
    await dbService.saveWtSession(session);

    final exported = await BladeReportExport.exportAndShare(
      asset: asset,
      session: session,
      detections: const [],
      db: dbService,
      isOnline: () async => false,
      outputDir: tmpDir,
      shareSink: recordSink,
    );
    expect(sharedFileNames, isEmpty);

    // 恢復連線：佇列接手
    queue.shareSinkOverride = recordSink;
    final outcome = await queue.processPendingShares();

    expect(outcome.shared, 1);
    expect(sharedFileNames, hasLength(1));
    expect(sharedFileNames.single, endsWith('.pdf'));
    expect(await dbService.getWtSessionsPendingShare(), isEmpty);
    // 佇列送的必須是那個真的存在的檔案——檔案不存在時它會跳過而不標記完成
    expect(await File(exported.path).exists(), isTrue);
  });

  test('share: false 只產生檔案，不問連線也不動 pendingShare', () async {
    final session = newSession();
    await dbService.saveWtAsset(asset);
    await dbService.saveWtSession(session);

    var connectivityAsked = false;
    final r = await BladeReportExport.exportAndShare(
      asset: asset,
      session: session,
      detections: const [],
      share: false,
      db: dbService,
      isOnline: () async {
        connectivityAsked = true;
        return true;
      },
      outputDir: tmpDir,
      shareSink: recordSink,
    );

    expect(connectivityAsked, isFalse);
    expect(r.shared, isFalse);
    expect(sharedFileNames, isEmpty);
    expect(await File(r.path).exists(), isTrue);
    expect((await dbService.getWtSession('sess-1'))!.pendingShare, isFalse);
  });
}
