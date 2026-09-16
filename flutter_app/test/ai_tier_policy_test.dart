import 'package:flutter_test/flutter_test.dart';
import 'package:induspect_ai/services/ai/ai_tier_policy.dart';

/// 選層是純函式。這裡守的是「端側只是備援，不是取代」與「查不到就不開」。
void main() {
  group('chooseAiTier', () {
    AiTier pick({
      bool online = false,
      bool cloud = true,
      bool localEnabled = true,
      bool ready = true,
      bool eligible = true,
      bool ocr = true,
    }) =>
        chooseAiTier(
          online: online,
          cloudConfigured: cloud,
          localEnabled: localEnabled,
          localModelReady: ready,
          deviceEligible: eligible,
          ocrAvailable: ocr,
        );

    test('連得上而且有金鑰 → 一律雲端，端側就緒也不搶', () {
      expect(pick(online: true), AiTier.cloud);
    });

    test('連得上但沒金鑰 → 端側頂上', () {
      expect(pick(online: true, cloud: false), AiTier.localLlm);
    });

    test('離線、端側全部就位 → 端側', () {
      expect(pick(), AiTier.localLlm);
    });

    test('離線、使用者沒開端側 → OCR', () {
      expect(pick(localEnabled: false), AiTier.ocrOnly);
    });

    test('離線、模型沒裝 → OCR', () {
      expect(pick(ready: false), AiTier.ocrOnly);
    });

    test('離線、裝置不夠 → OCR（即使模型裝了）', () {
      // 3.7 GB 下載完才發現跑不動是最糟的體驗，所以門檻在選層這裡再擋一次。
      expect(pick(eligible: false), AiTier.ocrOnly);
    });

    test('什麼都沒有 → 手動', () {
      expect(pick(localEnabled: false, ocr: false), AiTier.manual);
    });
  });

  group('deviceEligibleForLocalModel', () {
    test('查不到記憶體就是不合格，不猜', () {
      expect(deviceEligibleForLocalModel(null), isFalse);
    });
    test('名目 8 GB 機型回報 7.4 GB 也要放行', () {
      expect(deviceEligibleForLocalModel(7400), isTrue);
    });
    test('6 GB 機型不放行', () {
      expect(deviceEligibleForLocalModel(5800), isFalse);
    });
  });

  group('downloadAllowed', () {
    const size = LocalModelRequirements.approxSizeBytes;
    const margin = LocalModelRequirements.freeSpaceMarginBytes;

    test('預設只准 Wi-Fi', () {
      expect(downloadAllowed(onWifi: false, wifiOnly: true, freeBytes: size * 2), isFalse);
      expect(downloadAllowed(onWifi: true, wifiOnly: true, freeBytes: size * 2), isTrue);
    });
    test('使用者關掉 Wi-Fi 限制才准走行動網路', () {
      expect(downloadAllowed(onWifi: false, wifiOnly: false, freeBytes: size * 2), isTrue);
    });
    test('空間要留 1 GB 給照片與 DB', () {
      expect(downloadAllowed(onWifi: true, wifiOnly: true, freeBytes: size + margin - 1), isFalse);
      expect(downloadAllowed(onWifi: true, wifiOnly: true, freeBytes: size + margin), isTrue);
    });
    test('查不到剩餘空間就不准', () {
      expect(downloadAllowed(onWifi: true, wifiOnly: true, freeBytes: null), isFalse);
    });
  });
}
