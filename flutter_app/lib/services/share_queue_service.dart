import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../services/connectivity_service.dart';
import '../services/database_service.dart';
import '../services/file_save_service.dart';

/// 一次佇列處理的結果。
///
/// 原本只有 `debugPrint`，於是「檔案不存在時**不標記完成**」這條規則沒有任何
/// 地方驗得到——而它錯的方式是靜默的：把不存在的檔案標成已分享，使用者會
/// 以為客戶收到了報告。回傳計數讓這條規則有東西可以斷言。
class ShareQueueOutcome {
  /// 成功送出並標記完成
  final int shared;

  /// 有路徑但檔案不存在 → 跳過且**不**標記完成（等使用者重新匯出）
  final int skippedMissingFile;

  /// 完全沒有匯出路徑 → 沒有東西可分享，標記完成以免無限重試
  final int clearedWithoutFile;

  /// 分享動作本身丟例外 → 不標記完成，下次連線再試
  final int failed;

  const ShareQueueOutcome({
    this.shared = 0,
    this.skippedMissingFile = 0,
    this.clearedWithoutFile = 0,
    this.failed = 0,
  });

  ShareQueueOutcome operator +(ShareQueueOutcome other) => ShareQueueOutcome(
        shared: shared + other.shared,
        skippedMissingFile: skippedMissingFile + other.skippedMissingFile,
        clearedWithoutFile: clearedWithoutFile + other.clearedWithoutFile,
        failed: failed + other.failed,
      );

  int get total => shared + skippedMissingFile + clearedWithoutFile + failed;

  bool get isEmpty => total == 0;

  @override
  String toString() => 'ShareQueueOutcome(shared: $shared, '
      'skippedMissingFile: $skippedMissingFile, '
      'clearedWithoutFile: $clearedWithoutFile, failed: $failed)';
}

/// 離線分享佇列服務
///
/// 監聽網路連線狀態，當恢復連線時自動處理標記為 pendingShare 的紀錄——
/// **定檢表單與葉片作業兩種都處理**（葉片作業的欄位語意刻意做成一樣：
/// `pending_share` + `report_path`，就是為了共用這條佇列，不另寫一套）。
class ShareQueueService {
  static final ShareQueueService _instance = ShareQueueService._internal();
  factory ShareQueueService() => _instance;
  ShareQueueService._internal();

  final DatabaseService _dbService = DatabaseService();
  final ConnectivityService _connectivity = ConnectivityService();
  StreamSubscription? _subscription;
  bool _isProcessing = false;

  /// 兩次分享之間的間隔：連續叫起系統分享面板會互相取消。
  /// 測試把它設成 zero，否則每一筆都要真的等 500 ms。
  @visibleForTesting
  Duration betweenShares = const Duration(milliseconds: 500);

  /// 測試用：覆寫連線狀態來源（單元測試環境沒有 connectivity plugin）
  @visibleForTesting
  Stream<bool>? connectivityStreamOverride;

  /// 測試用：覆寫啟動時的連線檢查
  @visibleForTesting
  Future<bool> Function()? connectionCheckOverride;

  /// 測試用：覆寫實際的分享動作
  @visibleForTesting
  ShareSink? shareSinkOverride;

  /// 最近一次由連線事件（或啟動檢查）觸發的處理。
  /// 測試用來等它跑完——那條路是 fire-and-forget，外面沒有 future 可以 await。
  @visibleForTesting
  Future<ShareQueueOutcome>? lastTriggeredRun;

  ShareSink get _share => shareSinkOverride ?? FileSaveService.saveAndShare;

  /// 初始化：監聽連線狀態變化
  void initialize() {
    _subscription?.cancel();
    final Stream<bool> stream =
        connectivityStreamOverride ?? _connectivity.onConnectivityChanged;
    _subscription = stream.listen((isOnline) {
      if (isOnline) lastTriggeredRun = processPendingShares();
    });

    // 啟動時也嘗試處理
    final Future<bool> Function() check =
        connectionCheckOverride ?? () => _connectivity.checkConnection();
    check().then((isOnline) {
      if (isOnline) lastTriggeredRun = processPendingShares();
    });
  }

  /// 處理所有待分享的紀錄（定檢 + 葉片）
  ///
  /// 已在處理中時直接回傳空結果——連線事件可能連續來好幾個，
  /// 重入會讓同一筆被分享兩次。
  Future<ShareQueueOutcome> processPendingShares() async {
    if (_isProcessing) return const ShareQueueOutcome();
    _isProcessing = true;

    try {
      final forms = await _processFormRecords();
      final blades = await _processBladeSessions();
      return forms + blades;
    } finally {
      _isProcessing = false;
    }
  }

  Future<ShareQueueOutcome> _processFormRecords() async {
    var outcome = const ShareQueueOutcome();
    try {
      final pendingRecords = await _dbService.getFormRecordsPendingShare();

      for (final record in pendingRecords) {
        try {
          // Issue #18: 嘗試分享已匯出的檔案，檔案不存在時跳過（不標記完成）
          if (record.filledDocumentPath != null) {
            final file = File(record.filledDocumentPath!);
            if (await file.exists()) {
              await _share(
                bytes: await file.readAsBytes(),
                fileName: p.basename(file.path),
              );
              // 分享成功，標記完成
              await _dbService.markFormShareComplete(record.recordId);
              outcome += const ShareQueueOutcome(shared: 1);
              debugPrint('已完成待分享紀錄: ${record.title}');
            } else {
              debugPrint('檔案已不存在，跳過分享: ${record.filledDocumentPath}');
              // 檔案不存在不標記完成，等使用者重新匯出
              outcome += const ShareQueueOutcome(skippedMissingFile: 1);
            }
          } else {
            // 無匯出路徑，無法分享，標記完成以避免無限重試
            await _dbService.markFormShareComplete(record.recordId);
            outcome += const ShareQueueOutcome(clearedWithoutFile: 1);
            debugPrint('紀錄無匯出路徑，跳過: ${record.title}');
          }
        } catch (e) {
          debugPrint('分享紀錄失敗 (${record.recordId}): $e');
          // 個別失敗不中斷整個佇列
          outcome += const ShareQueueOutcome(failed: 1);
        }

        // 避免過快連續分享
        await Future.delayed(betweenShares);
      }
    } catch (e) {
      debugPrint('處理待分享佇列失敗: $e');
    }
    return outcome;
  }

  /// 葉片作業的待分享。與定檢同一套規則：檔案不存在**不標記完成**，
  /// 等使用者重新匯出——把不存在的檔案標成已分享，使用者會以為客戶收到了。
  Future<ShareQueueOutcome> _processBladeSessions() async {
    var outcome = const ShareQueueOutcome();
    try {
      final pending = await _dbService.getWtSessionsPendingShare();
      for (final session in pending) {
        try {
          final path = session.reportPath;
          if (path == null) {
            // 沒產生過報告就沒有東西可分享，標記完成以免無限重試
            await _dbService.markWtShareComplete(session.sessionId);
            outcome += const ShareQueueOutcome(clearedWithoutFile: 1);
            debugPrint('葉片作業無報告路徑，跳過: ${session.sessionId}');
            continue;
          }
          final file = File(path);
          if (!await file.exists()) {
            debugPrint('葉片報告已不存在，跳過分享: $path');
            outcome += const ShareQueueOutcome(skippedMissingFile: 1);
            continue;
          }
          await _share(
            bytes: await file.readAsBytes(),
            fileName: p.basename(path),
          );
          await _dbService.markWtShareComplete(session.sessionId);
          outcome += const ShareQueueOutcome(shared: 1);
          debugPrint('已完成待分享的葉片作業: ${session.sessionId}');
        } catch (e) {
          debugPrint('分享葉片作業失敗 (${session.sessionId}): $e');
          outcome += const ShareQueueOutcome(failed: 1);
        }
        await Future.delayed(betweenShares);
      }
    } catch (e) {
      debugPrint('處理葉片待分享佇列失敗: $e');
    }
    return outcome;
  }

  /// 停止監聽
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }

  /// 測試用：卸下所有覆寫並停止監聽（singleton 的狀態會跨測試殘留）
  @visibleForTesting
  void resetForTesting() {
    dispose();
    connectivityStreamOverride = null;
    connectionCheckOverride = null;
    shareSinkOverride = null;
    lastTriggeredRun = null;
    betweenShares = const Duration(milliseconds: 500);
    _isProcessing = false;
  }
}
