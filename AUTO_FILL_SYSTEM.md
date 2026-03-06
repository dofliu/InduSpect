# 自動回填系統技術文件

> 最後更新：2026-03-05

## 概述

InduSpect 的「表單自動回填」系統能將 AI 巡檢分析結果，自動填入任意格式的 Excel (.xlsx) 或 Word (.docx) 定檢表。系統採用**動態結構分析 + AI 語意映射**的兩階段架構，不綁定特定表格格式，能處理不同欄位、行列數、填表位置的表單。

---

## 系統架構

```
┌──────────────┐     ┌──────────────────┐     ┌──────────────────┐     ┌───────────────┐
│  1. 結構分析  │────>│  2. AI 欄位映射   │────>│  3. 預覽確認     │────>│  4. 執行回填   │
│  (動態偵測)   │     │  (Gemini AI)      │     │  (信心度標記)    │     │  (保留格式)    │
└──────────────┘     └──────────────────┘     └──────────────────┘     └───────────────┘
```

---

## 四階段工作流程

### 階段一：結構分析（`POST /api/auto-fill/analyze-structure`）

**目的**：動態解析任意表格的欄位位置，產出「欄位位置地圖」(Field Position Map)。

**處理邏輯**：

#### Excel 分析（`_deep_analyze_excel`）

1. 載入工作簿，遍歷所有工作表
2. 建立合併儲存格查找表（`merge_lookup`）
3. 逐一掃描每個儲存格（最多 200 行 × 50 欄）
4. 使用 `_is_field_label()` 判斷是否為欄位標籤
5. 使用 `_find_value_cell_excel()` 找到對應的值儲存格

**值儲存格搜尋策略**：
```
策略 1：檢查標籤右方 1~3 格 → 空白或非標籤的儲存格即為值位置
策略 2：檢查標籤下方 1~2 格 → 空白或佔位符的儲存格即為值位置
```

#### Word 分析（`_deep_analyze_word`）

1. **段落分析**：偵測含冒號或底線的段落（如「設備名稱：______」）
2. **表格分析**：遍歷所有表格，偵測標籤儲存格，找右方/下方的值儲存格

#### 輸出格式（欄位位置地圖）

```json
{
  "field_id": "excel_Sheet1_B5",
  "field_name": "設備名稱",
  "field_type": "text",
  "label_location": {
    "sheet": "Sheet1",
    "cell": "B5",
    "row": 5,
    "column": 2
  },
  "value_location": {
    "sheet": "Sheet1",
    "cell": "C5",
    "row": 5,
    "column": 3,
    "direction": "right",
    "offset": 1
  },
  "is_merged": false,
  "merge_info": null,
  "mapping": null
}
```

---

### 階段二：AI 欄位映射（`POST /api/auto-fill/map-fields`）

**目的**：使用 Gemini AI 將巡檢結果智慧映射到表單欄位。

**處理邏輯**：

1. 將欄位地圖中的欄位名稱和類型整理為摘要
2. 將所有 AI 巡檢結果整理為結構化資料
3. 組合 Prompt 送給 Gemini，要求 AI 判斷每個欄位應填入什麼值

**AI 映射規則**：
| 欄位類型 | 映射來源 | 範例 |
|----------|----------|------|
| 日期欄位 | `inspection_date` | 2026-03-05 |
| 數值欄位 | `extracted_values` 中的讀數 | 溫度: 65.5°C |
| 狀態/判定欄位 | `is_anomaly` | 合格 / 不合格 |
| 文字欄位 | 對應描述文字 | 設備運轉正常 |
| 勾選欄位 | 異常偵測結果 | ✓ / ✗ |

**輸出格式**：
```json
{
  "field_id": "excel_Sheet1_C10",
  "suggested_value": "65.5",
  "source": "來自溫度照片分析的 readings.溫度.value",
  "confidence": 0.95
}
```

---

### 階段三：預覽確認（`POST /api/auto-fill/preview`）

**目的**：讓使用者在正式回填前確認 AI 建議的值。

**信心度標記**：
- 🟢 **高信心**（90%+）：直接採用
- 🟡 **中信心**（70-89%）：建議確認
- 🔴 **低信心**（<70%）：需人工審查

**輸出包含**：
- 每個欄位的建議值、信心度、來源說明
- 是否找到目標儲存格（`has_target`）
- 警告訊息（無對應值、低信心度、找不到值位置）

---

### 階段四：執行回填（`POST /api/auto-fill/execute`）

**目的**：將確認後的值寫入原始文件，產出可下載的回填檔案。

#### Excel 回填（`_auto_fill_excel`）

```python
# 保留原始格式的寫入流程
original_font = copy.copy(target_cell.font)
original_alignment = copy.copy(target_cell.alignment)
original_number_format = target_cell.number_format

target_cell.value = typed_value  # 寫入值

# 還原格式
target_cell.font = original_font
target_cell.alignment = original_alignment
target_cell.number_format = original_number_format
```

#### Word 回填（`_auto_fill_word`）

- **段落型**：替換冒號後的內容（保留標籤文字）
- **表格型**：直接寫入對應儲存格
- **格式保留**：保留第一個 run 的字型格式

---

## 欄位偵測機制

### 標籤關鍵字（`FIELD_KEYWORDS`）

系統使用以下關鍵字判斷一個儲存格是否為欄位標籤：

```python
FIELD_KEYWORDS = [
    ':', '：', '日期', '姓名', '編號', '設備', '檢查', '備註',
    '人員', '地點', '位置', '廠區', '型號', '規格', '狀態', '狀況',
    '結果', '判定', '溫度', '壓力', '電流', '電壓', '轉速', '流量',
    '讀數', '數值', '合格', '不合格', '正常', '異常', '測量',
    '頻率', '振動', '噪音', '油位', '水位', '濕度',
]
```

### 佔位符識別（`_is_placeholder`）

系統識別以下佔位符模式，代表該儲存格是可填入的值位置：

| 模式 | 範例 |
|------|------|
| 底線 | `______`、`＿＿＿＿` |
| 雙括號 | `{{field_name}}` |
| 尖括號 | `<請填入>` |
| 方括號 | `[值]` |
| 斜線 | `///` |
| 純空白 | （空格） |

### 欄位類型推測（`_guess_field_type`）

根據欄位名稱中的關鍵字自動推測類型：

| 關鍵字 | 推測類型 |
|--------|----------|
| 日期、時間 | `date` |
| 溫度、壓力、電流、轉速、數值... | `number` |
| 是否、合格、判定、正常、異常 | `checkbox` |
| 其他 | `text` |

### 值轉換（`_convert_value`）

回填時根據欄位類型自動轉換值：

| 類型 | 轉換邏輯 |
|------|----------|
| `number` | 嘗試轉為 `float` 或 `int` |
| `checkbox` | `是/合格/正常/true` → `合格`；`否/不合格/異常/false` → `不合格` |
| `date` | 保持字串格式 |
| `text` | 直接轉為字串 |

---

## 可用的巡檢資料欄位

以下是 AI 分析後可用於映射的資料欄位：

```python
INSPECTION_FIELDS = {
    "equipment_name":       "設備名稱",        # text
    "equipment_type":       "設備類型",        # text
    "equipment_id":         "設備編號",        # text
    "inspection_date":      "檢查日期",        # date
    "inspector_name":       "檢查人員",        # text
    "location":             "位置/廠區",       # text
    "condition_assessment": "狀況評估",        # text
    "anomaly_description":  "異常描述",        # text
    "is_anomaly":           "是否異常",        # checkbox
    "notes":                "備註",            # text
    "extracted_values":     "儀表讀數/量測值",  # dict (動態展開)
}
```

---

## API 端點

| 端點 | 方法 | 說明 |
|------|------|------|
| `/api/auto-fill/analyze-structure` | POST | 上傳 Excel/Word，回傳欄位位置地圖 |
| `/api/auto-fill/map-fields` | POST | AI 智慧映射欄位與巡檢結果 |
| `/api/auto-fill/preview` | POST | 預覽回填結果與警告 |
| `/api/auto-fill/execute` | POST | 執行回填並下載檔案 |

---

## 為什麼能處理任意表格格式？

1. **動態掃描**：不預設表格結構，逐格掃描並判斷
2. **多方向搜尋**：值位置可在標籤的右方或下方
3. **合併儲存格處理**：自動識別並正確處理合併範圍
4. **多工作表支援**：Excel 中的所有工作表都會被分析
5. **混合格式支援**：Word 中的段落和表格同時分析
6. **AI 語意映射**：不靠欄位名稱精確比對，而是由 AI 理解語意後智慧對應

---

## 相關檔案

| 檔案路徑 | 說明 |
|----------|------|
| `backend/app/services/form_fill.py` | 核心服務邏輯（1105 行） |
| `backend/app/api/auto_fill.py` | API 路由定義 |
| `backend/app/models/schemas.py` | Pydantic 資料模型 |
| `flutter_app/lib/screens/auto_fill_screen.dart` | Flutter 前端介面 |
| `examples/motor_inspection_template.json` | 範例巡檢模板 |

---

## 限制與注意事項

- 欄位標籤偵測依賴關鍵字清單，極不常見的欄位名稱可能漏偵測
- Excel 掃描上限為 200 行 × 50 欄，超大表格可能不完整
- AI 映射需要網路連線與有效的 Gemini API Key
- 回填後建議人工確認低信心度（< 70%）的欄位
