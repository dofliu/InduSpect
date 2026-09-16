import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:induspect_ai/providers/settings_provider.dart';
import 'package:induspect_ai/services/gemini_service.dart';
import 'package:induspect_ai/utils/constants.dart';

/// 金鑰與模型解析的守門。
///
/// 這批測試存在的原因是一個已出貨的缺口：核心 5 步驟流程呼叫無參數的 `init()`，
/// 而無參數只讀得到被 gitignore 的 `.env`——打包進 APK 的是空檔，
/// 於是使用者在設定頁填的金鑰對核心功能完全無效，AI 靜默關閉退回手動模式。
void main() {
  group('resolveGeminiConfig', () {
    test('明確傳入的金鑰優先於 .env', () {
      final cfg = resolveGeminiConfig(
        apiKey: 'AIza-from-settings',
        env: const {'GEMINI_API_KEY': 'AIza-from-env'},
      );
      expect(cfg.apiKey, 'AIza-from-settings');
    });

    test('沒有明確金鑰時才讀 .env', () {
      final cfg = resolveGeminiConfig(env: const {'GEMINI_API_KEY': 'AIza-from-env'});
      expect(cfg.apiKey, 'AIza-from-env');
    });

    test('兩邊都沒有金鑰時丟具名例外，不是泛用 Exception', () {
      // 型別是重點：葉片線的 catch 要靠它分辨「沒金鑰」與「有金鑰但連不上」，
      // 前者該引導使用者去設定頁，後者該排進離線佇列。
      expect(
        () => resolveGeminiConfig(env: const {}),
        throwsA(isA<MissingGeminiKeyException>()),
      );
    });

    test('只有空白的金鑰等同沒有金鑰', () {
      expect(
        () => resolveGeminiConfig(apiKey: '   ', env: const {'GEMINI_API_KEY': '  '}),
        throwsA(isA<MissingGeminiKeyException>()),
      );
    });

    test('金鑰前後空白會被修掉', () {
      final cfg = resolveGeminiConfig(apiKey: '  AIza-x  ', env: const {});
      expect(cfg.apiKey, 'AIza-x');
    });

    test('模型 ID：明確參數 > .env > AppConstants 預設', () {
      final explicit = resolveGeminiConfig(
        apiKey: 'k',
        flashModel: 'flash-explicit',
        proModel: 'pro-explicit',
        env: const {'GEMINI_FLASH_MODEL': 'flash-env', 'GEMINI_PRO_MODEL': 'pro-env'},
      );
      expect(explicit.flashModel, 'flash-explicit');
      expect(explicit.proModel, 'pro-explicit');

      final fromEnv = resolveGeminiConfig(
        apiKey: 'k',
        env: const {'GEMINI_FLASH_MODEL': 'flash-env', 'GEMINI_PRO_MODEL': 'pro-env'},
      );
      expect(fromEnv.flashModel, 'flash-env');
      expect(fromEnv.proModel, 'pro-env');

      final fallback = resolveGeminiConfig(apiKey: 'k', env: const {});
      expect(fallback.flashModel, AppConstants.geminiFlashModel);
      expect(fallback.proModel, AppConstants.geminiProModel);
    });

    test('空字串的模型覆寫不算覆寫', () {
      final cfg = resolveGeminiConfig(
        apiKey: 'k',
        flashModel: '  ',
        env: const {'GEMINI_FLASH_MODEL': ''},
      );
      expect(cfg.flashModel, AppConstants.geminiFlashModel);
    });
  });

  group('GeminiService.init 的冪等性', () {
    setUp(GeminiService.resetForTesting);
    tearDown(GeminiService.resetForTesting);

    test('帶金鑰初始化後，無參數的 init() 不得把它丟掉', () {
      // 這是那個缺口的回歸測試：GeminiService 是 singleton，
      // provider 先用設定頁的金鑰初始化好，核心流程接著呼叫無參數 init()。
      // 修好之前這裡會丟例外，呼叫端 catch 後把可用的服務設成 null。
      final service = GeminiService();
      service.init(apiKey: 'AIza-from-settings', env: const {});
      expect(service.isInitialized, isTrue);

      expect(() => service.init(env: const {}), returnsNormally);
      expect(service.isInitialized, isTrue);
      expect(service.currentApiKeyForTesting, 'AIza-from-settings');
    });

    test('沒有任何金鑰時初始化仍然丟 MissingGeminiKeyException', () {
      final service = GeminiService();
      expect(
        () => service.init(env: const {}),
        throwsA(isA<MissingGeminiKeyException>()),
      );
      expect(service.isInitialized, isFalse);
    });

    test('換一支金鑰會真的重新初始化', () {
      final service = GeminiService();
      service.init(apiKey: 'AIza-a', env: const {});
      service.init(apiKey: 'AIza-b', env: const {});
      expect(service.currentApiKeyForTesting, 'AIza-b');
    });

    test('只換模型也要重新初始化', () {
      final service = GeminiService();
      service.init(apiKey: 'k', flashModel: 'flash-1', env: const {});
      service.init(apiKey: 'k', flashModel: 'flash-2', env: const {});
      expect(service.currentFlashModelForTesting, 'flash-2');
    });
  });

  group('SettingsProvider 把金鑰推出去', () {
    test('有金鑰時會推進 GeminiService', () async {
      SharedPreferences.setMockInitialValues({
        'gemini_api_key': 'AIza-user',
        'selected_model': 'gemini-3.6-flash',
      });
      final captured = <String, String?>{};
      final settings = SettingsProvider();
      await settings.init();
      settings.applyToGeminiService(sink: ({apiKey, flashModel, proModel, env}) {
        captured['apiKey'] = apiKey;
        captured['flashModel'] = flashModel;
      });
      expect(captured['apiKey'], 'AIza-user');
      expect(captured['flashModel'], 'gemini-3.6-flash');
    });

    test('沒有金鑰時不得把例外往外丟', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await settings.init();
      expect(
        () => settings.applyToGeminiService(
            sink: ({apiKey, flashModel, proModel, env}) {
          throw const MissingGeminiKeyException();
        }),
        returnsNormally,
      );
    });

    test('換金鑰後會重新推一次', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await settings.init();
      final keys = <String?>[];
      await settings.setApiKey('AIza-new');
      settings.applyToGeminiService(
          sink: ({apiKey, flashModel, proModel, env}) => keys.add(apiKey));
      expect(keys, ['AIza-new']);
    });
  });
}
