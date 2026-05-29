# 定檢表模板系統技術規格

> **專案**: InduSpect AI - 智慧巡檢系統
> **版本**: v2.0 規格書
> **建立日期**: 2025-11-04
> **負責團隊**: doflab 劉瑞弘老師研究團隊

---

## 🎯 核心需求

### 業務目標
1. **模板匯入**: 支援 Excel/Word 定檢表格式匯入
2. **引導填寫**: App 依照表格內容引導使用者逐項完成
3. **混合填寫**: 支援手動輸入、拍照 AI 分析自動填入、純拍照項目
4. **生成報告**: 數值填回表格，產生帶簽名的 PDF 文件
5. **後端整合**: 資料上傳至後端資料庫，支援監控與統計系統整合
6. **週期提醒**: 設備定檢週期自動提醒

### 核心挑戰與解決方案
| 挑戰 | 解決方案 |
|------|---------|
| Excel/Word 格式多樣化 | 採用 JSON 中介格式 + 模板編輯器 |
| PDF 回填難度高 | 使用 Placeholder 模板 + PDF 填充技術 |
| 離線與線上同步 | 本地優先 + 背景同步機制 |
| 彈性與標準化平衡 | 自定義模板 + 預設範本庫 |

---

## 📋 系統架構設計

### 整體流程

```
┌─────────────────────────────────────────────────────────────┐
│                    Phase 1: 模板建立                         │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  Excel/Word    ──匯入──>  模板編輯器  ──儲存──>  JSON 模板   │
│   定檢表                  (Web/App)               (.json)    │
│                                                               │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    Phase 2: 現場檢測                         │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  1. 選擇模板 & 設備                                           │
│  2. 引導式填寫                                                │
│     ├─ 文字/數值欄位：手動輸入或 AI 辨識                      │
│     ├─ 照片欄位：拍照 + AI 分析自動填入                       │
│     ├─ 選項欄位：單選/多選/下拉式選單                         │
│     └─ 簽名欄位：手寫簽名                                     │
│  3. 離線儲存（本地 SQLite）                                   │
│                                                               │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    Phase 3: 報告生成                         │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  填寫完成   ──>   PDF 模板    ──填充──>   簽名 PDF          │
│   資料            (含 Placeholder)            (.pdf)         │
│                                                               │
│  同步上傳   ──>   後端資料庫  ──整合──>   監控/統計系統      │
│                  (Supabase/Firebase)                         │
│                                                               │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    Phase 4: 持續管理                         │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  設備管理   ──>   定檢週期設定  ──>   自動提醒通知           │
│  歷史查詢   ──>   趨勢分析      ──>   預測性維護             │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

---

## 🔄 動態模板建立 (Dynamic Template Creation)

> **新增於 v2.1** — 支援從真實 Excel/Word 定檢表自動建立 InspectionTemplate

### 概述

傳統流程需要手動定義模板 JSON，現在系統支援直接上傳真實的定檢表文件，透過 AI + 規則引擎自動分析文件結構並產生標準 `InspectionTemplate` JSON。

### 架構流程

```
┌──────────────────────────────────────────────────────────────────┐
│                   動態模板建立 Pipeline                            │
├──────────────────────────────────────────────────────────────────┤
│                                                                    │
│  上傳 Excel/Word  ──>  深度結構分析  ──>  AI 轉換 (Gemini)       │
│   定檢表文件           (field_map)        ↓ 失敗時               │
│                                          ↓                       │
│                                     Fallback 規則引擎            │
│                                          ↓                       │
│                                   InspectionTemplate JSON        │
│                                     + source_file 綁定           │
│                                                                    │
└──────────────────────────────────────────────────────────────────┘
```

### API 端點

```
POST /api/templates/create-from-file
```

**請求**: `multipart/form-data`
| 參數 | 類型 | 說明 |
|------|------|------|
| `file` | File | Excel (.xlsx) 或 Word (.docx) 檔案 |
| `template_name` | string | 模板名稱 |
| `category` | string | 設備類別 |
| `company` | string | 公司名稱 |
| `department` | string | 部門名稱 |

**回應**:
```json
{
  "success": true,
  "template_id": "TEMP-XXXXXXXX",
  "field_count": 44,
  "section_count": 4,
  "template": { ... }
}
```

### 深度結構分析

系統針對不同文件格式使用專門的分析器：

#### Excel 分析 (`_deep_analyze_excel`)
- 逐 Sheet 掃描每個 Cell
- 辨識合併儲存格、框線、資料驗證
- 產出 `field_map`：每個欄位含 `field_name`, `field_type`, `label_location` (Sheet/Cell 座標)

#### Word 分析 (`_deep_analyze_word`)
- 分析段落 (paragraphs) 與表格 (tables)
- 辨識標題層級、表格結構、空白填寫區
- 產出 `field_map`：含 `label_location.type` (paragraph/table_row)

### AI 轉換與 Fallback 機制

#### 主路徑：Gemini AI
- 將原始文字 + field_map 送給 Gemini，請求產出完整 InspectionTemplate JSON
- **驗證邏輯**：AI 回傳的 JSON 必須包含非空的 `sections` 陣列，否則降級至 fallback

#### Fallback 規則引擎
當 AI 不可用或回傳無效結果時，系統使用智慧規則引擎：

1. **欄位過濾**：排除區段標題 (如「一、外觀檢查」)、表頭文字、過長/過短文字
2. **四區段分類**：
   - **基本資訊** (`basic_info`)：日期、編號、名稱、地點等
   - **檢測項目** (`inspection_items`)：檢查項目 + 合格/不合格 radio 選項
   - **量測數據** (`measurements`)：數值欄位 + 自動偵測單位 (V, A, MΩ, °C 等)
   - **綜合評估** (`conclusion`)：總體判定、改善建議、簽名
3. **自動增強**：每個區段自動加入照片欄位

### source_file 綁定

產出的模板包含 `source_file` 欄位，記錄原始文件資訊：

```json
{
  "source_file": {
    "file_name": "電氣設備定期檢查表.xlsx",
    "file_type": "excel",
    "field_map": [
      {
        "field_name": "設備名稱",
        "field_type": "text",
        "label_location": { "sheet": "Sheet1", "cell": "A3" }
      }
    ]
  }
}
```

此綁定使得未來可將填寫完成的資料自動回填至原始 Excel/Word 文件。

### Flutter 整合

Flutter 端對應模型：
- `SourceFileInfo` class (`inspection_template.dart`)
- `InspectionTemplate.sourceFile` 欄位
- `BackendApiService.createTemplateFromFile()` 呼叫後端 API

---

## 🗂️ 模板系統設計

### 1. JSON 模板格式規範

#### 1.1 基本結構

```json
{
  "template_id": "TEMP-2025-001",
  "template_name": "電機設備定期檢查表",
  "template_version": "1.0",
  "category": "電機設備",
  "created_at": "2025-11-04T10:00:00Z",
  "updated_at": "2025-11-04T10:00:00Z",

  "metadata": {
    "company": "台灣電力公司",
    "department": "維護部",
    "inspection_cycle_days": 30,
    "estimated_duration_minutes": 45,
    "required_tools": ["溫度計", "噪音計", "相機"],
    "safety_notes": "檢查前務必關閉電源"
  },

  "sections": [
    {
      "section_id": "basic_info",
      "section_title": "基本資訊",
      "section_order": 1,
      "fields": [...]
    },
    {
      "section_id": "inspection_items",
      "section_title": "檢測項目",
      "section_order": 2,
      "fields": [...]
    },
    {
      "section_id": "conclusion",
      "section_title": "檢測結論",
      "section_order": 3,
      "fields": [...]
    }
  ]
}
```

#### 1.2 欄位類型規範

```json
{
  "fields": [
    // 類型 1: 文字輸入
    {
      "field_id": "equipment_name",
      "field_type": "text",
      "label": "設備名稱",
      "placeholder": "請輸入設備名稱",
      "required": true,
      "ai_fillable": false,
      "max_length": 100,
      "validation": {
        "pattern": null,
        "min_length": 2
      }
    },

    // 類型 2: 數值輸入（支援 AI 辨識）
    {
      "field_id": "temperature",
      "field_type": "number",
      "label": "溫度讀數",
      "unit": "°C",
      "required": true,
      "ai_fillable": true,
      "photo_required": true,
      "validation": {
        "min": -50,
        "max": 200,
        "decimal_places": 1
      },
      "warning_threshold": {
        "min": 20,
        "max": 80,
        "message": "溫度超出正常範圍，請檢查"
      }
    },

    // 類型 3: 單選
    {
      "field_id": "operation_status",
      "field_type": "radio",
      "label": "運轉狀態",
      "required": true,
      "ai_fillable": true,
      "options": [
        {"value": "normal", "label": "正常"},
        {"value": "abnormal", "label": "異常"},
        {"value": "stopped", "label": "停機"}
      ],
      "default_value": "normal"
    },

    // 類型 4: 多選
    {
      "field_id": "abnormal_symptoms",
      "field_type": "checkbox",
      "label": "異常症狀（可複選）",
      "required": false,
      "ai_fillable": true,
      "options": [
        {"value": "noise", "label": "異常噪音"},
        {"value": "vibration", "label": "震動過大"},
        {"value": "overheat", "label": "過熱"},
        {"value": "leak", "label": "洩漏"},
        {"value": "other", "label": "其他"}
      ]
    },

    // 類型 5: 下拉式選單
    {
      "field_id": "equipment_type",
      "field_type": "dropdown",
      "label": "設備類型",
      "required": true,
      "ai_fillable": false,
      "options": [
        {"value": "motor", "label": "馬達"},
        {"value": "pump", "label": "泵浦"},
        {"value": "valve", "label": "閥門"},
        {"value": "transformer", "label": "變壓器"}
      ]
    },

    // 類型 6: 日期時間
    {
      "field_id": "inspection_date",
      "field_type": "datetime",
      "label": "檢測日期",
      "required": true,
      "ai_fillable": false,
      "default_value": "now",
      "format": "YYYY-MM-DD HH:mm"
    },

    // 類型 7: 照片（單張）
    {
      "field_id": "equipment_photo",
      "field_type": "photo",
      "label": "設備外觀照片",
      "required": true,
      "ai_analyze": true,
      "max_size_mb": 10,
      "min_resolution": {"width": 800, "height": 600}
    },

    // 類型 8: 照片（多張）
    {
      "field_id": "detail_photos",
      "field_type": "photo_multiple",
      "label": "細節照片",
      "required": false,
      "ai_analyze": true,
      "min_count": 1,
      "max_count": 5
    },

    // 類型 9: 長文字（備註）
    {
      "field_id": "notes",
      "field_type": "textarea",
      "label": "備註說明",
      "placeholder": "請詳細描述異常情況...",
      "required": false,
      "ai_fillable": false,
      "max_length": 500,
      "rows": 4
    },

    // 類型 10: 簽名
    {
      "field_id": "inspector_signature",
      "field_type": "signature",
      "label": "檢測人員簽名",
      "required": true,
      "save_as_image": true
    },

    // 類型 11: AI 自動分析結果
    {
      "field_id": "ai_assessment",
      "field_type": "ai_result",
      "label": "AI 綜合評估",
      "required": false,
      "editable": true,
      "depends_on": ["equipment_photo", "temperature", "operation_status"]
    },

    // 類型 12: 測量值（支援 2D 測量工具）
    {
      "field_id": "crack_size",
      "field_type": "measurement",
      "label": "裂縫尺寸",
      "unit": "mm",
      "required": false,
      "ai_fillable": true,
      "photo_required": true,
      "measurement_tool": "2d_ruler"
    }
  ]
}
```

#### 1.3 條件顯示邏輯

```json
{
  "field_id": "abnormal_description",
  "field_type": "textarea",
  "label": "異常描述",
  "required": true,
  "conditional": {
    "show_when": {
      "field": "operation_status",
      "operator": "equals",
      "value": "abnormal"
    }
  }
}
```

#### 1.4 計算欄位

```json
{
  "field_id": "total_score",
  "field_type": "calculated",
  "label": "總分",
  "formula": "appearance_score + function_score + safety_score",
  "display_format": "總分：{value} / 100"
}
```

---

### 2. 模板編輯器設計

#### 2.1 Web 模板編輯器（優先開發）

**功能需求**:
- ✅ Excel/Word 檔案上傳與解析
- ✅ 視覺化拖放式欄位編輯
- ✅ 欄位類型選擇與屬性設定
- ✅ 即時預覽（手機視圖）
- ✅ JSON 匯出與匯入
- ✅ 版本管理與歷史記錄

**技術方案**:
- 前端: React.js + TypeScript
- Excel 解析: `xlsx` (SheetJS)
- Word 解析: `mammoth.js` 或 `docx` (僅支援 .docx)
- 拖放: `react-beautiful-dnd` 或 `dnd-kit`
- 表單驗證: `zod` + `react-hook-form`

**工作流程**:
```
1. 上傳 Excel/Word
   ↓
2. AI 輔助解析表格結構（Gemini）
   - 識別欄位名稱
   - 推測欄位類型
   - 建議必填屬性
   ↓
3. 使用者手動調整
   - 拖放排序
   - 設定屬性
   - 添加驗證規則
   ↓
4. 產生 JSON 模板
   ↓
5. 匯出或直接上傳至 App
```

#### 2.2 App 內簡易編輯器（次要）

**功能需求**:
- ✅ 複製現有模板
- ✅ 修改欄位標籤與順序
- ✅ 調整必填屬性
- ❌ 不支援複雜的結構變更

---

### 3. 模板儲存與管理

#### 3.1 本地儲存（SQLite）

**資料表: templates**
```sql
CREATE TABLE templates (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  category TEXT,
  version TEXT,
  json_content TEXT NOT NULL,  -- JSON 模板完整內容
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  is_default BOOLEAN DEFAULT 0,
  usage_count INTEGER DEFAULT 0
);
```

**資料表: template_records**
```sql
CREATE TABLE template_records (
  id TEXT PRIMARY KEY,
  template_id TEXT NOT NULL,
  equipment_id TEXT,
  equipment_name TEXT,
  filled_data TEXT NOT NULL,  -- JSON 格式填寫資料
  status TEXT CHECK(status IN ('draft', 'completed', 'submitted')),
  created_at INTEGER NOT NULL,
  completed_at INTEGER,
  synced_to_backend BOOLEAN DEFAULT 0,
  pdf_path TEXT,
  FOREIGN KEY (template_id) REFERENCES templates(id),
  FOREIGN KEY (equipment_id) REFERENCES equipments(id)
);
```

#### 3.2 雲端同步

**Supabase 資料表設計**:

```sql
-- 模板表
CREATE TABLE public.templates (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  organization_id UUID REFERENCES public.organizations(id),
  name TEXT NOT NULL,
  category TEXT,
  version TEXT,
  json_content JSONB NOT NULL,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  is_active BOOLEAN DEFAULT true
);

-- 檢測記錄表
CREATE TABLE public.inspection_records (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  template_id UUID REFERENCES public.templates(id),
  equipment_id UUID REFERENCES public.equipments(id),
  inspector_id UUID REFERENCES auth.users(id),
  filled_data JSONB NOT NULL,
  status TEXT CHECK(status IN ('draft', 'completed', 'approved', 'rejected')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  completed_at TIMESTAMPTZ,
  approved_at TIMESTAMPTZ,
  approved_by UUID REFERENCES auth.users(id),
  pdf_url TEXT,
  photos JSONB,  -- 照片 URL 陣列
  CONSTRAINT valid_status CHECK (
    status = 'draft' OR completed_at IS NOT NULL
  )
);

-- 設備表
CREATE TABLE public.equipments (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  organization_id UUID REFERENCES public.organizations(id),
  equipment_code TEXT UNIQUE NOT NULL,
  equipment_name TEXT NOT NULL,
  equipment_type TEXT,
  location TEXT,
  qr_code TEXT,
  inspection_cycle_days INTEGER DEFAULT 30,
  last_inspection_date DATE,
  next_inspection_date DATE,
  status TEXT DEFAULT 'active',
  metadata JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 定檢提醒表
CREATE TABLE public.inspection_reminders (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  equipment_id UUID REFERENCES public.equipments(id),
  template_id UUID REFERENCES public.templates(id),
  due_date DATE NOT NULL,
  reminder_sent BOOLEAN DEFAULT false,
  completed BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
```

---

## 📄 PDF 生成與回填策略

### 方案 A：HTML 模板轉 PDF（推薦）

**優點**:
- ✅ 設計彈性高（CSS 樣式）
- ✅ 易於維護與調整版型
- ✅ 支援中文字型
- ✅ 可嵌入照片與簽名

**缺點**:
- ❌ 不是「填回原表格」，而是重新生成

**技術實作**:

```dart
// 使用 printing package
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

Future<Uint8List> generateInspectionPDF({
  required String templateName,
  required Map<String, dynamic> filledData,
  required Uint8List? signatureImage,
}) async {
  final pdf = pw.Document();

  // 載入中文字型
  final font = await PdfGoogleFonts.notoSansRegular();
  final fontBold = await PdfGoogleFonts.notoSansBold();

  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      theme: pw.ThemeData.withFont(
        base: font,
        bold: fontBold,
      ),
      build: (pw.Context context) => [
        // 標題
        pw.Header(
          level: 0,
          child: pw.Text(templateName, style: pw.TextStyle(fontSize: 24)),
        ),

        // 基本資訊區塊
        _buildInfoSection(filledData),

        // 檢測項目表格
        _buildInspectionTable(filledData),

        // 照片區塊
        if (filledData['photos'] != null)
          _buildPhotoSection(filledData['photos']),

        // 簽名區塊
        if (signatureImage != null)
          _buildSignatureSection(signatureImage),

        // 頁尾
        pw.Footer(
          child: pw.Text('報告產生時間：${DateTime.now()}'),
        ),
      ],
    ),
  );

  return pdf.save();
}
```

**HTML 模板範例**:
```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <style>
    @page { size: A4; margin: 2cm; }
    body { font-family: 'Noto Sans TC', sans-serif; }
    .header { text-align: center; border-bottom: 2px solid #333; }
    .field { margin: 10px 0; }
    .field-label { font-weight: bold; display: inline-block; width: 150px; }
    .field-value { display: inline-block; border-bottom: 1px solid #999; }
    .photo-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px; }
    .signature { margin-top: 50px; text-align: right; }
  </style>
</head>
<body>
  <div class="header">
    <h1>{{template_name}}</h1>
    <p>設備名稱：{{equipment_name}}</p>
  </div>

  <div class="content">
    {{#sections}}
    <h2>{{section_title}}</h2>
    {{#fields}}
    <div class="field">
      <span class="field-label">{{label}}：</span>
      <span class="field-value">{{value}} {{unit}}</span>
    </div>
    {{/fields}}
    {{/sections}}
  </div>

  <div class="photo-grid">
    {{#photos}}
    <img src="{{url}}" alt="{{description}}" />
    {{/photos}}
  </div>

  <div class="signature">
    <p>檢測人員簽名：</p>
    <img src="{{signature}}" alt="簽名" />
    <p>日期：{{date}}</p>
  </div>
</body>
</html>
```

---

### 方案 B：PDF 模板填充（適用於固定格式）

**適用場景**:
- 客戶提供標準 PDF 表格
- 需要完全符合既有格式

**技術實作**:
使用 `syncfusion_flutter_pdf` 或類似套件

```dart
import 'package:syncfusion_flutter_pdf/pdf.dart';

Future<Uint8List> fillPDFTemplate({
  required String templatePath,
  required Map<String, dynamic> data,
}) async {
  // 載入 PDF 模板
  final PdfDocument document = PdfDocument(
    inputBytes: await File(templatePath).readAsBytes(),
  );

  // 取得表單欄位
  final PdfForm form = document.form;

  // 填充欄位
  data.forEach((key, value) {
    final field = form.fields.firstWhere(
      (field) => field.name == key,
      orElse: () => null,
    );

    if (field != null) {
      if (field is PdfTextBoxField) {
        field.text = value.toString();
      } else if (field is PdfCheckBoxField) {
        field.isChecked = value as bool;
      }
    }
  });

  // 扁平化表單（防止修改）
  form.flattenAllFields();

  // 儲存
  final bytes = await document.save();
  document.dispose();

  return bytes;
}
```

**準備 PDF 模板步驟**:
1. 使用 Adobe Acrobat 或 PDFtk 建立表單欄位
2. 為每個欄位設定名稱（與 JSON `field_id` 對應）
3. 設定欄位類型（文字框、核取方塊等）
4. 匯出為 PDF 模板

---

### 方案 C：Placeholder 文字替換（最簡單）

**適用場景**:
- 快速原型
- 簡單表格

**實作方式**:
```dart
String generatePDFContent(Map<String, dynamic> data) {
  String template = '''
設備名稱：{{equipment_name}}
檢測日期：{{inspection_date}}
溫度：{{temperature}} °C
狀態：{{status}}
  ''';

  data.forEach((key, value) {
    template = template.replaceAll('{{$key}}', value.toString());
  });

  return template;
}
```

---

## 🔗 後端整合方案

### 1. API 設計

#### 1.1 RESTful API 端點

**模板管理**
```
GET    /api/templates              # 取得模板列表
GET    /api/templates/:id          # 取得特定模板
POST   /api/templates              # 建立新模板
PUT    /api/templates/:id          # 更新模板
DELETE /api/templates/:id          # 刪除模板
```

**檢測記錄**
```
GET    /api/inspections            # 取得檢測記錄列表
GET    /api/inspections/:id        # 取得特定記錄
POST   /api/inspections            # 建立檢測記錄
PUT    /api/inspections/:id        # 更新記錄
POST   /api/inspections/:id/submit # 提交記錄（變更狀態）
POST   /api/inspections/:id/pdf    # 生成 PDF
```

**設備管理**
```
GET    /api/equipments             # 取得設備列表
GET    /api/equipments/:id         # 取得設備詳情
POST   /api/equipments             # 新增設備
PUT    /api/equipments/:id         # 更新設備
GET    /api/equipments/:id/history # 取得設備檢測歷史
```

**提醒系統**
```
GET    /api/reminders              # 取得待檢測提醒
POST   /api/reminders              # 建立提醒
PUT    /api/reminders/:id/complete # 完成提醒
```

#### 1.2 請求/回應格式範例

**POST /api/inspections**
```json
{
  "template_id": "uuid",
  "equipment_id": "uuid",
  "filled_data": {
    "equipment_name": "冷卻泵浦 A1",
    "temperature": 65.5,
    "operation_status": "normal",
    "photos": [
      {
        "field_id": "equipment_photo",
        "file_name": "photo_001.jpg",
        "file_size": 2048576,
        "uploaded": true,
        "url": "https://storage.example.com/photos/..."
      }
    ]
  },
  "status": "draft"
}
```

**Response 200 OK**
```json
{
  "id": "uuid",
  "created_at": "2025-11-04T10:30:00Z",
  "status": "draft",
  "sync_status": "synced"
}
```

---

### 2. 同步機制

#### 2.1 離線優先策略

```dart
class SyncService {
  // 建立檢測記錄（離線優先）
  Future<String> createInspectionRecord(InspectionRecord record) async {
    // 1. 先儲存到本地 SQLite
    await _localDB.insert(record);

    // 2. 標記為待同步
    await _localDB.markForSync(record.id);

    // 3. 如果有網路，立即上傳
    if (await _networkService.isOnline()) {
      await _uploadToBackend(record);
    } else {
      // 4. 無網路時加入背景同步佇列
      await _backgroundSyncQueue.add(record.id);
    }

    return record.id;
  }

  // 背景同步（定期執行）
  Future<void> syncPendingRecords() async {
    final pendingRecords = await _localDB.getPendingSync();

    for (final record in pendingRecords) {
      try {
        await _uploadToBackend(record);
        await _localDB.markSynced(record.id);
      } catch (e) {
        print('Sync failed for ${record.id}: $e');
        // 保留在佇列中，下次重試
      }
    }
  }

  // 上傳到後端
  Future<void> _uploadToBackend(InspectionRecord record) async {
    // 1. 先上傳照片到 Storage
    for (final photo in record.photos) {
      if (!photo.uploaded) {
        final url = await _uploadPhoto(photo.localPath);
        photo.url = url;
        photo.uploaded = true;
      }
    }

    // 2. 上傳檢測記錄到資料庫
    await _apiClient.post('/api/inspections', body: record.toJson());
  }
}
```

#### 2.2 衝突解決策略

```dart
enum ConflictResolution {
  serverWins,    // 伺服器版本優先
  clientWins,    // 客戶端版本優先
  manual,        // 手動選擇
  merge,         // 合併（若可能）
}

class ConflictResolver {
  Future<InspectionRecord> resolve({
    required InspectionRecord localRecord,
    required InspectionRecord serverRecord,
    ConflictResolution strategy = ConflictResolution.serverWins,
  }) async {
    switch (strategy) {
      case ConflictResolution.serverWins:
        return serverRecord;

      case ConflictResolution.clientWins:
        return localRecord;

      case ConflictResolution.manual:
        return await _showConflictDialog(localRecord, serverRecord);

      case ConflictResolution.merge:
        return _mergeRecords(localRecord, serverRecord);
    }
  }
}
```

---

### 3. 監控與統計整合

#### 3.1 即時監控儀表板（Web）

**資料來源**: Supabase Real-time Subscriptions

```typescript
// 即時監聽檢測記錄更新
const subscription = supabase
  .channel('inspection-records')
  .on('postgres_changes', {
    event: 'INSERT',
    schema: 'public',
    table: 'inspection_records'
  }, (payload) => {
    console.log('New inspection:', payload.new);
    updateDashboard(payload.new);
  })
  .subscribe();

// 統計資料查詢
async function getDashboardStats(organizationId: string) {
  const { data, error } = await supabase.rpc('get_dashboard_stats', {
    org_id: organizationId,
    date_from: '2025-01-01',
    date_to: '2025-12-31'
  });

  return {
    totalInspections: data.total_inspections,
    abnormalRate: data.abnormal_rate,
    avgCompletionTime: data.avg_completion_time,
    topAbnormalEquipments: data.top_abnormal_equipments
  };
}
```

#### 3.2 PostgreSQL 統計函數

```sql
-- 建立統計函數
CREATE OR REPLACE FUNCTION get_dashboard_stats(
  org_id UUID,
  date_from DATE,
  date_to DATE
)
RETURNS JSON AS $$
DECLARE
  result JSON;
BEGIN
  SELECT json_build_object(
    'total_inspections', COUNT(*),
    'abnormal_rate',
      ROUND(
        COUNT(*) FILTER (WHERE (filled_data->>'operation_status') = 'abnormal')::NUMERIC /
        COUNT(*)::NUMERIC * 100,
        2
      ),
    'avg_completion_time',
      AVG(EXTRACT(EPOCH FROM (completed_at - created_at)) / 60),
    'top_abnormal_equipments',
      (
        SELECT json_agg(row_to_json(t))
        FROM (
          SELECT
            e.equipment_name,
            COUNT(*) as abnormal_count
          FROM inspection_records ir
          JOIN equipments e ON ir.equipment_id = e.id
          WHERE
            ir.organization_id = org_id
            AND (ir.filled_data->>'operation_status') = 'abnormal'
            AND ir.created_at BETWEEN date_from AND date_to
          GROUP BY e.equipment_name
          ORDER BY abnormal_count DESC
          LIMIT 10
        ) t
      )
  ) INTO result
  FROM inspection_records
  WHERE
    organization_id = org_id
    AND created_at BETWEEN date_from AND date_to;

  RETURN result;
END;
$$ LANGUAGE plpgsql;
```

---

## ⏰ 定檢週期提醒系統

### 1. 提醒邏輯設計

```dart
class ReminderService {
  // 計算下次檢測日期
  DateTime calculateNextInspectionDate({
    required DateTime lastInspectionDate,
    required int cycleDays,
  }) {
    return lastInspectionDate.add(Duration(days: cycleDays));
  }

  // 建立提醒
  Future<void> createReminder({
    required Equipment equipment,
  }) async {
    final nextDate = calculateNextInspectionDate(
      lastInspectionDate: equipment.lastInspectionDate,
      cycleDays: equipment.inspectionCycleDays,
    );

    final reminder = InspectionReminder(
      equipmentId: equipment.id,
      templateId: equipment.defaultTemplateId,
      dueDate: nextDate,
    );

    // 儲存到本地
    await _localDB.insertReminder(reminder);

    // 同步到後端
    await _apiClient.post('/api/reminders', body: reminder.toJson());

    // 排程本地通知
    await _scheduleNotification(reminder);
  }

  // 排程本地通知
  Future<void> _scheduleNotification(InspectionReminder reminder) async {
    final equipment = await _getEquipment(reminder.equipmentId);

    // 提前 3 天提醒
    final notificationDate = reminder.dueDate.subtract(Duration(days: 3));

    await FlutterLocalNotificationsPlugin().zonedSchedule(
      reminder.id.hashCode,
      '定期檢測提醒',
      '設備「${equipment.name}」需要進行定期檢測',
      tz.TZDateTime.from(notificationDate, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'inspection_reminder',
          '定檢提醒',
          channelDescription: '設備定期檢測提醒',
          importance: Importance.high,
        ),
      ),
      androidAllowWhileIdle: true,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  // 每日檢查逾期提醒
  Future<void> checkOverdueReminders() async {
    final overdueReminders = await _localDB.getOverdueReminders();

    for (final reminder in overdueReminders) {
      await _sendOverdueNotification(reminder);
    }
  }
}
```

### 2. 後端定時任務（Supabase Edge Functions）

```typescript
// supabase/functions/check-reminders/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

serve(async (req) => {
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  )

  // 查詢即將到期的提醒（3 天內）
  const { data: reminders, error } = await supabase
    .from('inspection_reminders')
    .select(`
      *,
      equipments(*),
      templates(*)
    `)
    .eq('completed', false)
    .eq('reminder_sent', false)
    .lte('due_date', new Date(Date.now() + 3 * 24 * 60 * 60 * 1000).toISOString())

  if (error) throw error

  // 發送推送通知給相關人員
  for (const reminder of reminders) {
    await sendPushNotification({
      userId: reminder.equipments.responsible_person_id,
      title: '定期檢測提醒',
      body: `設備「${reminder.equipments.equipment_name}」需要進行定期檢測`,
      data: {
        type: 'inspection_reminder',
        equipmentId: reminder.equipment_id,
        templateId: reminder.template_id
      }
    })

    // 更新提醒狀態
    await supabase
      .from('inspection_reminders')
      .update({ reminder_sent: true })
      .eq('id', reminder.id)
  }

  return new Response(
    JSON.stringify({ success: true, reminders_sent: reminders.length }),
    { headers: { "Content-Type": "application/json" } }
  )
})
```

**設定 Cron Job**:
```sql
-- 使用 pg_cron 擴充
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- 每日 08:00 執行檢查
SELECT cron.schedule(
  'check-inspection-reminders',
  '0 8 * * *',
  $$
  SELECT
    net.http_post(
      url:='https://your-project.supabase.co/functions/v1/check-reminders',
      headers:='{"Content-Type": "application/json", "Authorization": "Bearer YOUR_ANON_KEY"}'::jsonb
    ) as request_id;
  $$
);
```

---

## 📱 App 實作重點

### 1. 引導式填寫 UI

```dart
class TemplateBasedInspectionScreen extends StatefulWidget {
  final InspectionTemplate template;
  final Equipment? equipment;

  @override
  _TemplateBasedInspectionScreenState createState() =>
      _TemplateBasedInspectionScreenState();
}

class _TemplateBasedInspectionScreenState
    extends State<TemplateBasedInspectionScreen> {

  int _currentSectionIndex = 0;
  int _currentFieldIndex = 0;
  Map<String, dynamic> _filledData = {};

  @override
  Widget build(BuildContext context) {
    final currentSection = widget.template.sections[_currentSectionIndex];
    final currentField = currentSection.fields[_currentFieldIndex];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.template.name),
        subtitle: Text(
          '${currentSection.title} (${_currentFieldIndex + 1}/${currentSection.fields.length})'
        ),
      ),
      body: Column(
        children: [
          // 進度條
          LinearProgressIndicator(
            value: _getProgress(),
          ),

          // 欄位輸入區
          Expanded(
            child: _buildFieldInput(currentField),
          ),

          // 導航按鈕
          Row(
            children: [
              if (_hasPrevious())
                ElevatedButton(
                  onPressed: _goToPrevious,
                  child: Text('上一項'),
                ),
              Spacer(),
              ElevatedButton(
                onPressed: _hasNext() ? _goToNext : _complete,
                child: Text(_hasNext() ? '下一項' : '完成'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFieldInput(TemplateField field) {
    switch (field.fieldType) {
      case FieldType.text:
        return _buildTextInput(field);
      case FieldType.number:
        return _buildNumberInput(field);
      case FieldType.photo:
        return _buildPhotoInput(field);
      case FieldType.signature:
        return _buildSignatureInput(field);
      case FieldType.radio:
        return _buildRadioInput(field);
      // ... 其他類型
      default:
        return Text('未支援的欄位類型');
    }
  }

  Widget _buildPhotoInput(TemplateField field) {
    return Column(
      children: [
        Text(field.label, style: TextStyle(fontSize: 20)),
        SizedBox(height: 20),

        // 照片預覽
        if (_filledData[field.fieldId] != null)
          Image.file(File(_filledData[field.fieldId]['path'])),

        // 拍照按鈕
        ElevatedButton.icon(
          icon: Icon(Icons.camera_alt),
          label: Text('拍攝照片'),
          onPressed: () async {
            final photo = await _takePhoto();
            if (photo != null) {
              // AI 分析
              if (field.aiAnalyze) {
                final analysis = await _analyzePhoto(photo, field);
                _fillAIResults(analysis);
              }

              setState(() {
                _filledData[field.fieldId] = {
                  'path': photo.path,
                  'timestamp': DateTime.now().toIso8601String(),
                };
              });
            }
          },
        ),

        // AI 分析結果
        if (field.aiAnalyze && _filledData.containsKey('${field.fieldId}_ai'))
          Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                children: [
                  Text('AI 分析結果'),
                  ..._buildAIResults(_filledData['${field.fieldId}_ai']),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
```

---

## 📅 實施計畫

### Phase 1: 基礎架構（2 週）

**Week 1**:
- ✅ 設計 JSON 模板格式規範
- ✅ 建立本地資料庫 Schema（SQLite）
- ✅ 實作模板 Model 與解析邏輯
- ✅ 建立簡易模板範例（2-3 個）

**Week 2**:
- ✅ 實作引導式填寫 UI 框架
- ✅ 支援基本欄位類型（text, number, photo, signature）
- ✅ 整合現有 AI 分析功能
- ✅ 本地儲存檢測記錄

---

### Phase 2: 模板編輯器（2 週）

**Week 3**:
- ✅ 建立 Web 模板編輯器專案（React）
- ✅ Excel 檔案上傳與解析
- ✅ AI 輔助欄位識別（Gemini）
- ✅ 視覺化拖放式編輯介面

**Week 4**:
- ✅ 欄位屬性設定面板
- ✅ 即時預覽功能
- ✅ JSON 匯出與驗證
- ✅ 模板分享與匯入

---

### Phase 3: PDF 生成（1 週）

**Week 5**:
- ✅ 選定 PDF 生成方案（推薦 HTML → PDF）
- ✅ 設計 PDF 模板樣式（2-3 種版型）
- ✅ 實作 PDF 生成邏輯
- ✅ 嵌入照片與簽名
- ✅ 支援中文字型
- ✅ 測試與優化

---

### Phase 4: 後端整合（2 週）

**Week 6**:
- ✅ Supabase 專案設定
- ✅ 建立資料庫 Schema
- ✅ 實作 API 端點（模板、記錄、設備）
- ✅ Storage 設定（照片與 PDF 儲存）

**Week 7**:
- ✅ App 端同步邏輯實作
- ✅ 離線優先機制
- ✅ 衝突解決策略
- ✅ 背景同步服務

---

### Phase 5: 提醒系統（1 週）

**Week 8**:
- ✅ 設備管理功能
- ✅ 定檢週期設定
- ✅ 本地通知排程
- ✅ 後端定時任務（Edge Functions）
- ✅ 推送通知整合

---

### Phase 6: 測試與優化（1 週）

**Week 9**:
- ✅ 整合測試
- ✅ 效能優化
- ✅ UI/UX 調整
- ✅ 文檔撰寫
- ✅ 發布 Beta 版本

---

## 🎯 成功指標

### 功能完整性
- ✅ 支援 5 種以上欄位類型
- ✅ Excel/Word 匯入成功率 > 90%
- ✅ PDF 生成成功率 100%
- ✅ 離線/線上無縫切換

### 效能指標
- ✅ 單次檢測完成時間 < 10 分鐘（含拍照）
- ✅ PDF 生成時間 < 5 秒
- ✅ 照片上傳時間 < 10 秒/張（Wi-Fi）
- ✅ App 啟動時間 < 3 秒

### 用戶體驗
- ✅ 操作直覺，無需訓練即可上手
- ✅ AI 輔助填寫準確率 > 85%
- ✅ 提醒通知及時送達率 > 95%
- ✅ 資料不遺失率 100%

---

## 📞 聯絡與支援

**專案負責人**: dofliu
**開發團隊**: doflab 劉瑞弘老師研究團隊
**GitHub**: https://github.com/dofliu/InduSpect

---

*本規格書將隨專案進展持續更新*
