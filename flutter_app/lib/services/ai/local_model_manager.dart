import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ai_tier_policy.dart';

enum LocalModelState { notInstalled, installing, ready, failed }

/// 安裝動作的形狀：來源（檔案路徑或 URL）→ 完成。進度 0–100 回呼。
/// `flutter_gemma` 的實作在 `flutter_gemma_runner.dart`；測試餵假的。
typedef LocalModelInstaller = Future<void> Function(
  LocalModelSource source, {
  void Function(int percent)? onProgress,
});
typedef LocalModelProbe = Future<bool> Function(String modelId);
typedef LocalModelRemover = Future<void> Function(String modelId);

class LocalModelSource {
  const LocalModelSource.file(this.path)
      : url = null,
        token = null;
  const LocalModelSource.network(this.url, {this.token}) : path = null;
  final String? path;
  final String? url;
  final String? token;
  bool get isFile => path != null;
}

/// 端側模型的生命週期：裝了沒、正在裝、裝壞了。
///
/// 它不決定「要不要用」——那是 `chooseAiTier` 的事；也不碰 UI。
/// 三個縫（installer／probe／remover）讓它在沒有原生的地方也測得到。
class LocalModelManager extends ChangeNotifier {
  LocalModelManager({
    required LocalModelInstaller installer,
    required LocalModelProbe probe,
    required LocalModelRemover remover,
    this.modelId = LocalModelRequirements.modelId,
  })  // 具名參數不能用底線開頭，所以無法寫成 this._installer；lint 在這裡是誤報。
      // ignore: prefer_initializing_formals
      : _installer = installer,
        // ignore: prefer_initializing_formals
        _probe = probe,
        // ignore: prefer_initializing_formals
        _remover = remover;

  final LocalModelInstaller _installer;
  final LocalModelProbe _probe;
  final LocalModelRemover _remover;
  final String modelId;

  LocalModelState _state = LocalModelState.notInstalled;
  int _progress = 0;
  String? _error;

  LocalModelState get state => _state;
  int get progress => _progress;
  String? get error => _error;
  bool get isReady => _state == LocalModelState.ready;

  /// 啟動時問一次原生：模型在不在。
  Future<void> refresh() async {
    try {
      final installed = await _probe(modelId);
      _set(installed ? LocalModelState.ready : LocalModelState.notInstalled);
    } catch (e) {
      _error = e.toString();
      _set(LocalModelState.failed);
    }
  }

  /// 裝模型。同時只允許一個安裝在跑；失敗把原因留著讓設定頁顯示。
  Future<bool> install(LocalModelSource source) async {
    if (_state == LocalModelState.installing) return false;
    _error = null;
    _progress = 0;
    _set(LocalModelState.installing);
    try {
      await _installer(source, onProgress: (p) {
        _progress = p.clamp(0, 100);
        notifyListeners();
      });
      _progress = 100;
      _set(LocalModelState.ready);
      return true;
    } catch (e) {
      _error = e.toString();
      _set(LocalModelState.failed);
      return false;
    }
  }

  Future<void> remove() async {
    try {
      await _remover(modelId);
    } finally {
      _progress = 0;
      _set(LocalModelState.notInstalled);
    }
  }

  void _set(LocalModelState s) {
    _state = s;
    notifyListeners();
  }
}
