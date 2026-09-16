import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'providers/inspection_provider.dart';
import 'providers/app_state_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/dashboard_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/guide_screen.dart';
import 'screens/unified_history_screen.dart';
import 'services/connectivity_service.dart';
import 'services/photo_sync_service.dart';
import 'services/blade_ai_retry_service.dart';
import 'services/share_queue_service.dart';
import 'services/ai/flutter_gemma_runner.dart';
import 'utils/constants.dart';

void main() async {
  // 確保 Flutter binding 已初始化
  WidgetsFlutterBinding.ensureInitialized();

  // 載入環境變量
  try {
    await dotenv.load(fileName: '.env');
  } catch (e) {
    print('Warning: .env file not found. Please create one from .env.example');
  }

  // 設置首選的設備方向（僅豎屏）
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // 初始化連接和同步服務
  final connectivityService = ConnectivityService();
  await connectivityService.initialize();

  final photoSyncService = PhotoSyncService();
  await photoSyncService.initialize();

  // 離線分享佇列（定檢 + 葉片）
  ShareQueueService().initialize();

  // 葉片 AI 解讀的補跑佇列：離線時演算法先跑完、AI 掛在佇列裡，
  // 連線恢復後把那一段補上（規格 §6）
  BladeAiRetryService().initialize();

  // Tier 1b 端側 AI：註冊 LiteRT-LM 引擎。沒有原生（桌面測試、非 arm64）時失敗是正常的，
  // 這時端側層永遠不會被選到（AiRouter 退回 OCR），不能讓它擋住 App 啟動。
  try {
    await FlutterGemmaRunner.initialize();
  } catch (e) {
    debugPrint('flutter_gemma 初始化失敗（端側 AI 不可用）: $e');
  }

  runApp(const InduSpectApp());
}

class InduSpectApp extends StatelessWidget {
  const InduSpectApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        // 端側模型的裝了沒／正在裝。建構不碰原生；refresh() 由 dashboard 啟動時叫。
        ChangeNotifierProvider(create: (_) => FlutterGemmaRunner.buildManager()),
        ChangeNotifierProvider(create: (_) => AppStateProvider()),
        ChangeNotifierProxyProvider<SettingsProvider, InspectionProvider>(
          create: (_) => InspectionProvider(),
          update: (context, settings, inspection) {
            inspection?.setSettingsProvider(settings);
            return inspection ?? InspectionProvider();
          },
        ),
      ],
      child: MaterialApp(
        title: 'InduSpect AI',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          primarySwatch: Colors.blue,
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppColors.primary,
            brightness: Brightness.light,
          ),
          appBarTheme: const AppBarTheme(
            centerTitle: true,
            elevation: 0,
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
          ),
          cardTheme: CardThemeData(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        home: const DashboardScreen(),
        routes: {
          '/settings': (context) => const SettingsScreen(),
          '/guide': (context) => const GuideScreen(),
          '/history': (context) => const UnifiedHistoryScreen(),
        },
      ),
    );
  }
}
