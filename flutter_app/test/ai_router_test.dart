import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/models/analysis_result.dart';
import 'package:induspect_ai/providers/settings_provider.dart';
import 'package:induspect_ai/services/ai/ai_backend.dart';
import 'package:induspect_ai/services/ai/ai_router.dart';
import 'package:induspect_ai/services/ai/ai_tier_policy.dart';
import 'package:induspect_ai/services/ai/local_model_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeCloud implements AiBackend {
  @override
  AiSource get source => AiSource.cloud;
  @override
  Future<AnalysisResult> analyzeInspectionPhoto({required String itemId, required String itemDescription, required Uint8List imageBytes, required String photoPath}) async => AnalysisResult(itemId: itemId);
  @override
  Future<String> generateSummaryReport(String recordsJson) async => '';
  @override
  Future<Map<String, dynamic>> analyzeImageWithPrompt({required String prompt, required Uint8List imageBytes, String mimeType = 'image/jpeg'}) async => {};
}

/// 整條決策在沒有網路、沒有原生、沒有金鑰的環境走到底。
void main() {
  Future<SettingsProvider> settings({bool offlineAi = true}) async {
    SharedPreferences.setMockInitialValues({'offline_ai_enabled': offlineAi});
    final s = SettingsProvider();
    await s.init();
    return s;
  }

  LocalModelManager models({bool installed = true}) => LocalModelManager(
        installer: (s, {onProgress}) async {},
        probe: (_) async => installed,
        remover: (_) async {},
      );

  test('連得上且有雲端 → 雲端後端', () async {
    final r = AiRouter(
      settings: await settings(),
      localModels: models(),
      isOnline: () async => true,
      totalRamMb: () async => 8000,
      cloudFactory: () => _FakeCloud(),
      localRunnerFactory: () => ({required prompt, imageBytes}) async => '{}',
    );
    final d = await r.resolve();
    expect(d.tier, AiTier.cloud);
    expect(d.backend?.source, AiSource.cloud);
  });

  test('離線、端側就位、裝置夠 → 端側後端', () async {
    final m = models();
    await m.refresh();
    final r = AiRouter(
      settings: await settings(),
      localModels: m,
      isOnline: () async => false,
      totalRamMb: () async => 8000,
      cloudFactory: () => _FakeCloud(),
      localRunnerFactory: () => ({required prompt, imageBytes}) async => '{}',
    );
    final d = await r.resolve();
    expect(d.tier, AiTier.localLlm);
    expect(d.backend?.source, AiSource.localLlm);
  });

  test('離線、端側就位、但這個平台沒有執行器 → 退回 OCR 不假裝', () async {
    final m = models();
    await m.refresh();
    final r = AiRouter(
      settings: await settings(),
      localModels: m,
      isOnline: () async => false,
      totalRamMb: () async => 8000,
      cloudFactory: () => _FakeCloud(),
      localRunnerFactory: null,
    );
    final d = await r.resolve();
    expect(d.tier, AiTier.ocrOnly);
    expect(d.backend, isNull);
  });

  test('離線、查不到記憶體 → OCR（不猜）', () async {
    final m = models();
    await m.refresh();
    final r = AiRouter(
      settings: await settings(),
      localModels: m,
      isOnline: () async => false,
      totalRamMb: () async => null,
      cloudFactory: () => _FakeCloud(),
      localRunnerFactory: () => ({required prompt, imageBytes}) async => '{}',
    );
    expect((await r.resolve()).tier, AiTier.ocrOnly);
  });

  test('連得上但沒金鑰、端側就位 → 端側頂上', () async {
    final m = models();
    await m.refresh();
    final r = AiRouter(
      settings: await settings(),
      localModels: m,
      isOnline: () async => true,
      totalRamMb: () async => 8000,
      cloudFactory: () => null,
      localRunnerFactory: () => ({required prompt, imageBytes}) async => '{}',
    );
    expect((await r.resolve()).tier, AiTier.localLlm);
  });

  test('記憶體只查一次', () async {
    var asked = 0;
    final r = AiRouter(
      settings: await settings(),
      localModels: models(),
      isOnline: () async => true,
      totalRamMb: () async { asked++; return 8000; },
      cloudFactory: () => _FakeCloud(),
    );
    await r.resolve();
    await r.resolve();
    expect(asked, 1);
  });
}
