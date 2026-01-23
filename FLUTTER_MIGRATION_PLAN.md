# InduSpect AI - Flutter 移動應用遷移計劃

## 專案概覽

本文檔描述將現有 React Web 應用遷移到 Flutter 移動應用（iOS/Android）的完整計劃。

### 遷移目標

- ✅ 保留所有現有功能
- ✅ 提供原生移動體驗
- ✅ 支援 iOS 和 Android 雙平台
- ✅ 優化移動端性能和用戶體驗
- ✅ 保持與 Web 版本的功能同步能力

## 技術棧對照

| 功能 | React Web 版本 | Flutter 版本 |
|------|---------------|-------------|
| 前端框架 | React 19.2.0 + TypeScript | Flutter 3.x + Dart |
| 狀態管理 | React Hooks (useState) | Provider / Riverpod |
| 本地存儲 | localStorage (5-10MB) | shared_preferences + sqflite (unlimited) |
| 相機功能 | HTML5 Camera API | image_picker / camera plugin |
| 圖片處理 | Canvas API | CustomPaint / flutter_svg |
| AI 服務 | @google/genai (JavaScript) | google_generative_ai (Dart) |
| 網路請求 | fetch API | http / dio package |
| 路由 | 單頁面應用 | Navigator 2.0 / go_router |

## 項目結構規劃

```
flutter_app/
├── lib/
│   ├── main.dart                    # 應用入口
│   ├── config/
│   │   ├── app_config.dart         # 應用配置（API keys等）
│   │   └── routes.dart             # 路由配置
│   ├── models/
│   │   ├── inspection_item.dart    # 巡檢項目模型
│   │   ├── inspection_record.dart  # 巡檢記錄模型
│   │   ├── analysis_result.dart    # AI 分析結果模型
│   │   └── measurement.dart        # 測量數據模型
│   ├── services/
│   │   ├── gemini_service.dart     # Gemini API 服務
│   │   ├── storage_service.dart    # 本地存儲服務
│   │   ├── camera_service.dart     # 相機服務
│   │   └── image_service.dart      # 圖片處理服務
│   ├── providers/
│   │   ├── inspection_provider.dart # 巡檢狀態管理
│   │   └── app_state_provider.dart  # 應用狀態管理
│   ├── screens/
│   │   ├── home_screen.dart        # 首頁
│   │   ├── step1_upload_checklist.dart
│   │   ├── step2_capture_photos.dart
│   │   ├── step3_review_results.dart
│   │   ├── step4_records_report.dart
│   │   └── quick_analysis_screen.dart
│   ├── widgets/
│   │   ├── stepper_widget.dart     # 步驟指示器
│   │   ├── loading_widget.dart     # 載入動畫
│   │   ├── inspection_card.dart    # 審核卡片
│   │   ├── measurement_tool.dart   # 測量工具
│   │   └── common/                 # 通用組件
│   └── utils/
│       ├── constants.dart          # 常量定義
│       └── helpers.dart            # 工具函數
├── assets/
│   └── images/                     # 圖片資源
├── test/                           # 單元測試
├── integration_test/               # 整合測試
├── pubspec.yaml                    # 依賴配置
├── README_FLUTTER.md               # Flutter 應用文檔
└── .env.example                    # 環境變量範例
```

## 核心依賴包

```yaml
dependencies:
  flutter:
    sdk: flutter

  # 狀態管理
  provider: ^6.1.0

  # 本地存儲
  shared_preferences: ^2.2.0
  sqflite: ^2.3.0
  path_provider: ^2.1.0

  # 相機和圖片
  image_picker: ^1.0.0
  camera: ^0.10.0

  # AI 服務
  google_generative_ai: ^0.2.0

  # 網路請求
  dio: ^5.4.0

  # 圖片處理
  image: ^4.1.0

  # UI 組件
  flutter_svg: ^2.0.0
  cached_network_image: ^3.3.0

  # 工具
  uuid: ^4.3.0
  intl: ^0.19.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^3.0.0
```

## 關鍵功能遷移策略

### 1. 步驟 1: 上傳定檢表

**React 實現：**
```typescript
// 使用 HTML file input + Gemini API
const handleChecklistUpload = async (file: File) => {
  const base64 = await fileToBase64(file);
  const result = await geminiAnalyze(base64, prompt);
};
```

**Flutter 實現：**
```dart
// 使用 image_picker + google_generative_ai
Future<void> handleChecklistUpload() async {
  final ImagePicker picker = ImagePicker();
  final XFile? image = await picker.pickImage(source: ImageSource.camera);

  if (image != null) {
    final bytes = await image.readAsBytes();
    final result = await geminiService.analyzeChecklist(bytes);
    // 處理結果
  }
}
```

### 2. 步驟 2: 拍攝巡檢照片

**React 實現：**
- 使用 HTML5 Camera API
- 照片存儲在 localStorage (base64)

**Flutter 實現：**
```dart
// 使用 camera package 提供更好的控制
class CameraScreen extends StatefulWidget {
  @override
  Widget build(BuildContext context) {
    return CameraPreview(controller);
  }

  Future<void> takePicture() async {
    final image = await controller.takePicture();
    // 存儲到 SQLite
    await storageService.saveImage(image.path);
  }
}
```

### 3. 步驟 3: 圖片測量工具

**React 實現：**
```typescript
// 使用 HTML Canvas API
const canvas = document.createElement('canvas');
const ctx = canvas.getContext('2d');
// 繪製測量線
```

**Flutter 實現：**
```dart
// 使用 CustomPaint
class MeasurementPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // 繪製參考線
    canvas.drawLine(start, end, paint);
    // 繪製測量線
    canvas.drawLine(measureStart, measureEnd, paint);
  }
}

// 或使用 flutter_svg 進行更複雜的圖形處理
```

### 4. 本地存儲遷移

**React 實現：**
```typescript
// localStorage (limited to 5-10MB)
localStorage.setItem('inspectionItems', JSON.stringify(items));
```

**Flutter 實現：**
```dart
// 小數據: shared_preferences
await prefs.setString('app_state', jsonEncode(state));

// 大數據/結構化: sqflite
class DatabaseService {
  Future<void> saveInspectionRecord(InspectionRecord record) async {
    final db = await database;
    await db.insert('records', record.toMap());
  }

  Future<List<InspectionRecord>> getRecords() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('records');
    return List.generate(maps.length, (i) => InspectionRecord.fromMap(maps[i]));
  }
}
```

### 5. Gemini API 服務

**React 實現：**
```typescript
import { GoogleGenAI } from "@google/genai";
const genai = new GoogleGenAI(apiKey);
const model = genai.getGenerativeModel({ model: "gemini-2.5-flash" });
```

**Flutter 實現：**
```dart
import 'package:google_generative_ai/google_generative_ai.dart';

class GeminiService {
  late final GenerativeModel model;

  GeminiService(String apiKey) {
    model = GenerativeModel(
      model: 'gemini-2.5-flash',
      apiKey: apiKey,
    );
  }

  Future<AnalysisResult> analyzeImage(Uint8List imageBytes) async {
    final prompt = TextPart(promptText);
    final imagePart = DataPart('image/jpeg', imageBytes);

    final response = await model.generateContent([
      Content.multi([prompt, imagePart])
    ]);

    return AnalysisResult.fromJson(jsonDecode(response.text));
  }
}
```

## 開發階段規劃

### Phase 1: 基礎架構（第 1-2 週）
- ✅ 創建 Flutter 項目結構
- ✅ 設置依賴和配置
- ✅ 創建數據模型
- ✅ 實現基礎服務層

### Phase 2: 核心功能（第 3-5 週）
- ✅ 實現 4 步驟主流程 UI
- ✅ 相機拍攝功能
- ✅ Gemini API 集成
- ✅ 本地存儲功能

### Phase 3: 進階功能（第 6-7 週）
- ✅ 圖片測量工具
- ✅ 快速分析模式
- ✅ 報告生成功能

### Phase 4: 優化與測試（第 8-9 週）
- ✅ UI/UX 優化
- ✅ 性能優化
- ✅ 單元測試和整合測試
- ✅ iOS/Android 平台測試

### Phase 5: 部署準備（第 10 週）
- ✅ App Store / Play Store 準備
- ✅ 文檔完善
- ✅ Beta 測試

## 優化點

### 相較於 Web 版本的改進

1. **更好的相機體驗**
   - 原生相機控制（對焦、閃光燈、縮放）
   - 更高的照片質量
   - EXIF 資訊保留

2. **無限制本地存儲**
   - SQLite 資料庫（vs 5-10MB localStorage）
   - 可存儲高解析度原圖
   - 更好的數據結構化

3. **離線功能增強**
   - 更可靠的離線存儲
   - 背景同步
   - 網路狀態檢測

4. **性能優化**
   - 原生渲染（vs WebView）
   - 更流暢的動畫
   - 更快的啟動時間

5. **移動端特性**
   - GPS 定位（記錄巡檢位置）
   - 推送通知（巡檢提醒）
   - 生物識別認證

## 待解決的挑戰

1. **圖片測量工具精度**
   - 需要精確的觸控手勢處理
   - 縮放和平移的用戶體驗

2. **大圖片上傳**
   - 需要壓縮策略
   - 進度顯示
   - 斷點續傳

3. **API Key 安全**
   - 不應硬編碼在 app 中
   - 建議實現後端 proxy

4. **兩個分支同步**
   - Web 版本和 Flutter 版本功能同步機制
   - 共享的 prompt engineering 策略

## 與 Web 版本共存策略

1. **文檔位置**
   - Web 版本：根目錄（`index.tsx`, `index.html` 等）
   - Flutter 版本：`flutter_app/` 目錄

2. **共享資源**
   - `prj.md`, `arch.md` 等文檔保持共享
   - Prompt 策略文檔共享

3. **分支策略**
   - `main`: Web 版本持續開發
   - `claude/convert-to-mobile-app-*`: Flutter 開發
   - 定期合併 main 的文檔更新

## 下一步行動

1. ✅ 創建 `flutter_app/` 目錄
2. ✅ 初始化 Flutter 項目
3. ✅ 設置基礎架構
4. ✅ 開始實現核心功能
5. ✅ 定期提交到 `claude/convert-to-mobile-app-*` 分支

---

**文檔版本**: v1.0
**創建日期**: 2025-11-03
**最後更新**: 2025-11-03
