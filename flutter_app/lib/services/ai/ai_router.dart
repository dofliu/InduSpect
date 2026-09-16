import '../../providers/settings_provider.dart';
import '../connectivity_service.dart';
import '../device_info_channel.dart';
import '../gemini_service.dart';
import 'ai_backend.dart';
import 'ai_tier_policy.dart';
import 'gemini_cloud_backend.dart';
import 'gemma_local_backend.dart';
import 'local_model_manager.dart';

/// 這一次分析的決定：走哪一層、用哪個後端（手動時是 null）。
class AiDecision {
  const AiDecision(this.tier, this.backend);
  final AiTier tier;
  final AiBackend? backend;
}

/// 把四個輸入湊齊、交給 `chooseAiTier`、回對應的後端。
///
/// 畫面只叫 `resolve()`；四個輸入各有縫（連線探測、裝置記憶體、雲端建構、端側執行器），
/// 所以整條決策在沒有網路、沒有原生、沒有金鑰的測試環境也走得完。
class AiRouter {
  AiRouter({
    required SettingsProvider settings,
    required LocalModelManager localModels,
    Future<bool> Function()? isOnline,
    Future<int?> Function()? totalRamMb,
    AiBackend? Function()? cloudFactory,
    LocalVlmRunner Function()? localRunnerFactory,
  })  // 具名參數不能用底線開頭，寫不成 this._x；lint 在這裡是誤報。
      // ignore: prefer_initializing_formals
      : _settings = settings,
        // ignore: prefer_initializing_formals
        _localModels = localModels,
        _isOnline = isOnline ?? (() => ConnectivityService().checkConnection()),
        _totalRamMb = totalRamMb ?? DeviceInfoChannel().totalMemoryMb,
        _cloudFactory = cloudFactory ?? (() => _defaultCloud(settings)),
        // ignore: prefer_initializing_formals
        _localRunnerFactory = localRunnerFactory;

  final SettingsProvider _settings;
  final LocalModelManager _localModels;
  final Future<bool> Function() _isOnline;
  final Future<int?> Function() _totalRamMb;
  final AiBackend? Function() _cloudFactory;
  final LocalVlmRunner Function()? _localRunnerFactory;

  int? _ramCache;
  bool _ramQueried = false;

  /// 裝置記憶體只問一次——它不會變。
  Future<bool> deviceEligible() async {
    if (!_ramQueried) {
      _ramCache = await _totalRamMb();
      _ramQueried = true;
    }
    return deviceEligibleForLocalModel(_ramCache);
  }

  int? get totalRamMbCached => _ramCache;

  Future<AiDecision> resolve() async {
    final cloud = _cloudFactory();
    final online = await _isOnline();
    final eligible = await deviceEligible();
    final tier = chooseAiTier(
      online: online,
      cloudConfigured: cloud != null,
      localEnabled: _settings.offlineAiEnabled,
      localModelReady: _localModels.isReady,
      deviceEligible: eligible,
    );
    switch (tier) {
      case AiTier.cloud:
        return AiDecision(tier, cloud);
      case AiTier.localLlm:
        final factory = _localRunnerFactory;
        // 沒有端側執行器（非 Android／測試環境）就退回 OCR，不要假裝有端側。
        if (factory == null) return const AiDecision(AiTier.ocrOnly, null);
        return AiDecision(tier, GemmaLocalBackend(factory()));
      case AiTier.ocrOnly:
      case AiTier.manual:
        return AiDecision(tier, null);
    }
  }

  /// 雲端後端：金鑰來自設定頁（PR #77 之後這是唯一的出口）。沒金鑰回 null。
  static AiBackend? _defaultCloud(SettingsProvider settings) {
    try {
      final service = GeminiService()
        ..init(apiKey: settings.customApiKey, flashModel: settings.selectedModel);
      return GeminiCloudBackend(service);
    } on MissingGeminiKeyException {
      return null;
    } catch (_) {
      return null;
    }
  }
}
