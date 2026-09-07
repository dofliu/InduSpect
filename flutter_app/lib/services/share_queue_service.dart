import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../services/database_service.dart';
import '../services/file_save_service.dart';
import '../services/connectivity_service.dart';

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

  /// 初始化：監聽連線狀態變化
  void initialize() {
    _subscription?.cancel();
    _subscription = _connectivity.onConnectivityChanged.listen((isOnline) {
      if (isOnline) {
        processPendingShares();
      }
    });

    // 啟動時也嘗試處理
    _connectivity.checkConnection().then((isOnline) {
      if (isOnline) processPendingShares();
    });
  }

  /// 處理所有待分享的紀錄（定檢 + 葉片）
  Future<void> processPendingShares() async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      await _processFormRecords();
      await _processBladeSessions();
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _processFormRecords() async {
    try {
      final pendingRecords = await _dbService.getFormRecordsPendingShare();

      for (final record in pendingRecords) {
        try {
          // Issue #18: 嘗試分享已匯出的檔案，檔案不存在時跳過（不標記完成）
          if (record.filledDocumentPath != null) {
            final file = File(record.filledDocumentPath!);
            if (await file.exists()) {
              await FileSaveService.saveAndShare(
                bytes: await file.readAsBytes(),
                fileName: p.basename(file.path),
              );
              // 分享成功，標記完成
              await _dbService.markFormShareComplete(record.recordId);
              debugPrint('已完成待分享紀錄: ${record.title}');
            } else {
              debugPrint('檔案已不存在，跳過分享: ${record.filledDocumentPath}');
              // 檔案不存在不標記完成，等使用者重新匯出
            }
          } else {
            // 無匯出路徑，無法分享，標記完成以避免無限重試
            await _dbService.markFormShareComplete(record.recordId);
            debugPrint('紀錄無匯出路徑，跳過: ${record.title}');
          }
        } catch (e) {
          debugPrint('分享紀錄失敗 (${record.recordId}): $e');
          // 個別失敗不中斷整個佇列
        }

        // 避免過快連續分享
        await Future.delayed(const Duration(milliseconds: 500));
      }
    } catch (e) {
      debugPrint('處理待分享佇列失敗: $e');
    }
  }

  /// 葉片作業的待分享。與定檢同一套規則：檔案不存在**不標記完成**，
  /// 等使用者重新匯出——把不存在的檔案標成已分享，使用者會以為客戶收到了。
  Future<void> _processBladeSessions() async {
    try {
      final pending = await _dbService.getWtSessionsPendingShare();
      for (final session in pending) {
        try {
          final path = session.reportPath;
          if (path == null) {
            // 沒產生過報告就沒有東西可分享，標記完成以免無限重試
            await _dbService.markWtShareComplete(session.sessionId);
            debugPrint('葉片作業無報告路徑，跳過: ${session.sessionId}');
            continue;
          }
          final file = File(path);
          if (!await file.exists()) {
            debugPrint('葉片報告已不存在，跳過分享: $path');
            continue;
          }
          await FileSaveService.saveAndShare(
            bytes: await file.readAsBytes(),
            fileName: p.basename(path),
          );
          await _dbService.markWtShareComplete(session.sessionId);
          debugPrint('已完成待分享的葉片作業: ${session.sessionId}');
        } catch (e) {
          debugPrint('分享葉片作業失敗 (${session.sessionId}): $e');
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
    } catch (e) {
      debugPrint('處理葉片待分享佇列失敗: $e');
    }
  }

  /// 停止監聽
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}
