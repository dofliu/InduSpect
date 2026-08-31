// InduSpect AI smoke test
//
// 驗證 InduSpectApp 可建構並渲染首頁。
// 注意：Dashboard 含非同步載入與動畫，pumpAndSettle 會逾時（永不 settle），
// 因此改以固定幀數 pump（此前本檔因此長期被排除於測試清單外）。

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:induspect_ai/main.dart';

void main() {
  setUpAll(() {
    // 測試環境無原生 plugin：SQLite 用 ffi、SharedPreferences 用 mock、.env 用記憶體載入
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    dotenv.testLoad(fileInput: 'GEMINI_API_KEY=test-key');
  });

  testWidgets('InduSpectApp renders without error', (WidgetTester tester) async {
    await tester.pumpWidget(const InduSpectApp());
    // 固定幀數推進（不可用 pumpAndSettle：首頁有持續動畫/非同步 Future）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // 首頁應出現 InduSpect 字樣
    expect(find.textContaining('InduSpect'), findsWidgets);
  });
}
