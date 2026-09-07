import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/wt_capture_session.dart';
import '../models/wt_detection.dart';
import 'blade_ai_service.dart';
import 'blade_analysis_service.dart';
import 'connectivity_service.dart';
import 'database_service.dart';

/// 佇列要用到的資料存取。抽成介面是為了測試——
/// `DatabaseService` 是單例且 `database` getter 會去要平台路徑，
/// 單元測試裡跑不起來。
abstract class BladeAiRetryStore {
  Future<List<WtDetection>> pendingAi({int? limit});
  Future<WtCaptureSession?> session(String sessionId);
  Future<void> save(WtDetection detection);
}

class DbBladeAiRetryStore implements BladeAiRetryStore {
  final DatabaseService _db;
  DbBladeAiRetryStore([DatabaseService? db]) : _db = db ?? DatabaseService();

  @override
  Future<List<WtDetection>> pendingAi({int? limit}) =>
      _db.getWtDetectionsPendingAi(limit: limit);

  @override
  Future<WtCaptureSession?> session(String sessionId) =>
      _db.getWtSession(sessionId);

  @override
  Future<void> save(WtDetection detection) =>
      _db.updateWtDetectionAiResult(detection);
}

/// 一次補跑的結果
class BladeAiRetryOutcome {
  final int completed;

  /// 照片檔已經不在了。**維持待補**而不是丟掉：外接儲存重新掛上就還救得回來，
  /// 而 schema 裡沒有「放棄」這個狀態；掃描本身不打 API，留著不花成本。
  final int missingFile;

  /// AI 呼叫失敗（還是離線、額度用盡、回應壞掉）。維持待補。
  final int failed;

  /// 找不到所屬作業或對應的媒體紀錄（資料不一致，不該發生）
  final int orphaned;

  const BladeAiRetryOutcome({
    this.completed = 0,
    this.missingFile = 0,
    this.failed = 0,
    this.orphaned = 0,
  });

  int get total => completed + missingFile + failed + orphaned;
  bool get didWork => completed > 0;

  @override
  String toString() => 'BladeAiRetryOutcome(completed: $completed, '
      'missingFile: $missingFile, failed: $failed, orphaned: $orphaned)';
}

/// 葉片 AI 解讀的補跑佇列（規格 §6）。
///
/// 離線時 `blade_analysis_service` 會把偵測標成 `geminiOfflinePending`——
/// 演算法的數值都在，只缺 AI 的「這是缺陷還是正常結構」。這支服務在連線恢復
/// 時把那一段補完，沿用 `share_queue_service` 的模式（監聽連線 + 啟動掃一次）。
///
/// 三條不可退化的規則：
///
/// 1. **只補 `human_status = pending` 的。** 人已經確認或駁回過的不能被事後
///    補跑的 AI 改掉等級——那等於推翻簽核。這條在 SQL 層就擋掉了
///    （`getWtDetectionsPendingAi`）。
/// 2. **合併走 `BladeAnalysisService.mergeAlgorithmAndAi`**，與線上分析同一條
///    規則：演算法的 severity 是下限，AI 只能往上加。
/// 3. **失敗一律維持待補**，不寫入半套結果。補跑失敗比留著「演算法數值 +
///    待補標記」更糟的情況只有一種：把它標成完成卻沒有 AI 的判斷。
class BladeAiRetryService {
  static final BladeAiRetryService _instance =
      BladeAiRetryService._internal();
  factory BladeAiRetryService() => _instance;
  BladeAiRetryService._internal();

  /// 一次最多補幾筆。額度是有限的，而一次外業可能留下幾十筆待補——
  /// 一口氣打完可能把當天的配額用光，剩下的下次連線再補。
  static const int defaultBatchLimit = 20;

  final ConnectivityService _connectivity = ConnectivityService();
  StreamSubscription? _subscription;
  bool _isProcessing = false;

  void initialize() {
    _subscription?.cancel();
    _subscription = _connectivity.onConnectivityChanged.listen((isOnline) {
      if (isOnline) processPending();
    });
    _connectivity.checkConnection().then((isOnline) {
      if (isOnline) processPending();
    });
  }

  Future<BladeAiRetryOutcome> processPending({
    int limit = defaultBatchLimit,
    BladeAiRetryStore? store,
    BladeBytesLoader? loadBytes,
    BladeImageAnalyzer? analyzer,
  }) async {
    if (_isProcessing) return const BladeAiRetryOutcome();
    _isProcessing = true;
    try {
      return await retryOnce(
        limit: limit,
        store: store,
        loadBytes: loadBytes,
        analyzer: analyzer,
      );
    } finally {
      _isProcessing = false;
    }
  }

  /// 不看 `_isProcessing` 的版本，測試與手動觸發用。
  static Future<BladeAiRetryOutcome> retryOnce({
    int limit = defaultBatchLimit,
    BladeAiRetryStore? store,
    BladeBytesLoader? loadBytes,
    BladeImageAnalyzer? analyzer,
  }) async {
    final s = store ?? DbBladeAiRetryStore();
    final read = loadBytes ?? _readFile;
    final pending = await s.pendingAi(limit: limit);
    if (pending.isEmpty) return const BladeAiRetryOutcome();

    // 同一場次的偵測共用一筆作業紀錄，先分組省掉 N+1 查詢
    final sessions = <String, WtCaptureSession?>{};
    var completed = 0, missing = 0, failed = 0, orphaned = 0;

    for (final d in pending) {
      // 連「查不到」也快取，否則資料不一致時會對同一個 id 重複查
      if (!sessions.containsKey(d.sessionId)) {
        sessions[d.sessionId] = await s.session(d.sessionId);
      }
      final session = sessions[d.sessionId];

      final path = d.mediaPath;
      if (session == null || path == null) {
        orphaned++;
        continue;
      }
      // 作業裡找不到對應的媒體紀錄時退回一個最小的 WtMedia：檔案還在就仍然
      // 分析得動，只是少了倍率與前緣側的 prompt 上下文——比整筆放棄好
      final media = session.media.firstWhere(
        (m) => m.path == path,
        orElse: () => WtMedia(path: path),
      );

      Uint8List bytes;
      try {
        bytes = await read(path);
      } catch (_) {
        missing++;
        continue;
      }

      try {
        final ai = await BladeAiService.interpret(
          detectionId: d.detectionId,
          sessionId: d.sessionId,
          imageBytes: bytes,
          zoneLabel: zoneLabelOf(d, media),
          bladeLabel: d.blade,
          zone: d.zone,
          mediaPath: path,
          algorithmMetrics: d.metricJson,
          zoom: media.zoom,
          analyzer: analyzer,
        );
        await s.save(BladeAnalysisService.mergeAlgorithmAndAi(d, ai));
        completed++;
      } catch (e) {
        debugPrint('葉片 AI 補跑失敗（${d.detectionId}）：$e');
        failed++;
      }
    }

    final outcome = BladeAiRetryOutcome(
      completed: completed,
      missingFile: missing,
      failed: failed,
      orphaned: orphaned,
    );
    if (outcome.total > 0) debugPrint('葉片 AI 補跑：$outcome');
    return outcome;
  }

  /// 給 AI 的區段標籤。偵測本身只存機器用的 zone key（`mid_LE`），
  /// prompt 要的是人看得懂的敘述。
  static String zoneLabelOf(WtDetection d, WtMedia media) {
    const names = {'root': '根部段', 'mid': '中段', 'tip': '葉尖段'};
    final zone = d.zone ?? '';
    final base = names[zone.replaceAll(RegExp(r'_(LE|TE)$'), '')] ??
        (zone.isEmpty ? '未指定區段' : zone);
    final le = media.leadingEdge;
    if (le == null) return base;
    return '$base前緣（前緣在畫面${le == 'top' ? '上' : '下'}緣）';
  }

  static Future<Uint8List> _readFile(String path) => File(path).readAsBytes();

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}
