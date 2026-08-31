import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// Service to monitor network connectivity status
class ConnectivityService {
  static final ConnectivityService _instance = ConnectivityService._internal();
  factory ConnectivityService() => _instance;
  ConnectivityService._internal();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<ConnectivityResult>? _subscription;

  bool _isOnline = false;

  /// 網路「介面」是否連線（WiFi/行動網路已連上，但不代表真的能通到外網）
  bool get isOnline => _isOnline;

  // ── 可達性探測（廠區常見「連上 AP 但沒有 uplink」/ captive portal）──
  // 只看介面狀態會誤判為 online，於是每次呼叫都要等逾時（後端 10s+30s、
  // Gemini 60s）才降級。改為主動探測後端 /health，不通就立刻走離線路徑。
  static const Duration probeTimeout = Duration(seconds: 3);
  static const Duration probeCacheTtl = Duration(seconds: 10);

  DateTime? _lastProbeAt;
  bool _lastProbeOk = false;

  /// 最近一次探測是否成功（未探測過為 null）
  bool? get lastProbeOk => _lastProbeAt == null ? null : _lastProbeOk;

  /// 測試用：覆寫實際的 HTTP 探測
  @visibleForTesting
  Future<bool> Function(Uri uri)? probeOverride;

  /// 測試用：覆寫「網路介面」狀態檢查（單元測試環境沒有 connectivity plugin）
  @visibleForTesting
  Future<bool> Function()? interfaceCheckOverride;

  /// 測試用：清除探測快取
  @visibleForTesting
  void resetProbeCache() {
    _lastProbeAt = null;
    _lastProbeOk = false;
  }

  /// 探測目標；未設定 BACKEND_API_URL 時回傳 null（無從探測）
  Uri? get probeUri {
    String? base;
    try {
      base = dotenv.env['BACKEND_API_URL'];
    } catch (_) {
      // dotenv 未初始化（例如單元測試）→ 視為未設定
      return null;
    }
    if (base == null || base.trim().isEmpty) return null;
    final trimmed = base.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.tryParse('$trimmed/health');
  }

  // Stream controller for connectivity changes
  final _connectivityController = StreamController<bool>.broadcast();
  Stream<bool> get onConnectivityChanged => _connectivityController.stream;

  /// Initialize connectivity monitoring
  Future<void> initialize() async {
    // Check initial connectivity
    await _updateConnectivityStatus();

    // Listen to connectivity changes
    _subscription = _connectivity.onConnectivityChanged.listen((result) {
      _handleConnectivityChange(result);
    });
  }

  /// Update connectivity status
  Future<void> _updateConnectivityStatus() async {
    try {
      final result = await _connectivity.checkConnectivity();
      _handleConnectivityChange(result);
    } catch (e) {
      debugPrint('Error checking connectivity: $e');
      _isOnline = false;
    }
  }

  /// Handle connectivity change
  void _handleConnectivityChange(ConnectivityResult result) {
    final wasOnline = _isOnline;
    _isOnline = result != ConnectivityResult.none;

    debugPrint('Connectivity changed: $result, isOnline: $_isOnline');

    // Notify listeners if status changed
    if (wasOnline != _isOnline) {
      _connectivityController.add(_isOnline);

      if (_isOnline) {
        debugPrint('Internet connection restored');
      } else {
        debugPrint('Internet connection lost');
      }
    }
  }

  /// 是否「真的」可以連到後端。
  ///
  /// 1. 介面就斷了 → 直接 false（不浪費時間探測）
  /// 2. 未設定 BACKEND_API_URL → 無法探測，退回介面判定（維持舊行為）
  /// 3. 否則探測 `<BACKEND_API_URL>/health`（逾時 3 秒，結果快取 10 秒）
  ///
  /// 快取避免批次分析時每張照片都探測一次；[forceProbe] 可略過快取。
  Future<bool> checkConnection({bool forceProbe = false}) async {
    final interfaceOverride = interfaceCheckOverride;
    if (interfaceOverride != null) {
      _isOnline = await interfaceOverride();
    } else {
      await _updateConnectivityStatus();
    }
    if (!_isOnline) return false;

    final uri = probeUri;
    if (uri == null) return true;

    final now = DateTime.now();
    if (!forceProbe &&
        _lastProbeAt != null &&
        now.difference(_lastProbeAt!) < probeCacheTtl) {
      return _lastProbeOk;
    }

    _lastProbeOk = await _probe(uri);
    _lastProbeAt = now;
    if (!_lastProbeOk) {
      debugPrint('可達性探測失敗（介面已連線但無法連到後端）: $uri');
    }
    return _lastProbeOk;
  }

  Future<bool> _probe(Uri uri) async {
    final override = probeOverride;
    try {
      if (override != null) return await override(uri).timeout(probeTimeout);
      final resp = await http.get(uri).timeout(probeTimeout);
      // 5xx 代表後端本身有問題，同樣視為不可用
      return resp.statusCode < 500;
    } catch (e) {
      return false;
    }
  }

  /// Dispose resources
  void dispose() {
    _subscription?.cancel();
    _connectivityController.close();
  }
}
