import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:induspect_ai/services/connectivity_service.dart';

/// ConnectivityService 可達性探測測試
///
/// 針對廠區「連上 AP 但沒有 uplink / captive portal」的情境：
/// 只看網路介面會誤判為 online，導致每次呼叫都要等逾時才降級。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ConnectivityService svc;

  setUp(() {
    svc = ConnectivityService(); // singleton
    svc.resetProbeCache();
    svc.probeOverride = null;
    // 單元測試環境沒有 connectivity plugin，預設把「介面」視為已連線，
    // 才能真正驗證探測層的決策邏輯
    svc.interfaceCheckOverride = () async => true;
  });

  tearDown(() {
    svc.probeOverride = null;
    svc.interfaceCheckOverride = null;
    svc.resetProbeCache();
  });

  group('探測目標 probeUri', () {
    test('未設定 BACKEND_API_URL → null（無從探測）', () {
      dotenv.testLoad(fileInput: 'GEMINI_API_KEY=k');
      expect(svc.probeUri, isNull);
    });

    test('已設定 → 指向 /health', () {
      dotenv.testLoad(fileInput: 'BACKEND_API_URL=https://api.example.com');
      expect(svc.probeUri.toString(), 'https://api.example.com/health');
    });

    test('尾端斜線會被正規化，不會出現雙斜線', () {
      dotenv.testLoad(fileInput: 'BACKEND_API_URL=https://api.example.com///');
      expect(svc.probeUri.toString(), 'https://api.example.com/health');
    });

    test('空字串視為未設定', () {
      dotenv.testLoad(fileInput: 'BACKEND_API_URL=   ');
      expect(svc.probeUri, isNull);
    });
  });

  group('快取行為', () {
    test('TTL 內只探測一次（批次分析不會每張照片都打一次）', () async {
      dotenv.testLoad(fileInput: 'BACKEND_API_URL=https://api.example.com');
      var calls = 0;
      svc.probeOverride = (uri) async {
        calls++;
        return true;
      };

      await svc.checkConnection();
      await svc.checkConnection();
      await svc.checkConnection();

      expect(calls, lessThanOrEqualTo(1),
          reason: '10 秒 TTL 內不應重複探測');
    });

    test('forceProbe 可略過快取', () async {
      dotenv.testLoad(fileInput: 'BACKEND_API_URL=https://api.example.com');
      var calls = 0;
      svc.probeOverride = (uri) async {
        calls++;
        return true;
      };

      await svc.checkConnection();
      final before = calls;
      await svc.checkConnection(forceProbe: true);

      expect(calls, greaterThan(before));
    });

    test('lastProbeOk 反映最近一次結果；未探測前為 null', () async {
      dotenv.testLoad(fileInput: 'BACKEND_API_URL=https://api.example.com');
      expect(svc.lastProbeOk, isNull);

      svc.probeOverride = (uri) async => false;
      await svc.checkConnection();
      expect(svc.lastProbeOk, false);

      svc.resetProbeCache();
      svc.probeOverride = (uri) async => true;
      await svc.checkConnection();
      expect(svc.lastProbeOk, true);
    });
  });

  group('決策矩陣（介面 × 可達性）', () {
    test('介面已斷 → 直接 false，且不浪費時間探測', () async {
      dotenv.testLoad(fileInput: 'BACKEND_API_URL=https://api.example.com');
      svc.interfaceCheckOverride = () async => false;
      var probed = false;
      svc.probeOverride = (uri) async {
        probed = true;
        return true;
      };

      expect(await svc.checkConnection(), false);
      expect(probed, false, reason: '介面就斷了，不該再花 3 秒探測');
    });

    test('介面連線 + 探測成功 → true', () async {
      dotenv.testLoad(fileInput: 'BACKEND_API_URL=https://api.example.com');
      svc.probeOverride = (uri) async => true;
      expect(await svc.checkConnection(), true);
    });

    test('介面連線但探測失敗（有 AP 沒 uplink）→ false', () async {
      dotenv.testLoad(fileInput: 'BACKEND_API_URL=https://api.example.com');
      svc.probeOverride = (uri) async => false;
      expect(await svc.checkConnection(), false,
          reason: '這正是廠區 captive portal 的情境，必須判為離線');
    });

    test('未設定後端位址 → 無從探測，退回介面判定（維持舊行為）', () async {
      dotenv.testLoad(fileInput: 'GEMINI_API_KEY=k');
      var probed = false;
      svc.probeOverride = (uri) async {
        probed = true;
        return false;
      };

      expect(await svc.checkConnection(), true);
      expect(probed, false);
    });
  });

  group('探測失敗的處理', () {
    test('探測拋例外 → 視為不可達（不得讓例外往上竄）', () async {
      dotenv.testLoad(fileInput: 'BACKEND_API_URL=https://api.example.com');
      svc.probeOverride = (uri) async => throw Exception('connection reset');

      final result = await svc.checkConnection();
      expect(result, false, reason: '探測例外必須被吞掉並視為不可達');
    });

    test('探測逾時 → 視為不可達', () async {
      dotenv.testLoad(fileInput: 'BACKEND_API_URL=https://api.example.com');
      svc.probeOverride = (uri) async {
        await Future<void>.delayed(const Duration(seconds: 30));
        return true;
      };

      final sw = Stopwatch()..start();
      final result = await svc.checkConnection();
      sw.stop();

      expect(result, false);
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)),
          reason: '必須在 probeTimeout(3s) 附近就放棄，而不是等 30 秒');
    });

    test('探測逾時上限設定合理（遠小於 Gemini 的 60 秒）', () {
      expect(ConnectivityService.probeTimeout,
          lessThan(const Duration(seconds: 10)));
      expect(ConnectivityService.probeCacheTtl,
          greaterThan(ConnectivityService.probeTimeout));
    });
  });
}
