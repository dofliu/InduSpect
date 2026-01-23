# Flutter App 開發指南

## 當前開發狀態

### ✅ 已完成

- [x] 項目結構搭建
- [x] 數據模型定義
- [x] 服務層實現
  - [x] Gemini AI 服務
  - [x] 本地存儲服務
  - [x] 圖片處理服務
- [x] 狀態管理（Provider）
- [x] UI 框架
  - [x] 主頁面和導航
  - [x] 步驟 1: 上傳定檢表
  - [x] 步驟 2: 拍攝照片
  - [x] 步驟 3: 審核結果
  - [x] 步驟 4: 記錄與報告
  - [x] 快速分析模式

### 🚧 待實現

- [ ] **圖片測量工具** (高優先級)
  - [ ] CustomPaint 實現繪圖
  - [ ] 觸控手勢處理
  - [ ] 比例尺計算
  - [ ] 測量結果保存

- [ ] **平台配置** (中優先級)
  - [ ] Android 權限配置
  - [ ] iOS 權限配置
  - [ ] 相機權限請求
  - [ ] 存儲權限請求

- [ ] **錯誤處理** (中優先級)
  - [ ] 網路錯誤處理
  - [ ] API 錯誤處理
  - [ ] 本地存儲錯誤處理
  - [ ] 用戶友好的錯誤提示

- [ ] **性能優化** (中優先級)
  - [ ] 圖片懶加載
  - [ ] 大圖片優化
  - [ ] 列表滾動優化
  - [ ] 內存管理

- [ ] **測試** (低優先級)
  - [ ] 單元測試
  - [ ] Widget 測試
  - [ ] 整合測試
  - [ ] 平台測試

## 下一步開發計劃

### Phase 1: 完善核心功能 (1-2 週)

1. **實現圖片測量工具**
   - 創建 `MeasurementToolWidget`
   - 實現 `MeasurementPainter` (CustomPaint)
   - 集成到審核頁面

2. **配置平台權限**
   - 添加 Android manifest 配置
   - 添加 iOS Info.plist 配置
   - 實現權限請求邏輯

3. **改進錯誤處理**
   - 添加全局錯誤處理
   - 實現網路狀態檢測
   - 優化用戶反饋

### Phase 2: 測試與優化 (1 週)

1. **編寫測試**
   - 服務層單元測試
   - Provider 測試
   - Widget 測試

2. **性能優化**
   - 圖片壓縮優化
   - 內存管理
   - 啟動速度優化

3. **用戶體驗優化**
   - 載入動畫
   - 過渡動畫
   - 反饋提示

### Phase 3: 發布準備 (1 週)

1. **平台配置完善**
   - Android 簽名配置
   - iOS 證書配置
   - App 圖標和啟動畫面

2. **文檔完善**
   - 用戶手冊
   - 部署文檔
   - API 文檔

3. **Beta 測試**
   - 內部測試
   - Bug 修復
   - 性能調優

## 開發規範

### 代碼組織

```dart
// 1. 導入順序
import 'dart:xxx';           // Dart 標準庫
import 'package:flutter/xxx'; // Flutter 框架
import 'package:xxx/xxx';    // 第三方包
import '../xxx';             // 本地導入

// 2. 類定義順序
class MyWidget extends StatelessWidget {
  // 1. 常量
  static const xxx = xxx;

  // 2. 字段
  final String title;

  // 3. 構造函數
  const MyWidget({required this.title});

  // 4. 覆蓋方法
  @override
  Widget build(BuildContext context) { }

  // 5. 私有方法
  void _handleTap() { }
}
```

### 命名規範

- **文件名**: `snake_case.dart`
- **類名**: `PascalCase`
- **變量/方法**: `camelCase`
- **常量**: `UPPER_SNAKE_CASE` 或 `lowerCamelCase`
- **私有**: 前綴 `_`

### Widget 設計原則

1. **單一職責**: 每個 Widget 只做一件事
2. **可複用**: 提取常用 Widget 到 `widgets/common/`
3. **參數化**: 通過參數控制外觀和行為
4. **組合優於繼承**: 使用 Widget 組合

示例：
```dart
// ❌ 不好 - 太多職責
class ComplexWidget extends StatelessWidget { }

// ✅ 好 - 職責分離
class HeaderWidget extends StatelessWidget { }
class ContentWidget extends StatelessWidget { }
class FooterWidget extends StatelessWidget { }
```

### 狀態管理最佳實踐

1. **Provider 使用**
   ```dart
   // 讀取 - 會重建
   final data = context.watch<MyProvider>();

   // 讀取 - 不會重建
   final data = context.read<MyProvider>();

   // 選擇性監聽
   final value = context.select((MyProvider p) => p.value);
   ```

2. **避免過度重建**
   ```dart
   // ❌ 整個頁面重建
   class MyPage extends StatelessWidget {
     Widget build(context) {
       final provider = context.watch<MyProvider>();
       return Scaffold(...);
     }
   }

   // ✅ 只重建需要的部分
   class MyPage extends StatelessWidget {
     Widget build(context) {
       return Scaffold(
         body: Consumer<MyProvider>(
           builder: (context, provider, child) => Text(provider.value),
         ),
       );
     }
   }
   ```

### 錯誤處理

1. **服務層**
   ```dart
   Future<Result> fetchData() async {
     try {
       final data = await api.get();
       return Result.success(data);
     } catch (e) {
       print('Error: $e');
       return Result.error(e.toString());
     }
   }
   ```

2. **UI 層**
   ```dart
   if (result.isError) {
     ScaffoldMessenger.of(context).showSnackBar(
       SnackBar(content: Text(result.error)),
     );
   }
   ```

### 性能優化技巧

1. **使用 const 構造函數**
   ```dart
   const Text('Hello');  // ✅ 不會重建
   Text('Hello');        // ❌ 可能重建
   ```

2. **列表優化**
   ```dart
   ListView.builder(  // ✅ 懶加載
     itemCount: 1000,
     itemBuilder: (context, index) => ListTile(),
   );
   ```

3. **圖片優化**
   ```dart
   Image.file(
     file,
     cacheWidth: 800,  // 限制解碼寬度
     cacheHeight: 600,
   );
   ```

## 調試技巧

### Flutter DevTools

```bash
# 啟動 DevTools
flutter pub global activate devtools
flutter pub global run devtools
```

### 日誌輸出

```dart
import 'package:flutter/foundation.dart';

// 僅在 debug 模式打印
debugPrint('Debug message');

// 條件日誌
if (kDebugMode) {
  print('Only in debug');
}
```

### 性能分析

```bash
# 性能模式運行
flutter run --profile

# 查看 widget 重建
flutter run --trace-skia
```

## 常見問題解決

### 1. Hot Reload 不生效

```bash
# 嘗試 Hot Restart
flutter run  # 按 R

# 或完全重啟
flutter clean
flutter pub get
flutter run
```

### 2. 構建錯誤

```bash
# 清理並重新構建
flutter clean
flutter pub get
flutter build apk
```

### 3. 依賴衝突

```bash
# 升級所有依賴
flutter pub upgrade

# 查看依賴樹
flutter pub deps
```

### 4. 平台特定問題

**Android:**
```bash
cd android
./gradlew clean
cd ..
flutter run
```

**iOS:**
```bash
cd ios
rm -rf Pods Podfile.lock
pod install
cd ..
flutter run
```

## 發布檢查清單

- [ ] 所有功能測試通過
- [ ] 性能達標（啟動 < 3s）
- [ ] 內存無洩漏
- [ ] 錯誤處理完善
- [ ] 用戶體驗流暢
- [ ] 文檔完整
- [ ] 版本號更新
- [ ] 變更日誌更新
- [ ] 隱私政策和服務條款
- [ ] App Store / Play Store 資料準備

## 資源

- [Flutter 官方文檔](https://flutter.dev/docs)
- [Dart 語言指南](https://dart.dev/guides)
- [Provider 文檔](https://pub.dev/packages/provider)
- [Google Generative AI SDK](https://pub.dev/packages/google_generative_ai)
- [Flutter 最佳實踐](https://flutter.dev/docs/development/ui/widgets-intro)

---

**最後更新**: 2025-11-03
