import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:induspect_ai/models/form_inspection_record.dart';
import 'package:induspect_ai/models/wt_asset.dart';
import 'package:induspect_ai/models/wt_capture_session.dart';
import 'package:induspect_ai/services/database_service.dart';
import 'package:induspect_ai/services/share_queue_service.dart';

/// 讓 microtask / event queue 跑完。
///
/// 刻意不用 `pumpEventQueue`：連線事件觸發的處理是 fire-and-forget，
/// 這裡只需要「把佇列跑乾」這一件事，不值得綁在它於各版 test 套件的可見性上。
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 離線分享佇列（Issue #43 的「斷網完成檢測 → 恢復網路 → 自動分享」）
///
/// 這條路以前**一條測試都沒有**，而它錯的方式是靜默的：把不存在的檔案標成
/// 已分享，使用者會以為客戶收到了報告，而畫面上再也不會提醒他重送。
/// 所以這裡守的重點不是「有沒有分享成功」，是**什麼情況下不准標記完成**。
void main() {
  final dbService = DatabaseService();
  final queue = ShareQueueService();

  late Directory tmpDir;
  late List<String> sharedFileNames;
  late List<int> sharedByteLengths;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('induspect_share_queue');
    final handle = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 5, onCreate: dbService.onCreate),
    );
    dbService.attachDatabaseForTesting(handle);

    sharedFileNames = [];
    sharedByteLengths = [];
    queue.resetForTesting();
    queue.betweenShares = Duration.zero;
    queue.shareSinkOverride = ({required Uint8List bytes, required String fileName}) async {
      sharedFileNames.add(fileName);
      sharedByteLengths.add(bytes.length);
    };

    addTearDown(() async {
      queue.resetForTesting();
      dbService.attachDatabaseForTesting(null);
      await handle.close();
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    });
  });

  /// 產生一個真的存在的匯出檔
  Future<String> writeExport(String name, {int bytes = 32}) async {
    final file = File('${tmpDir.path}/$name');
    await file.writeAsBytes(List<int>.filled(bytes, 7));
    return file.path;
  }

  Future<void> addFormRecord({
    required String recordId,
    String? documentPath,
    bool pendingShare = true,
  }) async {
    await dbService.saveFormRecord(FormInspectionRecord(
      recordId: recordId,
      title: '定檢 $recordId',
      filledDocumentPath: documentPath,
      status: FormRecordStatus.completed,
      pendingShare: pendingShare,
    ));
  }

  Future<void> addBladeSession({
    required String sessionId,
    String? reportPath,
    bool pendingShare = true,
  }) async {
    await dbService.saveWtAsset(WtAsset(assetId: 'WTG-$sessionId'));
    await dbService.saveWtSession(WtCaptureSession(
      sessionId: sessionId,
      assetId: 'WTG-$sessionId',
      status: WtSessionStatus.confirmed,
      reportPath: reportPath,
      pendingShare: pendingShare,
    ));
  }

  Future<bool> formStillPending(String recordId) async {
    final all = await dbService.getFormRecordsPendingShare();
    return all.any((r) => r.recordId == recordId);
  }

  Future<bool> bladeStillPending(String sessionId) async {
    final all = await dbService.getWtSessionsPendingShare();
    return all.any((s) => s.sessionId == sessionId);
  }

  group('定檢紀錄', () {
    test('檔案存在 → 送出並標記完成', () async {
      final path = await writeExport('report.xlsx', bytes: 11);
      await addFormRecord(recordId: 'F1', documentPath: path);

      final outcome = await queue.processPendingShares();

      expect(outcome.shared, 1);
      expect(sharedFileNames, ['report.xlsx']);
      expect(sharedByteLengths, [11]);
      expect(await formStillPending('F1'), isFalse);
    });

    test('★ 有路徑但檔案已不存在 → 不送出、**不標記完成**', () async {
      await addFormRecord(recordId: 'F2', documentPath: '${tmpDir.path}/gone.xlsx');

      final outcome = await queue.processPendingShares();

      expect(outcome.skippedMissingFile, 1);
      expect(outcome.shared, 0);
      expect(sharedFileNames, isEmpty);
      // 這是整條佇列最重要的一條：標成已分享，使用者會以為客戶收到了
      expect(await formStillPending('F2'), isTrue,
          reason: '檔案不存在時必須留在佇列裡，等使用者重新匯出');
    });

    test('完全沒有匯出路徑 → 標記完成（沒有東西可分享，否則無限重試）', () async {
      await addFormRecord(recordId: 'F3', documentPath: null);

      final outcome = await queue.processPendingShares();

      expect(outcome.clearedWithoutFile, 1);
      expect(sharedFileNames, isEmpty);
      expect(await formStillPending('F3'), isFalse);
    });

    test('★ 分享動作丟例外 → 不標記完成，且不中斷佇列其餘紀錄', () async {
      final bad = await writeExport('bad.xlsx');
      final good = await writeExport('good.xlsx');
      await addFormRecord(recordId: 'F4', documentPath: bad);
      await addFormRecord(recordId: 'F5', documentPath: good);

      queue.shareSinkOverride = ({required Uint8List bytes, required String fileName}) async {
        if (fileName == 'bad.xlsx') throw StateError('分享面板被取消');
        sharedFileNames.add(fileName);
      };

      final outcome = await queue.processPendingShares();

      expect(outcome.failed, 1);
      expect(outcome.shared, 1);
      expect(sharedFileNames, ['good.xlsx'], reason: '前一筆失敗不能讓後面的不跑');
      expect(await formStillPending('F4'), isTrue, reason: '失敗的要留下來重試');
      expect(await formStillPending('F5'), isFalse);
    });

    test('未標記待分享的紀錄不會被碰到', () async {
      final path = await writeExport('not_queued.xlsx');
      await addFormRecord(recordId: 'F6', documentPath: path, pendingShare: false);

      final outcome = await queue.processPendingShares();

      expect(outcome.isEmpty, isTrue);
      expect(sharedFileNames, isEmpty);
    });
  });

  group('葉片作業（與定檢共用同一條佇列、同一套規則）', () {
    test('報告存在 → 送出並標記完成', () async {
      final path = await writeExport('blade.pdf', bytes: 5);
      await addBladeSession(sessionId: 'S1', reportPath: path);

      final outcome = await queue.processPendingShares();

      expect(outcome.shared, 1);
      expect(sharedFileNames, ['blade.pdf']);
      expect(sharedByteLengths, [5]);
      expect(await bladeStillPending('S1'), isFalse);
    });

    test('★ 報告檔已不存在 → 不標記完成', () async {
      await addBladeSession(sessionId: 'S2', reportPath: '${tmpDir.path}/gone.pdf');

      final outcome = await queue.processPendingShares();

      expect(outcome.skippedMissingFile, 1);
      expect(sharedFileNames, isEmpty);
      expect(await bladeStillPending('S2'), isTrue);
    });

    test('沒產生過報告 → 標記完成', () async {
      await addBladeSession(sessionId: 'S3', reportPath: null);

      final outcome = await queue.processPendingShares();

      expect(outcome.clearedWithoutFile, 1);
      expect(await bladeStillPending('S3'), isFalse);
    });

    test('一次處理同時把定檢與葉片都清掉', () async {
      await addFormRecord(recordId: 'F7', documentPath: await writeExport('f7.xlsx'));
      await addBladeSession(sessionId: 'S4', reportPath: await writeExport('s4.pdf'));

      final outcome = await queue.processPendingShares();

      expect(outcome.shared, 2);
      expect(sharedFileNames, containsAll(['f7.xlsx', 's4.pdf']));
      expect(await formStillPending('F7'), isFalse);
      expect(await bladeStillPending('S4'), isFalse);
    });
  });

  group('連線事件觸發', () {
    test('恢復連線 → 自動清佇列；斷線事件不觸發', () async {
      final events = StreamController<bool>();
      addTearDown(events.close);
      await addFormRecord(recordId: 'F8', documentPath: await writeExport('f8.xlsx'));

      queue.connectivityStreamOverride = events.stream;
      queue.connectionCheckOverride = () async => false; // 啟動時離線
      queue.initialize();
      await settle();
      expect(sharedFileNames, isEmpty, reason: '啟動時離線就不該處理');

      events.add(false);
      await settle();
      expect(queue.lastTriggeredRun, isNull, reason: '斷線事件不是觸發條件');
      expect(sharedFileNames, isEmpty);

      events.add(true);
      await settle();
      final outcome = await queue.lastTriggeredRun;
      expect(outcome?.shared, 1);
      expect(sharedFileNames, ['f8.xlsx']);
      expect(await formStillPending('F8'), isFalse);
    });

    test('啟動時就在線上 → 直接清一次', () async {
      await addFormRecord(recordId: 'F9', documentPath: await writeExport('f9.xlsx'));

      final events = StreamController<bool>();
      addTearDown(events.close);
      queue.connectivityStreamOverride = events.stream;
      queue.connectionCheckOverride = () async => true;
      queue.initialize();
      await settle();

      final outcome = await queue.lastTriggeredRun;
      expect(outcome?.shared, 1);
      expect(sharedFileNames, ['f9.xlsx']);
    });

    test('★ 連續兩個上線事件不會把同一筆送兩次（重入守門）', () async {
      await addFormRecord(recordId: 'F10', documentPath: await writeExport('f10.xlsx'));

      final first = queue.processPendingShares();
      final second = await queue.processPendingShares();
      final firstOutcome = await first;

      expect(second.isEmpty, isTrue, reason: '處理中的第二次呼叫應該直接返回');
      expect(firstOutcome.shared, 1);
      expect(sharedFileNames, ['f10.xlsx']);
    });

    test('dispose 之後連線事件不再觸發', () async {
      final events = StreamController<bool>();
      addTearDown(events.close);
      await addFormRecord(recordId: 'F11', documentPath: await writeExport('f11.xlsx'));

      queue.connectivityStreamOverride = events.stream;
      queue.connectionCheckOverride = () async => false;
      queue.initialize();
      queue.dispose();

      events.add(true);
      await settle();

      expect(sharedFileNames, isEmpty);
      expect(await formStillPending('F11'), isTrue);
    });
  });

  group('ShareQueueOutcome', () {
    test('相加逐欄位累計', () {
      const a = ShareQueueOutcome(shared: 1, failed: 2);
      const b = ShareQueueOutcome(shared: 3, skippedMissingFile: 4, clearedWithoutFile: 5);
      final sum = a + b;

      expect(sum.shared, 4);
      expect(sum.failed, 2);
      expect(sum.skippedMissingFile, 4);
      expect(sum.clearedWithoutFile, 5);
      expect(sum.total, 15);
      expect(sum.isEmpty, isFalse);
      expect(const ShareQueueOutcome().isEmpty, isTrue);
    });
  });
}
