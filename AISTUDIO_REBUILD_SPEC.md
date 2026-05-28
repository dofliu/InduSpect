# InduSpect AI — Google AI Studio 完整重建規格文件

> **用途**：此文件供 Google AI Studio 從零開始重建 InduSpect，並發布為 Android App。
> **語言**：UI 介面與 AI 回應使用**繁體中文**，程式碼以英文撰寫。
> **最後更新**：2026-05-28

---

## 目錄

1. [專案概覽](#1-專案概覽)
2. [技術架構決策](#2-技術架構決策)
3. [Flutter 專案設定](#3-flutter-專案設定)
4. [資料模型](#4-資料模型)
5. [SQLite 資料庫 Schema](#5-sqlite-資料庫-schema)
6. [核心畫面結構](#6-核心畫面結構)
7. [5 步驟檢測 Pipeline 詳細規格](#7-5-步驟檢測-pipeline-詳細規格)
8. [Gemini AI Prompt 範本](#8-gemini-ai-prompt-範本)
9. [後端 API 規格](#9-後端-api-規格)
10. [工業法規標準資料庫](#10-工業法規標準資料庫)
11. [單位換算引擎](#11-單位換算引擎)
12. [離線優先架構](#12-離線優先架構)
13. [Android 設定與權限](#13-android-設定與權限)
14. [關鍵演算法](#14-關鍵演算法)
15. [UI 設計規範](#15-ui-設計規範)
16. [環境變數與 API Key 設定](#16-環境變數與-api-key-設定)
17. [測試規格](#17-測試規格)
18. [實作優先順序](#18-實作優先順序)

---

## 1. 專案概覽

### 1.1 產品定位

**InduSpect AI（智慧工業巡檢系統）** 是一款 Android 行動應用，讓工廠巡檢人員可以：
- 上傳既有的 Excel/Word 定檢表，由 AI 自動辨識欄位結構
- 引導式逐項拍照，Gemini AI 即時分析設備狀態
- 自動將 AI 分析結果回填至原始格式文件
- 根據台灣工業法規標準自動判定合格/不合格
- 產生 AI 高階主管摘要報告
- 離線工作，網路恢復後自動分享

### 1.2 核心功能（只有兩個）

**功能一：完整檢測 Pipeline**
```
上傳定檢表 (Excel/Word)
    ↓
AI 分析表單結構 → 產生檢查項目列表
    ↓
一鍵自動檢測（引導拍照 → 批次 AI 分析 → 法規標準判定）
    ↓
預覽結果（合格/不合格/警告統計）
    ↓
回填原始格式文件（或 JSON 摘要 fallback）
    ↓
AI 自動產生高階主管摘要報告
    ↓
分享文件（離線時暫存，上線自動發送）
```

**功能二：歷史紀錄**
- GPS 定位標記（含反向地理編碼）
- 可編輯標題
- 全文搜尋（SQL LIKE）
- 重新分享已匯出文件

### 1.3 應用程式資訊

```
App 名稱：InduSpect AI
Package Name：com.induspect.ai
版本：1.0.0+1
最低 Android SDK：21 (Android 5.0)
目標 Android SDK：34
Flutter SDK：>=3.2.0
Dart SDK：>=3.2.0 <4.0.0
```

---

## 2. 技術架構決策

### 2.1 技術選型

| 技術 | 選擇 | 理由 |
|------|------|------|
| UI 框架 | Flutter 3.x | 跨平台、豐富 Widget |
| AI 服務 | Google Gemini API | 多模態（圖像+文字）、繁中支援 |
| 本地資料庫 | SQLite (sqflite) | 離線優先、結構化查詢 |
| 狀態管理 | Provider | 輕量、適合中小型應用 |
| HTTP | Dio + http | 功能完整 |
| 文件解析 | excel + archive | 解析 xlsx/docx |
| GPS | geolocator + geocoding | 精確定位 + 地址解析 |
| 分享 | share_plus | 跨平台分享介面 |

### 2.2 架構層次

```
┌─────────────────────────────────┐
│          Flutter UI Layer        │
│  (Screens, Widgets, Providers)   │
├─────────────────────────────────┤
│         Service Layer            │
│  GeminiService  DatabaseService  │
│  LocationService  ShareQueue     │
│  BackendApiService  FileService  │
├─────────────────────────────────┤
│          Data Layer              │
│  Models  SQLite  SharedPrefs     │
├─────────────────────────────────┤
│       External Services          │
│  Gemini API  FastAPI Backend     │
│  GPS  File System                │
└─────────────────────────────────┘
```

### 2.3 離線優先原則

- 所有資料首先存入 SQLite，再考慮同步
- 分享功能有離線佇列（ShareQueueService）
- Gemini AI 需要網路；離線時顯示提示，允許手動填寫
- 後端 API 為可選強化（offline 時降級為本地處理）

---

## 3. Flutter 專案設定

### 3.1 pubspec.yaml

```yaml
name: induspect_ai
description: InduSpect AI - 智慧巡檢系統移動應用
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.2.0 <4.0.0'

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
  image_picker: ^1.0.7
  camera: ^0.10.5+9

  # AI 服務
  google_generative_ai: ^0.4.6

  # 網路請求
  dio: ^5.4.0
  http: ^1.2.0
  connectivity_plus: ^5.0.2

  # 圖片處理
  image: ^4.1.7

  # 分享/匯出
  share_plus: ^7.2.1

  # 文件解析
  excel: ^4.0.6
  archive: ^3.6.1

  # 工具
  uuid: ^4.3.3
  intl: ^0.19.0
  path: ^1.8.3
  file_picker: ^8.0.0

  # 環境變量
  flutter_dotenv: ^5.1.0

  # 權限處理
  permission_handler: ^11.2.0

  # GPS 定位
  geolocator: ^11.0.0
  geocoding: ^3.0.0

  # UI
  flutter_svg: ^2.0.9

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_launcher_icons: ^0.13.1
  flutter_lints: ^3.0.1
  sqflite_common_ffi: ^2.3.0

flutter_launcher_icons:
  android: true
  ios: false
  image_path: "assets/images/logo.png"
  adaptive_icon_background: "#2196F3"
  adaptive_icon_foreground: "assets/images/logo_foreground.png"

flutter:
  uses-material-design: true
  assets:
    - assets/images/
    - assets/templates/
    - .env
```

### 3.2 目錄結構

```
lib/
├── main.dart                        # 入口點
├── app.dart                         # InduSpectApp widget
├── models/
│   ├── form_inspection_record.dart  # 主要資料模型
│   ├── inspection_template.dart     # 表單模板
│   ├── template_field.dart          # 模板欄位
│   └── analysis_result.dart         # AI 分析結果
├── screens/
│   ├── dashboard_screen.dart        # 主頁（2 入口 + 最近紀錄）
│   ├── form_inspection_screen.dart  # ★ 核心：5 步驟流程
│   ├── unified_history_screen.dart  # 歷史紀錄
│   ├── guided_capture_screen.dart   # 批次引導拍照
│   └── settings_screen.dart         # API Key 設定
├── services/
│   ├── gemini_service.dart          # Gemini AI
│   ├── database_service.dart        # SQLite CRUD
│   ├── backend_api_service.dart     # 後端 API（可選）
│   ├── location_service.dart        # GPS
│   ├── share_queue_service.dart     # 離線分享佇列
│   ├── connectivity_service.dart    # 網路監聽
│   ├── file_save_service.dart       # 檔案分享
│   └── photo_service.dart           # 照片命名
├── providers/
│   ├── settings_provider.dart       # API Key & 模型設定
│   └── app_state_provider.dart      # 應用狀態
└── utils/
    └── constants.dart               # 常量定義
```

---

## 4. 資料模型

### 4.1 FormInspectionRecord（核心模型）

```dart
// lib/models/form_inspection_record.dart

import 'dart:convert';

enum FormRecordStatus { draft, completed, exported, shared }

class FormInspectionRecord {
  final int? id;
  final String recordId;         // UUID
  String title;                  // 可編輯標題
  final String? sourceFileName;  // 來源檔名（例：定檢表2026.xlsx）
  final String? templateJson;    // 解析後的模板 JSON
  final Map<String, dynamic> filledData;   // {fieldId: value}
  final Map<String, dynamic> aiResults;   // {fieldId: {equipment_type, readings, ...}}
  String? summaryReport;         // AI 摘要報告（Markdown）
  String? filledDocumentPath;    // 已回填文件的本地路徑
  FormRecordStatus status;       // draft/completed/exported/shared
  final double? latitude;
  final double? longitude;
  final String? locationName;    // 反向地理編碼地名
  final List<String> photoPaths;
  final DateTime createdAt;
  DateTime updatedAt;
  bool pendingShare;             // 離線時待分享

  FormInspectionRecord({
    this.id,
    required this.recordId,
    required this.title,
    this.sourceFileName,
    this.templateJson,
    Map<String, dynamic>? filledData,
    Map<String, dynamic>? aiResults,
    this.summaryReport,
    this.filledDocumentPath,
    this.status = FormRecordStatus.draft,
    this.latitude,
    this.longitude,
    this.locationName,
    List<String>? photoPaths,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.pendingShare = false,
  })  : filledData = filledData ?? {},
        aiResults = aiResults ?? {},
        photoPaths = photoPaths ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  // Computed getters
  int get anomalyCount {
    int count = 0;
    for (final result in aiResults.values) {
      if (result is Map && result['is_anomaly'] == true) count++;
    }
    return count;
  }

  int get completedCount => filledData.length;

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'record_id': recordId,
      'title': title,
      'source_file_name': sourceFileName,
      'template_json': templateJson,
      'filled_data': jsonEncode(filledData),
      'ai_results': jsonEncode(aiResults),
      'summary_report': summaryReport,
      'filled_document_path': filledDocumentPath,
      'status': status.name,
      'latitude': latitude,
      'longitude': longitude,
      'location_name': locationName,
      'photo_paths': jsonEncode(photoPaths),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'pending_share': pendingShare ? 1 : 0,
    };
    if (id != null) map['id'] = id;
    return map;
  }

  factory FormInspectionRecord.fromMap(Map<String, dynamic> map) {
    return FormInspectionRecord(
      id: map['id'] as int?,
      recordId: map['record_id'] as String,
      title: map['title'] as String,
      sourceFileName: map['source_file_name'] as String?,
      templateJson: map['template_json'] as String?,
      filledData: _decodeJson(map['filled_data']),
      aiResults: _decodeJson(map['ai_results']),
      summaryReport: map['summary_report'] as String?,
      filledDocumentPath: map['filled_document_path'] as String?,
      status: FormRecordStatus.values.firstWhere(
        (s) => s.name == (map['status'] as String? ?? 'draft'),
        orElse: () => FormRecordStatus.draft,
      ),
      latitude: map['latitude'] as double?,
      longitude: map['longitude'] as double?,
      locationName: map['location_name'] as String?,
      photoPaths: _decodePaths(map['photo_paths'] as String?),
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? '') ?? DateTime.now(),
      pendingShare: (map['pending_share'] as int? ?? 0) == 1,
    );
  }

  FormInspectionRecord copyWith({ /* all fields optional */ }) { ... }

  static Map<String, dynamic> _decodeJson(dynamic value) {
    if (value == null || value == '') return {};
    if (value is String) {
      try { return Map<String, dynamic>.from(jsonDecode(value) as Map); }
      catch (_) { return {}; }
    }
    return {};
  }

  static List<String> _decodePaths(String? value) {
    if (value == null || value.isEmpty) return [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) return decoded.cast<String>();
    } catch (_) {
      // 向後相容舊格式（|||分隔）
      return value.split('|||').where((s) => s.isNotEmpty).toList();
    }
    return [];
  }
}
```

### 4.2 InspectionItemState（單項目狀態）

```dart
// 在 form_inspection_screen.dart 內定義

class InspectionItemState {
  final String fieldId;
  final String label;
  final String fieldType;    // text/number/radio/measurement
  String? photoPath;
  Uint8List? photoBytes;
  Map<String, dynamic>? aiResult;   // Gemini 回傳的 JSON
  String? manualValue;
  bool isCompleted;
  bool isAnalyzing;
  late final TextEditingController manualController;

  // AI 分析或手動值
  String? get displayValue {
    if (aiResult != null) {
      final condition = aiResult!['condition_assessment'] as String?;
      final isAnomaly = aiResult!['is_anomaly'] as bool?;
      if (isAnomaly == true) {
        return '異常: ${aiResult!['anomaly_description'] ?? condition ?? ''}';
      }
      return condition ?? '正常';
    }
    return manualValue;
  }

  // 合格/不合格/已填寫/未檢測
  String get verdict {
    if (aiResult != null) {
      return (aiResult!['is_anomaly'] == true) ? '不合格' : '合格';
    }
    if (manualValue != null && manualValue!.isNotEmpty) return '已填寫';
    return '未檢測';
  }
}
```

### 4.3 AnalysisResult（AI 分析結果）

```dart
// lib/models/analysis_result.dart

enum AnalysisStatus { pending, analyzing, completed, error }

class AnalysisResult {
  final String itemId;
  final String photoPath;
  final String? equipmentType;
  final Map<String, dynamic>? readings;  // {欄位名: {value, unit}}
  final String? conditionAssessment;
  final bool isAnomaly;
  final String? anomalyDescription;
  final String? estimatedSize;
  final String? analysisError;
  final AnalysisStatus status;

  // 從 Gemini JSON 回應建立
  factory AnalysisResult.fromGeminiJson(
    String itemId, String photoPath, Map<String, dynamic> json) {
    return AnalysisResult(
      itemId: itemId,
      photoPath: photoPath,
      equipmentType: json['equipment_type'] as String?,
      readings: json['readings'] as Map<String, dynamic>?,
      conditionAssessment: json['condition_assessment'] as String?,
      isAnomaly: json['is_anomaly'] as bool? ?? false,
      anomalyDescription: json['anomaly_description'] as String?,
      estimatedSize: json['estimated_size'] as String?,
      status: AnalysisStatus.completed,
    );
  }
}
```

### 4.4 InspectionTemplate

```dart
// lib/models/inspection_template.dart

class InspectionTemplate {
  final String templateId;
  final String name;
  final String fileType;          // xlsx / docx
  final List<TemplateField> fields;
  final Map<String, dynamic> metadata;
}

// lib/models/template_field.dart
class TemplateField {
  final String fieldId;
  final String fieldName;
  final String fieldType;        // text/number/radio/date/measurement
  final bool required;
  final String? unit;
  final List<String>? options;   // radio 選項
  final Map<String, dynamic>? valueLocation;  // Excel/Word 位置
}
```

---

## 5. SQLite 資料庫 Schema

### 5.1 資料庫版本：v3

```dart
// lib/services/database_service.dart

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  Database? _database;

  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'induspect.db');
    return await openDatabase(
      path,
      version: 3,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }
```

### 5.2 核心表：form_inspection_records

```sql
CREATE TABLE form_inspection_records (
  id                   INTEGER PRIMARY KEY AUTOINCREMENT,
  record_id            TEXT UNIQUE NOT NULL,
  title                TEXT NOT NULL,
  source_file_name     TEXT,
  template_json        TEXT,
  filled_data          TEXT NOT NULL,          -- JSON object
  ai_results           TEXT,                   -- JSON object
  summary_report       TEXT,                   -- Markdown string
  filled_document_path TEXT,
  status               TEXT NOT NULL,          -- draft/completed/exported/shared
  latitude             REAL,
  longitude            REAL,
  location_name        TEXT,
  photo_paths          TEXT,                   -- JSON array of paths
  created_at           TEXT NOT NULL,          -- ISO8601
  updated_at           TEXT NOT NULL,          -- ISO8601
  pending_share        INTEGER DEFAULT 0       -- 0/1
);

CREATE INDEX idx_form_status     ON form_inspection_records(status);
CREATE INDEX idx_form_created_at ON form_inspection_records(created_at);
CREATE INDEX idx_form_title      ON form_inspection_records(title);
```

### 5.3 Migration 路徑

```dart
Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
  // v1 → v2: 新增 photo_sync_tasks（舊功能殘留，仍需建表避免錯誤）
  if (oldVersion < 2) {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS photo_sync_tasks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id TEXT UNIQUE NOT NULL,
        ...
      )
    ''');
  }
  // v2 → v3: 新增 form_inspection_records（核心表）
  if (oldVersion < 3) {
    await _createFormInspectionRecordsTable(db);
  }
}
```

### 5.4 CRUD 操作

```dart
// 新增紀錄
Future<int> insertFormRecord(FormInspectionRecord record) async {
  final db = await database;
  final map = record.toMap();
  map['updated_at'] = DateTime.now().toIso8601String();  // 不 mutate 原物件
  return await db.insert('form_inspection_records', map,
    conflictAlgorithm: ConflictAlgorithm.replace);
}

// 更新紀錄（避免 mutate 傳入物件）
Future<int> saveFormRecord(FormInspectionRecord record) async {
  final db = await database;
  final map = Map<String, dynamic>.from(record.toMap());
  map['updated_at'] = DateTime.now().toIso8601String();
  return await db.update('form_inspection_records', map,
    where: 'record_id = ?', whereArgs: [record.recordId]);
}

// 搜尋（SQL side，不在記憶體做）
Future<List<FormInspectionRecord>> searchFormRecords(String query) async {
  final db = await database;
  final rows = await db.query(
    'form_inspection_records',
    where: 'title LIKE ? OR location_name LIKE ?',
    whereArgs: ['%$query%', '%$query%'],
    orderBy: 'created_at DESC',
  );
  return rows.map(FormInspectionRecord.fromMap).toList();
}

// 查詢最近 N 筆
Future<List<FormInspectionRecord>> getRecentFormRecords({int limit = 20}) async {
  final db = await database;
  final rows = await db.query('form_inspection_records',
    orderBy: 'created_at DESC', limit: limit);
  return rows.map(FormInspectionRecord.fromMap).toList();
}

// 查詢待分享
Future<List<FormInspectionRecord>> getPendingShareRecords() async {
  final db = await database;
  final rows = await db.query('form_inspection_records',
    where: 'pending_share = 1');
  return rows.map(FormInspectionRecord.fromMap).toList();
}
```

---

## 6. 核心畫面結構

### 6.1 畫面地圖

```
InduSpectApp
├── DashboardScreen（主頁）
│   ├── → FormInspectionScreen（開始檢測）
│   └── → UnifiedHistoryScreen（歷史紀錄）
├── FormInspectionScreen（5 步驟核心流程）
│   └── → GuidedCaptureScreen（批次引導拍照）
├── UnifiedHistoryScreen（歷史紀錄）
│   └── 每筆紀錄：編輯標題、刪除、重新分享
└── SettingsScreen（API Key 設定）
```

### 6.2 DashboardScreen

```dart
// 主頁結構：
// - AppBar：標題 "InduSpect AI" + 設定按鈕
// - 兩個主要功能按鈕：
//   ┌─────────────────┐  ┌─────────────────┐
//   │  📋 開始檢測     │  │  📂 歷史紀錄     │
//   │  FormInspection  │  │  UnifiedHistory  │
//   └─────────────────┘  └─────────────────┘
// - 最近紀錄列表（FutureBuilder 從 SQLite 查詢）
//   每筆紀錄顯示：標題、日期、狀態、異常數

class DashboardScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('InduSpect AI'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: Column(
        children: [
          // 兩個主功能卡片
          Row(
            children: [
              _ActionCard(
                icon: Icons.assignment,
                title: '開始檢測',
                subtitle: '上傳定檢表，AI 自動分析',
                onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const FormInspectionScreen())),
              ),
              _ActionCard(
                icon: Icons.history,
                title: '歷史紀錄',
                subtitle: '查看過去的檢測紀錄',
                onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const UnifiedHistoryScreen())),
              ),
            ],
          ),
          // 最近紀錄
          FutureBuilder<List<FormInspectionRecord>>(
            future: DatabaseService().getRecentFormRecords(limit: 10),
            builder: (context, snapshot) {
              // 顯示清單...
            },
          ),
        ],
      ),
    );
  }
}
```

### 6.3 UnifiedHistoryScreen

```dart
// 功能：
// - 搜尋欄（300ms debounce，SQL LIKE 搜尋 title + location_name）
// - 紀錄列表（status 徽章、GPS 地名、異常數量）
// - 長按或右滑：刪除
// - 點擊標題：進入 inline 編輯模式
// - 重新分享按鈕（share_plus）

class UnifiedHistoryScreen extends StatefulWidget { ... }

class _UnifiedHistoryScreenState extends State<UnifiedHistoryScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  List<FormInspectionRecord> _records = [];

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      // SQL-side 搜尋（Issue #16 修復）
      final results = query.isEmpty
        ? await DatabaseService().getRecentFormRecords()
        : await DatabaseService().searchFormRecords(query);
      setState(() => _records = results);
    });
  }

  Future<void> _editTitle(FormInspectionRecord record, String newTitle) async {
    final updated = record.copyWith(title: newTitle);
    await DatabaseService().saveFormRecord(updated);
    _loadRecords();
  }

  Future<void> _reshare(FormInspectionRecord record) async {
    if (record.filledDocumentPath != null) {
      // 檢查檔案是否仍存在（Issue #18 修復）
      final file = File(record.filledDocumentPath!);
      if (await file.exists()) {
        await Share.shareXFiles([XFile(record.filledDocumentPath!)]);
        return;
      }
    }
    // Fallback：分享 JSON 摘要
    await Share.share(jsonEncode(record.filledData));
  }
}
```

---

## 7. 5 步驟檢測 Pipeline 詳細規格

### 7.1 狀態機

```dart
enum FormInspectionStep {
  uploadForm,   // Step 1: 上傳定檢表
  inspecting,   // Step 2: 逐項檢測
  preview,      // Step 3: 預覽結果
  exporting,    // Step 4: 產生表單
  done,         // Step 5: 完成
}

enum InspectionMode {
  photo,    // 拍照 AI 分析（預設）
  manual,   // 手動填寫
}
```

### 7.2 Step 1：上傳表單

```dart
// 流程：
// 1. FilePicker 選取 .xlsx/.xls/.docx
// 2. 嘗試後端 API 解析（POST /api/auto-fill/analyze-structure）
//    失敗 → 本地解析（excel package 讀取欄位名稱）
// 3. 產生 List<InspectionItemState>
// 4. 建立 SQLite draft 紀錄（status=draft）
// 5. 背景啟動 GPS 定位（非阻塞）
// 6. 進入 Step 2

Future<void> _pickAndAnalyzeForm() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['xlsx', 'xls', 'docx'],
    withData: true,
  );
  if (result == null || result.files.isEmpty) return;

  final file = result.files.first;
  final bytes = file.bytes ?? await File(file.path!).readAsBytes();

  setState(() { _isLoading = true; });

  try {
    // 嘗試後端，失敗 fallback 本地
    Map<String, dynamic> response;
    try {
      response = await BackendApiService().analyzeFormStructure(
        fileBytes: bytes, fileName: file.name);
    } catch (_) {
      response = await _localParseForm(bytes, file.name);
    }

    final fieldMap = response['field_map'] as List;
    _inspectionItems = fieldMap.map((f) => InspectionItemState(
      fieldId: f['field_id'],
      label: f['field_name'],
      fieldType: f['field_type'] ?? 'text',
    )).toList();

    // 建立 draft 紀錄
    _currentRecord = FormInspectionRecord(
      recordId: const Uuid().v4(),
      title: '${file.name} - ${DateFormat('MM/dd HH:mm').format(DateTime.now())}',
      sourceFileName: file.name,
      templateJson: jsonEncode(response),
    );
    await DatabaseService().insertFormRecord(_currentRecord!);

    // 背景 GPS（不阻塞 UI）
    _fetchLocationInBackground();

    setState(() {
      _currentStep = FormInspectionStep.inspecting;
      _isLoading = false;
    });
  } catch (e) {
    setState(() { _errorMessage = e.toString(); _isLoading = false; });
  }
}

// 本地 Excel 解析（無後端時的 fallback）
Future<Map<String, dynamic>> _localParseForm(Uint8List bytes, String fileName) async {
  final extension = p.extension(fileName).toLowerCase();
  if (extension == '.xlsx' || extension == '.xls') {
    final excel = Excel.decodeBytes(bytes);
    final fields = <Map<String, dynamic>>[];
    for (final table in excel.tables.values) {
      for (int i = 0; i < table.maxRows; i++) {
        for (int j = 0; j < table.maxCols; j++) {
          final cell = table.cell(CellIndex.indexByColumnRow(
            columnIndex: j, rowIndex: i));
          if (cell.value != null) {
            final text = cell.value.toString().trim();
            if (text.isNotEmpty) {
              fields.add({
                'field_id': 'field_${i}_${j}',
                'field_name': text,
                'field_type': 'text',
              });
            }
          }
        }
      }
      break; // 只處理第一個 sheet
    }
    return {'field_map': fields, 'file_type': 'xlsx'};
  }
  // docx: 讀取 archive，解析 word/document.xml 的文字節點
  throw UnimplementedError('DOCX 本地解析尚未實作');
}
```

### 7.3 Step 2：逐項檢測

**兩種子模式：**

**A. 一鍵自動檢測（推薦）**
```dart
// UI：底部 "自動檢測" 按鈕（teal 配色）

Future<void> _startAutoInspection() async {
  await _launchGuidedCapture();       // 引導批次拍照
  if (_completedCount > 0 && mounted) {
    setState(() => _currentStep = FormInspectionStep.preview);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('自動檢測完成！已完成 $_completedCount/${_inspectionItems.length} 項')),
    );
  }
}

// 啟動 GuidedCaptureScreen，傳入所有項目和智慧提示
Future<void> _launchGuidedCapture() async {
  final bindings = await Navigator.push<List<PhotoBinding>>(context,
    MaterialPageRoute(builder: (_) => GuidedCaptureScreen(
      items: _inspectionItems.map((item) => GuidedItem(
        taskId: item.fieldId,
        displayName: item.label,
        photoHint: _getSmartPhotoHint(item.label, item.fieldType),
      )).toList(),
    )));

  if (bindings == null || bindings.isEmpty) return;
  await _runBatchAnalysis(bindings);
}

// 批次 AI 分析（最多 3 個並行）
static const int _maxConcurrentAnalysis = 3;

Future<void> _runBatchAnalysis(List<PhotoBinding> bindings) async {
  setState(() {
    _isBatchAnalyzing = true;
    _batchTotal = bindings.length;
    _batchCompleted = 0;
    _batchErrors = 0;
  });

  final futures = <Future<void>>[];
  int running = 0;

  for (final binding in bindings) {
    final index = _inspectionItems.indexWhere((i) => i.fieldId == binding.taskId);
    if (index < 0) { setState(() => _batchCompleted++); continue; }

    final item = _inspectionItems[index];
    final imageBytes = await File(binding.filePath).readAsBytes();

    setState(() {
      item.photoPath = binding.filePath;
      item.photoBytes = imageBytes;
      item.isAnalyzing = true;
      _batchCurrentItem = item.label;
    });

    // Issue #14 修復：concurrency limit
    if (running >= _maxConcurrentAnalysis) {
      await Future.any(futures);
    }
    running++;

    final future = _runAIAnalysis(item, imageBytes, binding.filePath)
      .whenComplete(() {
        running--;
        setState(() {
          _batchCompleted++;
          if (!item.isCompleted) _batchErrors++;
        });
      });
    futures.add(future);
  }

  await Future.wait(futures);
  setState(() => _isBatchAnalyzing = false);
}
```

**B. 逐項手動拍照**
```dart
// UI：每個 InspectionItemState 對應一個 Card
//   - 顯示欄位名稱、拍照按鈕、AI 結果
//   - 切換到「手動填寫」: TextField + 提交

Future<void> _captureAndAnalyze(int index) async {
  final item = _inspectionItems[index];
  final XFile? image = await ImagePicker().pickImage(
    source: ImageSource.camera,
    maxWidth: 1920, maxHeight: 1080, imageQuality: 85,
  );
  if (image == null) return;
  final imageBytes = await image.readAsBytes();
  setState(() { item.photoBytes = imageBytes; item.isAnalyzing = true; });
  await _runAIAnalysis(item, imageBytes, image.path);
}
```

**AI 分析核心方法：**
```dart
Future<void> _runAIAnalysis(
    InspectionItemState item, Uint8List imageBytes, String photoPath) async {
  try {
    final result = await _geminiService!.analyzeInspectionPhoto(
      itemId: item.fieldId,
      itemDescription: item.label,
      imageBytes: imageBytes,
      photoPath: photoPath,
    );

    _mapAIResultToField(item, result);

    // 每次 AI 完成自動存 SQLite
    await _saveProgress();
  } catch (e) {
    setState(() { item.isAnalyzing = false; });
    // Issue #15 修復：debounced 錯誤通知（800ms）
    _showBatchError(e.toString());
  }
}

void _mapAIResultToField(InspectionItemState item, AnalysisResult result) {
  final aiResultMap = {
    'equipment_type': result.equipmentType,
    'readings': result.readings,
    'condition_assessment': result.conditionAssessment,
    'is_anomaly': result.isAnomaly,
    'anomaly_description': result.anomalyDescription,
    'estimated_size': result.estimatedSize,
  };

  setState(() {
    item.aiResult = aiResultMap;
    item.isCompleted = result.status == AnalysisStatus.completed;
    item.isAnalyzing = false;
    _filledData[item.fieldId] = item.displayValue;
    _currentRecord?.aiResults[item.fieldId] = aiResultMap;
  });
}
```

**批次進度覆蓋層：**
```dart
// 批次分析時顯示浮動進度層
if (_isBatchAnalyzing)
  Positioned.fill(
    child: Container(
      color: Colors.black54,
      child: Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  value: _batchTotal > 0 ? _batchCompleted / _batchTotal : null,
                ),
                const SizedBox(height: 16),
                Text('分析中 $_batchCompleted/$_batchTotal'),
                Text('目前項目：$_batchCurrentItem'),
                if (_batchErrors > 0)
                  Text('錯誤：$_batchErrors 項', style: TextStyle(color: Colors.red)),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
```

### 7.4 Step 3：預覽結果

```dart
// 顯示統計：
// - 已完成/總數
// - 異常數量（紅色警示）
// - 未完成數量

// 逐項列表顯示 verdict：
// ✅ 合格 / ❌ 不合格 / ✏️ 已填寫 / ⏳ 未檢測

// 法規判定（若有 judgeReadings API）：
// 🔴 不合格：絕緣電阻 0.5 MΩ < 1.0 MΩ（法規：屋內線路裝置規則 第59條）
// 🟡 警告：接地電阻 75Ω（接近上限 100Ω）
// 🟢 合格：漏電動作電流 20 mA ≤ 30 mA

Widget _buildPreviewStep() {
  final completed = _inspectionItems.where((i) => i.isCompleted).length;
  final anomalies = _inspectionItems.where((i) => i.aiResult?['is_anomaly'] == true).length;

  return Column(
    children: [
      // 統計摘要卡片
      _StatsCard(total: _inspectionItems.length,
        completed: completed, anomalies: anomalies),
      // 逐項列表
      ...(_inspectionItems.map((item) => _InspectionResultCard(item: item))),
    ],
  );
}
```

### 7.5 Step 4：匯出表單

```dart
Future<void> _exportForm() async {
  setState(() { _currentStep = FormInspectionStep.exporting; });

  try {
    // 嘗試後端回填原始格式
    final fillValues = _inspectionItems
      .where((i) => i.isCompleted)
      .map((i) => {'field_id': i.fieldId, 'value': i.displayValue ?? ''})
      .toList();

    Uint8List? docBytes;
    String? fileName;

    try {
      final response = await BackendApiService().executeFill(
        fileBytes: _uploadedFileBytes!,
        fileName: _fileName!,
        fillValues: fillValues,
      );
      docBytes = response['bytes'];
      fileName = response['file_name'];
    } catch (_) {
      // Fallback：JSON 摘要
      final summary = jsonEncode({
        'inspection_date': DateTime.now().toIso8601String(),
        'source_file': _fileName,
        'results': _filledData,
      });
      docBytes = Uint8List.fromList(utf8.encode(summary));
      fileName = '${p.basenameWithoutExtension(_fileName!)}_result.json';
    }

    // 儲存至持久化目錄（Issue #18 修復：不用 temp）
    final dir = await getApplicationDocumentsDirectory();
    final filePath = p.join(dir.path, fileName!);
    await File(filePath).writeAsBytes(docBytes!);

    setState(() {
      _exportedFilePath = filePath;
      _currentRecord = _currentRecord?.copyWith(
        status: FormRecordStatus.exported,
        filledDocumentPath: filePath,
      );
    });
    await DatabaseService().saveFormRecord(_currentRecord!);

    setState(() { _currentStep = FormInspectionStep.done; });
    // 自動觸發 AI 報告
    _autoGenerateReport();

  } catch (e) {
    _showError('匯出失敗：$e');
    setState(() { _currentStep = FormInspectionStep.preview; });
  }
}
```

### 7.6 Step 5：完成

```dart
Widget _buildDoneStep() {
  return Column(
    children: [
      // 統計卡片（完成數、異常數、位置）
      _CompletionStatsCard(record: _currentRecord!),

      // AI 摘要報告（自動產生，無需手動觸發）
      if (_isGeneratingReport)
        const CircularProgressIndicator()
      else if (_summaryReport != null)
        _MarkdownReportCard(markdown: _summaryReport!),

      // 操作按鈕
      Row(
        children: [
          ElevatedButton.icon(
            icon: const Icon(Icons.share),
            label: const Text('分享表單'),
            onPressed: () => _shareDocument(_exportedFilePath),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.description),
            label: const Text('分享報告'),
            onPressed: _summaryReport != null
              ? () => _shareReport(_summaryReport!)
              : null,
          ),
        ],
      ),
    ],
  );
}

// 進入完成步驟時自動觸發（Issue #28 功能）
bool _autoReportTriggered = false;

void _autoGenerateReport() {
  if (_autoReportTriggered) return;
  _autoReportTriggered = true;
  _generateSummaryReport();
}

Future<void> _generateSummaryReport() async {
  setState(() => _isGeneratingReport = true);
  try {
    final report = await _geminiService!.generateSummaryReport(
      records: _inspectionItems.map((i) => i.aiResult ?? {}).toList(),
    );
    setState(() {
      _summaryReport = report;
      _isGeneratingReport = false;
    });
    // 更新 SQLite
    if (_currentRecord != null) {
      _currentRecord = _currentRecord!.copyWith(summaryReport: report);
      await DatabaseService().saveFormRecord(_currentRecord!);
    }
  } catch (e) {
    setState(() => _isGeneratingReport = false);
  }
}
```

### 7.7 分享邏輯

```dart
Future<void> _shareDocument(String? filePath) async {
  final isConnected = await ConnectivityService().isConnected;

  if (isConnected && filePath != null && await File(filePath).exists()) {
    await Share.shareXFiles([XFile(filePath)]);
    await _markShared();
  } else {
    // 離線：加入待分享佇列
    await DatabaseService().saveFormRecord(
      _currentRecord!.copyWith(pendingShare: true));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已加入離線佇列，網路恢復後自動分享')),
    );
  }
}
```

---

## 8. Gemini AI Prompt 範本

### 8.1 模型設定

```dart
// lib/utils/constants.dart
class AppConstants {
  // 使用最新 Gemini 模型
  static const String geminiFlashModel = 'gemini-2.0-flash-exp';  // 圖像分析（快速）
  static const String geminiProModel = 'gemini-1.5-pro';           // 報告生成（高品質）
  static const Duration apiTimeout = Duration(seconds: 60);
}

// lib/services/gemini_service.dart 初始化
void init({String? apiKey}) {
  final key = apiKey ?? dotenv.env['GEMINI_API_KEY'];
  _flashModel = GenerativeModel(
    model: AppConstants.geminiFlashModel,
    apiKey: key!,
    generationConfig: GenerationConfig(
      temperature: 0.2,   // 低溫度：穩定輸出
      topP: 0.8, topK: 40, maxOutputTokens: 2048,
    ),
    requestOptions: const RequestOptions(apiVersion: 'v1beta'),
  );
  _proModel = GenerativeModel(
    model: AppConstants.geminiProModel,
    apiKey: key,
    generationConfig: GenerationConfig(
      temperature: 0.4,   // 略高：更有創意的報告
      topP: 0.9, topK: 50, maxOutputTokens: 4096,
    ),
    requestOptions: const RequestOptions(apiVersion: 'v1beta'),
  );
}
```

### 8.2 Prompt 一：從定檢表照片提取項目

```
您是一位專業的工業巡檢 AI。請分析提供的定檢表照片。

任務指令：
1. 識別照片中所有的巡檢項目和檢查點。
2. 提取每個檢查項目的描述文字。
3. 按順序組織這些項目。
4. 忽略表頭、日期、簽名等非檢查項目內容。

輸出格式：
請務必將您的所有發現以一個單一、最小化、不含 markdown 標記的 JSON 物件格式回傳。JSON 結構必須如下：
{
  "items": [
    "檢查項目1的描述",
    "檢查項目2的描述",
    ...
  ]
}

注意事項：
- 僅回傳純 JSON，不要包含任何其他文字
- 確保 items 是字符串數組
- 如果無法識別任何項目，回傳空數組 []
```

### 8.3 Prompt 二：標準設備巡檢分析（核心 Prompt）

```
您是一位專業的工業巡檢 AI。請分析提供的設備巡檢點圖像。

檢查項目：{itemDescription}

任務指令：
1. 識別圖像中的主要設備類型（例如：泵、閥門、壓力錶、馬達、管路、電氣設備等）。

2. **重要：仔細識別並提取所有數值類資料到 readings 物件**，包括：
   - 儀表讀數（溫度、壓力、速度、流量、電流、電壓、頻率等）
   - 物理測量值（尺寸、距離、厚度、角度等）
   - 狀態指標（百分比、計數、時間、週期等）
   - 每個數值必須獨立記錄，格式：{"欄位名稱": {"value": 數值, "unit": "單位"}}
   - 即使定檢表中沒有特別要求，只要照片中有數值，都應該提取

3. 仔細評估設備的整體狀況，重點描述任何磨損、生鏽、腐蝕、洩漏、裂縫或物理損壞的跡象。
   如果狀況良好，請註明「狀況良好」。

4. 根據您的評估，判斷是否存在需要關注的異常情況（is_anomaly: true/false）。

5. 如果發現異常，請詳細描述異常的特徵、位置和嚴重程度。

6. 如果圖像中包含信用卡（標準尺寸 85.6mm × 53.98mm）或其他已知尺寸的參照物，
   並且存在需要測量的異常，請嘗試估算異常特徵的真實尺寸。

輸出格式：
請務必將您的所有發現以一個單一、最小化、不含 markdown 標記的 JSON 物件格式回傳。
{
  "equipment_type": "string",
  "readings": {
    "溫度": {"value": 75.5, "unit": "°C"},
    "壓力": {"value": 2.5, "unit": "MPa"},
    "油位": {"value": 80, "unit": "%"}
  },
  "condition_assessment": "string（限 100 字以內）",
  "is_anomaly": boolean,
  "anomaly_description": "string or null",
  "estimated_size": "string or null"
}

注意事項：
- 僅回傳純 JSON，不要包含任何其他文字、markdown 標記或程式碼區塊標記
- **積極提取所有可見的數值資料**，這對檢測報告非常重要
- 如果無儀表讀數，readings 可以是 null 或空物件 {}
- **重要：所有文字內容必須使用繁體中文**
```

### 8.4 Prompt 三：快速分析（無預定項目）

```
您是一位專業的工業設備檢測 AI。請分析提供的設備圖像。

任務指令：
1. 識別圖像中的主要設備或場景類型。
2. **重要：仔細識別並提取所有數值類資料**，包括：
   - 儀表讀數（溫度、壓力、速度、電流、電壓等）
   - 物理測量值（尺寸、距離、角度等）
   - 狀態指標（百分比、次數、時間等）
   - 將每個數值獨立記錄在 readings 中
3. 評估設備狀況，識別任何異常。
4. 如果有信用卡等參照物，估算異常尺寸。

輸出格式：
{
  "equipment_type": "string",
  "readings": {
    "溫度": {"value": 75.5, "unit": "°C"}
  },
  "condition_assessment": "string（限 50 字以內）",
  "is_anomaly": boolean,
  "anomaly_description": "string or null",
  "estimated_size": "string or null"
}

注意事項：
- 僅回傳純 JSON，不要任何 markdown
- 積極尋找並提取所有數值資料
- 信用卡標準尺寸：85.6mm × 53.98mm
- 所有文字必須使用繁體中文
```

### 8.5 Prompt 四：高階主管摘要報告

```
您是一位經驗豐富的工廠營運經理 AI 助理。

背景資料：
以下是一個 JSON 陣列，包含了某次設施巡檢中每個檢查點的數據。每個物件代表一個巡檢點的發現。

{recordsJson}

任務指令：
請基於上述數據，生成一份專業的高階主管級巡檢摘要報告。報告應包含以下部分：

1. **總體概述**（2-3 句話）
   - 本次巡檢涵蓋的範圍（檢查了多少個點、主要設備類型）
   - 整體設備狀況的簡要評價

2. **關鍵發現**（條列式，每點 1-2 句話）
   - 列出所有被標記為異常（is_anomaly: true）的項目
   - 對於每個異常，說明：設備類型、異常描述、潛在影響
   - 按嚴重程度排序（最嚴重的在前）

3. **數據摘要**
   - 總檢查點數
   - 正常點數 vs 異常點數
   - 如果有儀表讀數，提及關鍵讀數的範圍或趨勢

4. **建議措施**（2-3 點）
   - 針對發現的異常，提出具體的後續行動建議
   - 優先級排序

輸出格式：
請以清晰、結構化的 Markdown 格式輸出報告，使用 ##、### 標題和項目符號列表。
語言：繁體中文。語氣：專業、客觀、簡潔。
不要回傳 JSON，直接回傳 Markdown 格式的報告內容。
```

### 8.6 JSON 提取輔助方法

```dart
// Gemini 有時在 JSON 外加入說明文字，需要提取純 JSON
String _extractJson(String responseText) {
  responseText = responseText.trim();
  final firstBrace = responseText.indexOf('{');
  final firstBracket = responseText.indexOf('[');

  int start = -1;
  if (firstBrace != -1 && firstBracket != -1) {
    start = firstBrace < firstBracket ? firstBrace : firstBracket;
  } else if (firstBrace != -1) {
    start = firstBrace;
  } else if (firstBracket != -1) {
    start = firstBracket;
  }

  final lastBrace = responseText.lastIndexOf('}');
  final lastBracket = responseText.lastIndexOf(']');
  int end = -1;
  if (lastBrace != -1 && lastBracket != -1) {
    end = lastBrace > lastBracket ? lastBrace : lastBracket;
  } else if (lastBrace != -1) {
    end = lastBrace;
  } else if (lastBracket != -1) {
    end = lastBracket;
  }

  if (start != -1 && end != -1 && end > start) {
    return responseText.substring(start, end + 1);
  }

  return responseText
    .replaceAll('```json', '').replaceAll('```', '').trim();
}
```

---

## 9. 後端 API 規格

> **注意**：後端 API 是可選的。App 需要能在沒有後端的情況下運作（降級模式）。

### 9.1 後端技術棧

```
框架：FastAPI (Python 3.10+)
依賴：
  - fastapi
  - uvicorn
  - python-multipart
  - openpyxl       # Excel 回填
  - python-docx    # Word 回填
  - google-generativeai  # Gemini
  - pydantic-settings
  - pytest + pytest-asyncio  # 測試
```

### 9.2 API 端點列表

| 方法 | 路徑 | 功能 | 必要性 |
|------|------|------|--------|
| POST | /api/auto-fill/analyze-structure | 分析 Excel/Word 結構 | 可選 |
| POST | /api/auto-fill/map-fields | AI 映射檢查結果到欄位 | 可選 |
| POST | /api/auto-fill/execute | 回填文件並回傳二進位 | 可選 |
| POST | /api/auto-fill/judge-readings | 法規標準判定（批次讀數） | 可選 |

### 9.3 judge-readings 端點（法規判定）

```python
# POST /api/auto-fill/judge-readings
# App 在批次 AI 分析後呼叫，取得法規合格/不合格判定

class ReadingItem(BaseModel):
    field_name: str       # 欄位名稱（用於匹配標準）
    value: float          # 量測值
    unit: str             # 單位（可能與標準單位不同）
    equipment_type: str = ""

class JudgeReadingsRequest(BaseModel):
    readings: List[ReadingItem]

class JudgmentResult(BaseModel):
    field_name: str
    judgment: str          # pass / fail / warning / unknown
    standard_id: Optional[str]
    regulation: Optional[str]
    pass_value: Optional[float]
    unit: Optional[str]
    converted_value: Optional[float]   # 換算後的值（若有換算）
    converted_unit: Optional[str]

class JudgeReadingsResponse(BaseModel):
    judgments: List[JudgmentResult]
    warnings: List[str]
    summary: dict          # {pass: n, fail: n, warning: n, unknown: n}

@router.post("/judge-readings", response_model=JudgeReadingsResponse)
async def judge_readings(request: JudgeReadingsRequest):
    svc = JudgmentService()
    judgments = []
    for item in request.readings:
        result = await svc.auto_judge(
            item.field_name, item.value, item.unit,
            equipment_type=item.equipment_type
        )
        judgments.append(JudgmentResult(**result))
    summary = {
        "pass": sum(1 for j in judgments if j.judgment == "pass"),
        "fail": sum(1 for j in judgments if j.judgment == "fail"),
        "warning": sum(1 for j in judgments if j.judgment == "warning"),
        "unknown": sum(1 for j in judgments if j.judgment == "unknown"),
    }
    return JudgeReadingsResponse(
        judgments=judgments,
        warnings=[f"{j.field_name}: 接近不合格" for j in judgments if j.judgment == "warning"],
        summary=summary,
    )
```

### 9.4 Flutter BackendApiService

```dart
// lib/services/backend_api_service.dart

class BackendApiService {
  static final BackendApiService _instance = BackendApiService._internal();
  factory BackendApiService() => _instance;
  BackendApiService._internal();

  // 後端 URL（可由 .env 設定，預設為 localhost）
  static String get _baseUrl =>
    dotenv.env['BACKEND_URL'] ?? 'http://10.0.2.2:8000';  // Android 模擬器

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 60),
  ));

  // 法規判定（離線時降級）
  Future<Map<String, dynamic>> judgeReadings(
      List<Map<String, dynamic>> readings) async {
    final isConnected = await ConnectivityService().isConnected;
    if (!isConnected) {
      return {'error': 'offline', 'judgments': []};
    }

    try {
      final response = await _dio.post(
        '$_baseUrl/api/auto-fill/judge-readings',
        data: {'readings': readings},
      );
      return response.data as Map<String, dynamic>;
    } catch (e) {
      return {'error': e.toString(), 'judgments': []};
    }
  }

  // 表單結構分析
  Future<Map<String, dynamic>> analyzeFormStructure({
    required Uint8List fileBytes,
    required String fileName,
  }) async {
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(fileBytes, filename: fileName),
    });
    final response = await _dio.post(
      '$_baseUrl/api/auto-fill/analyze-structure',
      data: formData,
    );
    return response.data as Map<String, dynamic>;
  }
}
```

---

## 10. 工業法規標準資料庫

### 10.1 四大類標準（共 56 項）

#### 電氣設備標準（15 項）

| standard_id | 設備類型 | 檢查項目 | 單位 | 判定條件 | 合格值 | 警告值 | 法規依據 |
|-------------|---------|---------|------|---------|--------|--------|---------|
| elec_insulation_lv | 低壓配電設備 | 絕緣電阻 | MΩ | ≥ | 1.0 | 2.0 | 屋內線路裝置規則 第59條 |
| elec_ground_resistance | 低壓配電設備 | 接地電阻 | Ω | ≤ | 100.0 | 80.0 | 屋內線路裝置規則 第59條 |
| elec_rcd_time | 低壓配電設備 | 漏電斷路器動作時間 | ms | ≤ | 100.0 | 80.0 | CNS 14816 |
| elec_rcd_current | 低壓配電設備 | 漏電斷路器動作電流 | mA | ≤ | 30.0 | 25.0 | CNS 14816 |
| elec_voltage_deviation | 低壓配電設備 | 電壓偏差率 | % | ≤ | 5.0 | 4.0 | 電業法施行細則 第38條 |
| elec_transformer_temp | 變壓器 | 變壓器油溫 | °C | ≤ | 85.0 | 75.0 | CNS 1390 |
| elec_transformer_insulation_hv | 高壓配電設備 | 高壓絕緣電阻 | MΩ | ≥ | 100.0 | 200.0 | 屋內線路裝置規則 第59條 |
| elec_contact_resistance | 低壓配電設備 | 接觸電阻 | μΩ | ≤ | 100.0 | 80.0 | IEC 62271 |
| elec_harmonic_thd | 低壓配電設備 | 諧波失真率 | % | ≤ | 5.0 | 4.0 | IEEE 519 |
| elec_power_factor | 低壓配電設備 | 功率因數 | — | ≥ | 0.85 | 0.90 | — |
| elec_motor_insulation | 電動機 | 馬達絕緣電阻 | MΩ | ≥ | 1.0 | 2.0 | IEC 60034-1 |
| elec_motor_temp | 電動機 | 馬達溫度 | °C | ≤ | 80.0 | 70.0 | IEC 60034-1 |
| elec_motor_vibration | 電動機 | 馬達振動速度 | mm/s | ≤ | 7.1 | 4.5 | ISO 10816 |
| elec_battery_voltage | 蓄電池 | 電池電壓 | V | range | [24.0, 28.8] | — | CNS 14796 |
| elec_battery_internal_resistance | 蓄電池 | 電池內阻 | mΩ | ≤ | 10.0 | 8.0 | CNS 14796 |

#### 消防設備標準（15 項）

| standard_id | 設備類型 | 檢查項目 | 單位 | 合格條件 | 法規依據 |
|-------------|---------|---------|------|---------|---------|
| fire_sprinkler_pressure | 自動撒水設備 | 撒水頭水壓 | kPa | ≥ 98.0 | 各類場所消防安全設備設置標準 第47條 |
| fire_hydrant_pressure | 消防栓 | 消防栓水壓 | kPa | ≥ 147.0 | 設置標準 第30條 |
| fire_extinguisher_pressure | 滅火器 | 滅火器壓力 | MPa | range [1.2, 1.8] | CNS 11176 |
| fire_alarm_temp | 火警感知器 | 差動式感知器動作溫度 | °C | ≤ 70.0 | CNS 10522 |
| fire_emergency_light | 緊急照明設備 | 緊急照明照度 | lux | ≥ 1.0 | 設置標準 第186條 |
| ... (10 更多項目) | | | | | |

#### 機械設備標準（15 項）

| standard_id | 設備類型 | 檢查項目 | 單位 | 合格條件 | 法規依據 |
|-------------|---------|---------|------|---------|---------|
| mech_pump_vibration | 泵 | 泵振動速度 | mm/s | ≤ 7.1 | ISO 10816 |
| mech_pump_temp | 泵 | 泵軸承溫度 | °C | ≤ 80.0 | — |
| mech_compressor_pressure | 空氣壓縮機 | 工作壓力 | MPa | ≤ 0.9 | CNS 7952 |
| mech_conveyor_belt_tension | 輸送帶 | 皮帶張力偏差 | % | ≤ 10.0 | — |
| mech_crane_load_test | 起重機 | 靜荷重測試 | % | ≤ 125.0 | 起重機具安全規則 |
| ... (10 更多項目) | | | | | |

#### 壓力容器標準（11 項）

| standard_id | 設備類型 | 檢查項目 | 單位 | 合格條件 | 法規依據 |
|-------------|---------|---------|------|---------|---------|
| pressure_vessel_test | 壓力容器 | 耐壓測試壓力 | MPa | ≥ 1.5× 設計壓力 | 鍋爐及壓力容器安全規則 |
| boiler_steam_pressure | 鍋爐 | 蒸汽壓力 | MPa | ≤ 設計值 1.05× | 鍋爐及壓力容器安全規則 第16條 |
| boiler_water_level | 鍋爐 | 水位 | % | range [40, 80] | — |
| ... (8 更多項目) | | | | | |

### 10.2 標準資料結構

```python
# 每個標準的完整欄位
{
    "standard_id": "elec_insulation_lv",
    "category": "electrical",          # electrical/fire/mechanical/pressure
    "equipment_type": "低壓配電設備",
    "inspection_item": "絕緣電阻",
    "keywords": ["絕緣", "insulation", "IR"],  # 模糊匹配關鍵字
    "unit": "MΩ",
    "pass_condition": "gte",           # gte/lte/range/eq/in_set
    "pass_value": 1.0,                 # 數值 或 [min, max] 或 set
    "warning_value": 2.0,              # 接近不合格的警告線
    "regulation": "屋內線路裝置規則 第59條",
    "notes": "三相各相分別量測，對地絕緣電阻",
}
```

### 10.3 標準匹配演算法

**重要：欄位名稱相關性為必要條件（防止假陽性）**

```python
def find_matching_standard(
    field_name: str, unit: str, equipment_type: str = ""
) -> Optional[dict]:
    """
    匹配優先序：
    1. inspection_item 完全符合（+10 分）
    2. keywords 包含在欄位名中（+5 分/個）
    3. 設備類型吻合（+4 分）
    4. 單位相符或可換算（+3 分）

    重要安全規則：
    - 至少需要 inspection_item 或一個 keyword 命中（欄位名稱相關性必要條件）
    - 單純設備類型匹配不足以判定，必須有欄位名稱關聯
    """
    best_standard = None
    best_score = 0

    for std in ALL_STANDARDS:
        score = 0
        has_field_relevance = False  # 必要條件

        # inspection_item 完全相符
        if std['inspection_item'] in field_name or field_name in std['inspection_item']:
            score += 10
            has_field_relevance = True

        # keywords 匹配
        for kw in std.get('keywords', []):
            if kw.lower() in field_name.lower():
                score += 5
                has_field_relevance = True

        # 必要條件未達到：跳過（防止假陽性）
        if not has_field_relevance:
            continue

        # 設備類型加分
        if equipment_type and std['equipment_type'] in equipment_type:
            score += 4

        # 單位加分
        if unit and normalize_unit(unit) == normalize_unit(std.get('unit', '')):
            score += 3

        if score > best_score:
            best_score = score
            best_standard = std

    return best_standard if best_score >= 5 else None
```

### 10.4 判定邏輯

```python
def judge_value(standard: dict, value: float) -> str:
    cond = standard['pass_condition']
    pass_val = standard['pass_value']
    warn_val = standard.get('warning_value')

    if cond == 'gte':
        if value >= pass_val:
            return 'pass' if warn_val is None or value >= warn_val else 'warning'
        return 'fail'
    elif cond == 'lte':
        if value <= pass_val:
            return 'pass' if warn_val is None or value <= warn_val else 'warning'
        return 'fail'
    elif cond == 'range':
        lo, hi = pass_val  # [min, max]
        return 'pass' if lo <= value <= hi else 'fail'
    elif cond == 'eq':
        return 'pass' if abs(value - pass_val) < 1e-9 else 'fail'
    return 'unknown'
```

---

## 11. 單位換算引擎

### 11.1 換算因子表

```python
# (維度, SI基礎換算因子)
_CONVERSION_FACTORS = {
    # 電阻
    "Ω":  ("resistance", 1.0),
    "kΩ": ("resistance", 1e3),
    "MΩ": ("resistance", 1e6),
    "μΩ": ("resistance", 1e-6),
    # 電流
    "A":  ("current", 1.0),
    "mA": ("current", 1e-3),
    "μA": ("current", 1e-6),
    # 電壓
    "V":  ("voltage", 1.0),
    "kV": ("voltage", 1e3),
    "mV": ("voltage", 1e-3),
    # 壓力（以 kPa 為基準）
    "Pa":     ("pressure", 1e-3),
    "kPa":    ("pressure", 1.0),
    "MPa":    ("pressure", 1e3),
    "bar":    ("pressure", 100.0),
    "kgf/cm²": ("pressure", 98.0665),
    # 時間
    "s":  ("time", 1.0),
    "ms": ("time", 1e-3),
    "μs": ("time", 1e-6),
    # 長度
    "m":  ("length", 1.0),
    "mm": ("length", 1e-3),
    "cm": ("length", 1e-2),
    # 速度
    "mm/s": ("velocity", 1.0),
    "m/s":  ("velocity", 1e3),
}

# 溫度換算（特殊處理，非線性）
TEMPERATURE_UNITS = {"°C", "°F", "K"}
```

### 11.2 單位正規化

```python
_UNIT_ALIASES = {
    # 溫度
    "℃": "°C", "degC": "°C", "°c": "°C",
    "℉": "°F", "degF": "°F",
    # 電阻
    "Mohm": "MΩ", "mohm": "MΩ", "MOHM": "MΩ",
    "kohm": "kΩ", "KOHM": "kΩ",
    "ohm": "Ω", "Ohm": "Ω", "OHM": "Ω",
    # 壓力
    "kgf/cm2": "kgf/cm²",
    "kg/cm²": "kgf/cm²", "kg/cm2": "kgf/cm²",
    # Micro prefix
    "uΩ": "μΩ", "uA": "μA", "uV": "μV",
}

def normalize_unit(unit: str) -> str:
    if not unit:
        return ""
    unit = unit.strip()
    return _UNIT_ALIASES.get(unit, _UNIT_ALIASES.get(unit.lower(), unit))
```

### 11.3 換算函式

```python
def convert_value(
    value, from_unit: str, to_unit: str
) -> tuple[Optional[float], bool]:
    """
    回傳 (換算後的值, 是否成功)
    失敗時回傳 (None, False)
    """
    if not isinstance(value, (int, float)):
        return None, False
    if not from_unit or not to_unit:
        return None, False

    from_n = normalize_unit(from_unit)
    to_n = normalize_unit(to_unit)

    # 同單位：直接回傳
    if from_n == to_n:
        return float(value), True

    # 溫度特殊處理
    if from_n in TEMPERATURE_UNITS and to_n in TEMPERATURE_UNITS:
        return _convert_temperature(float(value), from_n, to_n), True
    if from_n in TEMPERATURE_UNITS or to_n in TEMPERATURE_UNITS:
        return None, False  # 溫度不能與其他維度換算

    # 一般換算
    from_info = _CONVERSION_FACTORS.get(from_n)
    to_info = _CONVERSION_FACTORS.get(to_n)

    if not from_info or not to_info:
        return None, False

    from_dim, from_factor = from_info
    to_dim, to_factor = to_info

    if from_dim != to_dim:
        return None, False  # 維度不相容

    return float(value) * from_factor / to_factor, True

def _convert_temperature(value: float, from_unit: str, to_unit: str) -> float:
    # 先轉 °C
    if from_unit == "°F":
        celsius = (value - 32) * 5 / 9
    elif from_unit == "K":
        celsius = value - 273.15
    else:
        celsius = value

    # 再轉目標單位
    if to_unit == "°F":
        return celsius * 9 / 5 + 32
    elif to_unit == "K":
        return celsius + 273.15
    return celsius
```

### 11.4 auto_judge 換算流程

```python
async def auto_judge(
    field_name: str,
    measured_value: float,
    unit: str,
    equipment_type: str = ""
) -> dict:
    std = self._standards_db.find_matching_standard(
        field_name, unit, equipment_type)

    if std is None:
        return {
            "judgment": "unknown",
            "standard_id": None,
            "regulation": None,
            "measured_value": measured_value,
            "unit": unit,
            "converted_value": None,
            "converted_unit": None,
        }

    std_unit = std.get("unit", "")
    value_for_judge = measured_value
    converted = False
    converted_value = None

    # 換算到標準單位
    if unit and std_unit:
        cv, ok = self._standards_db.convert_value(measured_value, unit, std_unit)
        if ok and cv is not None:
            norm_from = normalize_unit(unit)
            norm_to = normalize_unit(std_unit)
            if norm_from != norm_to:  # 真的有換算（非同單位）
                value_for_judge = cv
                converted = True
                converted_value = cv

    result = self._standards_db.judge_value(std, value_for_judge)

    return {
        "judgment": result,
        "standard_id": std["standard_id"],
        "regulation": std.get("regulation"),
        "pass_value": std.get("pass_value"),
        "warning_value": std.get("warning_value"),
        "measured_value": measured_value,
        "unit": unit,
        "converted_value": converted_value if converted else None,
        "converted_unit": std_unit if converted else None,
    }
```

---

## 12. 離線優先架構

### 12.1 ConnectivityService

```dart
// lib/services/connectivity_service.dart

class ConnectivityService {
  static final ConnectivityService _instance = ConnectivityService._internal();
  factory ConnectivityService() => _instance;
  ConnectivityService._internal();

  final Connectivity _connectivity = Connectivity();
  final StreamController<bool> _controller = StreamController<bool>.broadcast();

  Stream<bool> get onConnectivityChanged => _controller.stream;

  Future<bool> get isConnected async {
    final result = await _connectivity.checkConnectivity();
    return result != ConnectivityResult.none;
  }

  void startMonitoring() {
    _connectivity.onConnectivityChanged.listen((result) {
      _controller.add(result != ConnectivityResult.none);
    });
  }
}
```

### 12.2 ShareQueueService

```dart
// lib/services/share_queue_service.dart

class ShareQueueService {
  static final ShareQueueService _instance = ShareQueueService._internal();
  factory ShareQueueService() => _instance;
  ShareQueueService._internal();

  StreamSubscription<bool>? _connectivitySub;

  void startListening() {
    _connectivitySub = ConnectivityService().onConnectivityChanged.listen((connected) {
      if (connected) _processQueue();
    });
  }

  void dispose() => _connectivitySub?.cancel();

  Future<void> _processQueue() async {
    final pending = await DatabaseService().getPendingShareRecords();
    for (final record in pending) {
      if (record.filledDocumentPath != null) {
        // Issue #18 修復：先檢查檔案是否仍存在
        final file = File(record.filledDocumentPath!);
        if (await file.exists()) {
          await Share.shareXFiles([XFile(record.filledDocumentPath!)]);
        } else {
          // 檔案遺失：改分享 JSON 摘要
          await Share.share(jsonEncode(record.filledData));
        }
      }
      // 標記已分享
      await DatabaseService().saveFormRecord(
        record.copyWith(pendingShare: false, status: FormRecordStatus.shared));
    }
  }
}
```

### 12.3 GuidedCaptureScreen

```dart
// lib/screens/guided_capture_screen.dart
// 功能：批次引導使用者逐一拍攝所有檢查項目

class GuidedItem {
  final String taskId;
  final String displayName;
  final String photoHint;    // 智慧拍照提示
}

class PhotoBinding {
  final String taskId;
  final String filePath;
  final Uint8List? photoBytes;
}

class GuidedCaptureScreen extends StatefulWidget {
  final List<GuidedItem> items;  // 所有需拍照的項目

  @override
  State<GuidedCaptureScreen> createState() => _GuidedCaptureScreenState();
}

// 流程：
// - 顯示目前項目：名稱、拍攝提示、已完成 N/總數
// - 底部：[上一項] [拍照] [下一項（跳過）]
// - 拍照後顯示縮圖預覽
// - 全部完成後回傳 List<PhotoBinding>
```

---

## 13. Android 設定與權限

### 13.1 AndroidManifest.xml

```xml
<!-- android/app/src/main/AndroidManifest.xml -->
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <uses-permission android:name="android.permission.INTERNET"/>
  <uses-permission android:name="android.permission.CAMERA"/>
  <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
  <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
  <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>
  <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
    android:maxSdkVersion="28"/>
  <!-- Android 13+ 分粒度照片權限 -->
  <uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>

  <uses-feature android:name="android.hardware.camera" android:required="false"/>

  <application
    android:label="InduSpect AI"
    android:name="${applicationName}"
    android:icon="@mipmap/ic_launcher"
    android:usesCleartextTraffic="true">  <!-- 允許 HTTP（開發用，正式應改 HTTPS） -->

    <activity ...>
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
    </activity>

    <!-- FileProvider（用於分享檔案） -->
    <provider
      android:name="androidx.core.content.FileProvider"
      android:authorities="${applicationId}.fileprovider"
      android:exported="false"
      android:grantUriPermissions="true">
      <meta-data
        android:name="android.support.FILE_PROVIDER_PATHS"
        android:resource="@xml/file_paths"/>
    </provider>
  </application>
</manifest>
```

### 13.2 file_paths.xml

```xml
<!-- android/app/src/main/res/xml/file_paths.xml -->
<?xml version="1.0" encoding="utf-8"?>
<paths>
  <external-files-path name="documents" path="Documents/"/>
  <files-path name="internal_files" path="."/>
  <cache-path name="cache" path="."/>
</paths>
```

### 13.3 build.gradle（app 層）

```groovy
android {
  compileSdkVersion 34
  defaultConfig {
    applicationId "com.induspect.ai"
    minSdkVersion 21
    targetSdkVersion 34
    versionCode 1
    versionName "1.0.0"
  }
  compileOptions {
    sourceCompatibility JavaVersion.VERSION_17
    targetCompatibility JavaVersion.VERSION_17
  }
}
```

### 13.4 權限請求（Runtime）

```dart
// 在 main.dart 啟動時或進入相機前請求權限
Future<void> _requestPermissions() async {
  await [
    Permission.camera,
    Permission.location,
    Permission.photos,
  ].request();
}
```

---

## 14. 關鍵演算法

### 14.1 智慧拍照提示

根據欄位名稱關鍵字，給出專業拍攝指引：

```dart
String _getSmartPhotoHint(String label, String fieldType) {
  final lower = label.toLowerCase();
  if (lower.contains('溫度') || lower.contains('temperature'))
    return '請正面拍攝溫度計或溫度顯示器，確保數值清晰可讀';
  if (lower.contains('壓力') || lower.contains('pressure'))
    return '請正面拍攝壓力錶，確保指針位置和刻度清晰可見';
  if (lower.contains('電壓') || lower.contains('voltage') ||
      lower.contains('電流') || lower.contains('current'))
    return '請拍攝電氣儀表面板，確保所有讀數清晰可見';
  if (lower.contains('絕緣') || lower.contains('insulation'))
    return '請拍攝絕緣電阻測試結果，確保數值和單位清晰';
  if (lower.contains('外觀') || lower.contains('appearance'))
    return '請拍攝設備整體外觀，注意是否有裂痕、鏽蝕、漏油等異常';
  if (lower.contains('漏') || lower.contains('leak'))
    return '請拍攝可能滲漏的位置，包含接頭、密封處和地面痕跡';
  if (lower.contains('油') || lower.contains('oil'))
    return '請拍攝油位視窗或油品顏色，確認油位高度';
  if (lower.contains('鏽') || lower.contains('腐蝕') || lower.contains('corrosion'))
    return '請近距離拍攝鏽蝕區域，可放置信用卡作為尺寸參照';
  if (fieldType == 'number' || fieldType == 'measurement')
    return '請拍攝「$label」的儀表，確保讀數清晰';
  if (fieldType == 'radio')
    return '請拍攝「$label」的實際狀態，AI 將自動判定合格/不合格';
  return '請拍攝「$label」的照片，確保光線充足、畫面清晰';
}
```

### 14.2 錯誤通知 Debounce

```dart
// Issue #15 修復：批次分析時 SnackBar 防抖
Timer? _errorDebounce;
final List<String> _pendingErrors = [];

void _showBatchError(String error) {
  _pendingErrors.add(error);
  _errorDebounce?.cancel();
  _errorDebounce = Timer(const Duration(milliseconds: 800), () {
    if (!mounted) return;
    final count = _pendingErrors.length;
    final msg = count == 1
      ? '分析失敗：${_pendingErrors.first}'
      : '${count} 項分析失敗，請檢查照片品質';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
    _pendingErrors.clear();
  });
}
```

### 14.3 GPS 定位

```dart
// lib/services/location_service.dart

class LocationData {
  final double latitude;
  final double longitude;
  final String? locationName;
}

class LocationService {
  Future<LocationData?> getCurrentLocation() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );

      String? locationName;
      // Issue #19 修復：Web 平台跳過 geocoding
      if (!kIsWeb) {
        try {
          final placemarks = await placemarkFromCoordinates(
            position.latitude, position.longitude);
          if (placemarks.isNotEmpty) {
            final p = placemarks.first;
            locationName = [p.locality, p.administrativeArea]
              .where((s) => s != null && s.isNotEmpty).join(', ');
          }
        } catch (_) {} // geocoding 失敗不影響主流程
      }

      return LocationData(
        latitude: position.latitude,
        longitude: position.longitude,
        locationName: locationName,
      );
    } catch (e) {
      return null;
    }
  }
}
```

### 14.4 照片命名規則

```dart
// lib/services/photo_service.dart

class PhotoService {
  static String generatePhotoName({
    required String recordId,
    required String fieldId,
    required int sequence,
    String extension = 'jpg',
  }) {
    // 格式：{recordId前8碼}_{fieldId前16碼}_{序號3位}.{ext}
    final rid = recordId.replaceAll('-', '').substring(0, 8);
    final fid = fieldId.substring(0, min(16, fieldId.length))
      .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final seq = sequence.toString().padLeft(3, '0');
    return '${rid}_${fid}_$seq.$extension';
  }
}
```

---

## 15. UI 設計規範

### 15.1 色彩系統

```dart
class AppColors {
  static const Color primary = Color(0xFF1976D2);     // 主色（藍）
  static const Color secondary = Color(0xFF424242);   // 次色（深灰）
  static const Color success = Color(0xFF4CAF50);     // 成功（綠）
  static const Color warning = Color(0xFFFFC107);     // 警告（黃）
  static const Color error = Color(0xFFF44336);       // 錯誤（紅）
  static const Color info = Color(0xFF2196F3);        // 資訊（淺藍）
  static const Color teal = Color(0xFF009688);        // 強調（青綠，自動檢測按鈕）
  static const Color backgroundLight = Color(0xFFF5F5F5);
}
```

### 15.2 步驟指示器

```dart
// FormInspectionScreen 頂部的步驟進度條
// Step 1 → Step 2 → Step 3 → Step 4 → Step 5
// 使用 Stepper widget 或自訂實作

Widget _buildStepIndicator() {
  return Row(
    children: FormInspectionStep.values.map((step) {
      final isCurrent = step == _currentStep;
      final isPast = step.index < _currentStep.index;
      return Expanded(
        child: Column(
          children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isPast ? AppColors.success
                  : isCurrent ? AppColors.primary
                  : AppColors.stepInactive,
              ),
              child: Center(child: Text('${step.index + 1}',
                style: const TextStyle(color: Colors.white))),
            ),
            Text(_stepLabel(step), style: const TextStyle(fontSize: 10)),
          ],
        ),
      );
    }).toList(),
  );
}

String _stepLabel(FormInspectionStep step) {
  switch (step) {
    case FormInspectionStep.uploadForm: return '上傳表單';
    case FormInspectionStep.inspecting: return '檢測';
    case FormInspectionStep.preview: return '預覽';
    case FormInspectionStep.exporting: return '匯出';
    case FormInspectionStep.done: return '完成';
  }
}
```

### 15.3 狀態徽章

```dart
Widget _buildStatusBadge(FormRecordStatus status) {
  final (label, color) = switch (status) {
    FormRecordStatus.draft => ('草稿', AppColors.warning),
    FormRecordStatus.completed => ('已完成', AppColors.info),
    FormRecordStatus.exported => ('已匯出', AppColors.success),
    FormRecordStatus.shared => ('已分享', AppColors.primary),
  };
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withOpacity(0.2),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color),
    ),
    child: Text(label, style: TextStyle(color: color, fontSize: 12)),
  );
}
```

### 15.4 判定顯示

```dart
Widget _buildVerdictIcon(String verdict) {
  switch (verdict) {
    case '合格':   return const Icon(Icons.check_circle, color: AppColors.success);
    case '不合格': return const Icon(Icons.cancel, color: AppColors.error);
    case '警告':   return const Icon(Icons.warning, color: AppColors.warning);
    case '已填寫': return const Icon(Icons.edit, color: AppColors.info);
    default:       return const Icon(Icons.help_outline, color: Colors.grey);
  }
}
```

---

## 16. 環境變數與 API Key 設定

### 16.1 .env 檔案

```
# .env（不提交到版控）
GEMINI_API_KEY=your_gemini_api_key_here
BACKEND_URL=http://10.0.2.2:8000
```

### 16.2 SettingsScreen（App 內設定）

```dart
// lib/screens/settings_screen.dart
// 讓使用者在 App 內輸入 Gemini API Key
// 儲存至 SharedPreferences

class SettingsScreen extends StatefulWidget { ... }

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _apiKeyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedKey = prefs.getString('gemini_api_key') ?? '';
    _apiKeyController.text = savedKey;
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gemini_api_key', _apiKeyController.text.trim());
    // 重新初始化 GeminiService
    GeminiService().init(apiKey: _apiKeyController.text.trim());
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('設定已儲存')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _apiKeyController,
              decoration: const InputDecoration(
                labelText: 'Gemini API Key',
                hintText: '請輸入您的 Google AI Studio API Key',
                helperText: '從 aistudio.google.com 取得',
              ),
              obscureText: true,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _saveSettings,
              child: const Text('儲存'),
            ),
          ],
        ),
      ),
    );
  }
}
```

### 16.3 GeminiService 動態 API Key

```dart
// 優先順序：SharedPreferences > .env > 手動輸入
void init({String? apiKey}) async {
  String? effectiveKey = apiKey;

  if (effectiveKey == null) {
    final prefs = await SharedPreferences.getInstance();
    effectiveKey = prefs.getString('gemini_api_key');
  }

  effectiveKey ??= dotenv.env['GEMINI_API_KEY'];

  if (effectiveKey == null || effectiveKey.isEmpty) {
    throw Exception('請在設定中輸入 Gemini API Key');
  }
  // ... 初始化模型
}
```

---

## 17. 測試規格

### 17.1 Flutter 測試（目標 46 tests）

```bash
flutter test test/form_inspection_record_test.dart \
              test/database_service_test.dart \
              test/inspection_item_state_test.dart \
              test/photo_service_test.dart
```

| 測試檔案 | 數量 | 覆蓋範圍 |
|---------|------|---------|
| form_inspection_record_test.dart | 17 | toMap/fromMap、null 處理、舊格式向後相容、computed getters、copyWith |
| database_service_test.dart | 12 | CRUD、排序、搜尋、GPS 持久化、UNIQUE 約束 |
| inspection_item_state_test.dart | 11 | displayValue/verdict 邏輯、TextEditingController 生命週期 |
| photo_service_test.dart | 6 | 照片命名格式、序號補零、截斷 |

**DB 測試設定（使用 in-memory SQLite）：**
```dart
// test/database_service_test.dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  // ...
}
```

### 17.2 Python 後端測試（目標 143 tests）

```bash
cd backend
python3 -m pytest tests/ --asyncio-mode=auto -v
```

重點測試檔案：
- `tests/test_unit_conversion_judgment.py`（25 tests）：單位換算、判定

---

## 18. 實作優先順序

### Phase 1：基礎可用（MVP）

1. Flutter 專案架構 + 依賴安裝
2. SQLite schema + DatabaseService CRUD
3. `FormInspectionRecord` model
4. `GeminiService` 初始化 + 4 個 Prompt
5. Step 1：FilePicker 上傳 + 本地 Excel 解析
6. Step 2：單張拍照 + AI 分析 + 顯示結果
7. Step 3：預覽頁面
8. Step 5：完成頁面 + 分享
9. DashboardScreen + 最近紀錄
10. SettingsScreen（API Key 設定）

### Phase 2：核心功能完整

11. GuidedCaptureScreen（批次引導拍照）
12. 批次 AI 分析（含 concurrency limit）
13. 進度覆蓋層（實時顯示）
14. AI 摘要報告自動產生
15. UnifiedHistoryScreen（搜尋 + 編輯 + 刪除 + 重新分享）
16. GPS 定位 + 反向地理編碼
17. 離線分享佇列（ShareQueueService）
18. Step 4：後端回填（有後端時）/ JSON fallback

### Phase 3：增強功能

19. 後端 FastAPI 服務（可選）
20. 法規標準判定（judgeReadings API）
21. 單位換算引擎
22. 判定結果在預覽頁顯示
23. Android APK 打包 + 圖示設定

### Phase 4：優化與測試

24. 寫 Flutter 測試（46 tests）
25. 效能優化（大量紀錄分頁載入）
26. UI 微調（深色模式、無障礙）
27. 錯誤處理完善

---

## 附錄 A：常見問題與解決方案

| 問題 | 解決方案 |
|------|---------|
| Gemini 回傳夾雜 markdown | 用 `_extractJson()` 擷取 `{...}` 區間 |
| 批次分析 OOM | `_maxConcurrentAnalysis = 3`，用 `Future.any()` 控制 |
| 分享後找不到檔案 | 用 `getApplicationDocumentsDirectory()` 存檔，不用 temp |
| geocoding 在測試/Web 失敗 | `if (!kIsWeb)` 包住，捕捉 exception |
| 500 kΩ 誤判為 ≥1.0 MΩ 合格 | 判定前換算至標準單位（`convert_value()`） |
| 不相關欄位被湊到標準 | `find_matching_standard` 要求欄位名稱相關性為必要條件 |
| SQLite 更新 mutate 原物件 | 先做 `Map.from(record.toMap())`，再設 `updated_at` |

---

## 附錄 B：一鍵建立 Android APK

```bash
# 確認環境
flutter doctor -v

# 安裝依賴
cd flutter_app
flutter pub get

# 靜態分析
flutter analyze --no-pub

# 執行測試
flutter test test/form_inspection_record_test.dart \
              test/database_service_test.dart \
              test/inspection_item_state_test.dart \
              test/photo_service_test.dart

# 建置 Debug APK
flutter build apk --debug

# 建置 Release APK（需設定 keystore）
flutter build apk --release
```

APK 輸出路徑：`build/app/outputs/flutter-apk/app-release.apk`

---

*文件版本：2026-05-28 | InduSpect AI v1.0.0*
