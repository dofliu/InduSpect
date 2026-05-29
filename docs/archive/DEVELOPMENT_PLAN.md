# InduSpect AI — 定檢系統改善開發計畫

> **建立日期**: 2026-03-13
> **目標**: 讓系統符合多數工廠現場定檢需求，達成「除了拍照，其餘全自動」的終極目標
> **核心原則**: 回填原始表單、維持原本格式、可直接上繳

---

## 專案現況總覽

### 已完成模組
| 模組 | 狀態 | 位置 |
|------|------|------|
| AI 照片分析 (Gemini) | ✅ 完成 | `gemini_service.dart` / `index.tsx` |
| 快速分析模式 | ✅ 完成 | `quick_analysis_screen.dart` |
| 4步驟巡檢流程 | ✅ 完成 | `step1~step4_*.dart` |
| 動態模板系統 | ✅ 完成 | `form_fill.py` (1105行) |
| 表單結構分析 | ✅ 完成 | `auto_fill.py` API |
| AI 欄位映射 | ✅ 完成 | `form_fill.py` map_fields |
| 預覽 + 信心度 | ✅ 完成 | `form_fill.py` preview |
| 回填引擎 (Excel/Word) | ✅ 完成 | `form_fill.py` execute |
| 2D 互動測量工具 | ✅ 完成 | `index.tsx` |
| 離線拍照儲存 | ✅ 完成 | SharedPreferences |

### 核心缺口（本計畫要補）
| 缺口 | 影響 | 對應任務 |
|------|------|----------|
| 拍照↔欄位 無法自動對應 | 拍 30 張照片不知道填哪裡 | Sprint 1 |
| 勾選式表單支援不足 | 80% 定檢表是勾選格式 | Sprint 2 |
| 照片無法自動插入報告 | 定檢報告必須附照片佐證 | Sprint 2 |
| 缺法規標準值比對 | AI 無法自動判合格/不合格 | Sprint 3 |
| 無歷史資料參照 | 無法帶入前次檢查值 | Sprint 3 |
| 端到端流程未整合 | 使用者要在多個畫面跳來跳去 | Sprint 4 |

---

## 開發階段總覽

```
Sprint 1 (1-2 週)  ─── 照片↔欄位 自動綁定引擎
Sprint 2 (1-2 週)  ─── 勾選表單 + 照片插入
Sprint 3 (1-2 週)  ─── 法規標準值 + 歷史資料
Sprint 4 (1 週)    ─── 端到端流程整合
Sprint 5 (1-2 週)  ─── 批次定檢 + 範本庫
Sprint 6 (1 週)    ─── 整合測試 + 真實表單驗證
```

預估總工期：**6-10 週**

---

## Sprint 1：照片↔欄位 自動綁定引擎

> **目標**: 讓每張照片自動知道對應表單的哪個欄位
> **為什麼最優先**: 沒有這個，拍再多照片也無法正確回填

### Task 1.1 — 從表單結構自動產生拍照任務清單

**檔案**: `backend/app/services/form_fill.py`

**需求**:
- 在 `analyze_structure()` 完成後，自動將 field_map 轉換為「拍照任務清單」
- 每個需要照片佐證的欄位產生一個拍照任務
- 任務包含：任務ID、對應欄位ID、欄位名稱、拍照提示語

**實作重點**:
```python
# 新增方法: generate_photo_tasks(field_map) -> list[PhotoTask]
#
# PhotoTask 結構:
# {
#   "task_id": "photo_001",
#   "field_ids": ["excel_Sheet1_C10", "excel_Sheet1_D10"],  # 可對應多欄位
#   "display_name": "第3項：配電盤 - 絕緣電阻",
#   "photo_hint": "請拍攝三用電表顯示的絕緣電阻讀數",
#   "expected_type": "number",      # 預期要提取的資料類型
#   "expected_unit": "MΩ",          # 預期單位
#   "sequence": 3                    # 拍照順序
# }
#
# 產生邏輯:
# 1. 遍歷 field_map，找出 field_type 為 number/checkbox 的欄位
# 2. 同一檢查項目的多個欄位（如 合格/不合格/數值/備註）合併為同一個拍照任務
# 3. 純文字欄位（日期/人員/設備名稱）不產生拍照任務（由基本資訊填入）
# 4. 按表單順序排序
```

**驗收標準**:
- [ ] 上傳一份電氣定檢 Excel，能自動產出拍照任務清單
- [ ] 日期/人員等基本欄位不會出現在拍照清單中
- [ ] 同一檢查項目的多個欄位合併為一個任務

---

### Task 1.2 — 新增 API 端點: 產生拍照任務

**檔案**: `backend/app/api/auto_fill.py`

**新增端點**:
```
POST /api/auto-fill/generate-photo-tasks
  Input:  template_id (str)
  Output: { "tasks": [PhotoTask], "basic_info_fields": [BasicField] }
```

**說明**:
- `tasks`: 需要拍照的檢查項目清單
- `basic_info_fields`: 不需拍照、可直接填入的基本欄位（日期、人員、設備名稱等）

**驗收標準**:
- [ ] API 回傳正確的 JSON 結構
- [ ] basic_info_fields 包含所有純文字/日期欄位
- [ ] tasks 按表單順序排列

---

### Task 1.3 — Flutter 前端: 引導拍照畫面（綁定欄位版）

**檔案**: 新建 `flutter_app/lib/screens/guided_capture_screen.dart`

**UI 流程**:
```
┌─────────────────────────────────────┐
│  定檢拍照  (3 / 15)                  │
│                                      │
│  📋 目前項目：配電盤 - 絕緣電阻測量    │
│  💡 提示：請拍攝三用電表的讀數畫面     │
│                                      │
│  ┌─────────────────────────────┐    │
│  │                             │    │
│  │      [相機預覽區域]          │    │
│  │                             │    │
│  └─────────────────────────────┘    │
│                                      │
│  [📷 拍照]    [🖼 從相簿]    [⏭ 跳過] │
│                                      │
│  ──── 已完成項目 ────                 │
│  ✅ 1. 外觀檢查     📷              │
│  ✅ 2. 接地電阻     📷              │
│  🔵 3. 絕緣電阻     ← 目前           │
│  ⬜ 4. 電壓量測                      │
│  ⬜ 5. ...                           │
└─────────────────────────────────────┘
```

**關鍵邏輯**:
- 從 API 取得 photo_tasks，依序顯示
- 拍照後，照片自動綁定 task_id（進而綁定 field_ids）
- 支援跳過（某些項目可能不適用）
- 支援重拍（覆蓋前一張）
- 照片存入本地，帶 task_id metadata

**驗收標準**:
- [ ] 能依序顯示拍照任務
- [ ] 拍照後照片與 task_id 正確綁定
- [ ] 支援跳過和重拍
- [ ] 離線模式下照片正確儲存

---

### Task 1.4 — AI 分析結果自動對應欄位

**檔案**: `backend/app/services/form_fill.py`

**需求**:
- 修改 `map_fields()`，新增參數 `photo_task_bindings`
- AI 映射時，不再是「通用映射」而是「精準映射」—— 因為我們已經知道哪張照片對應哪個欄位

**新邏輯**:
```python
# photo_task_bindings 結構:
# [
#   {
#     "task_id": "photo_001",
#     "field_ids": ["excel_Sheet1_C10"],
#     "photo_base64": "...",
#     "ai_result": {
#       "readings": [{"label": "絕緣電阻", "value": 52.3, "unit": "MΩ"}],
#       "is_anomaly": false,
#       "condition_assessment": "正常"
#     }
#   }
# ]
#
# 映射邏輯:
# 1. 每個 binding 的 ai_result 直接對應到其 field_ids
# 2. 不需要 AI 再猜「這個讀數應該填到哪裡」
# 3. 大幅提升映射準確率（從 ~80% → ~95%+）
```

**驗收標準**:
- [ ] 帶有 photo_task_bindings 時，映射準確率顯著提升
- [ ] 不帶 bindings 時，退回原本的通用映射（向下相容）
- [ ] 數值型欄位正確帶入 value + unit

---

## Sprint 2：勾選表單 + 照片插入

> **目標**: 支援 80% 定檢表的「勾選格式」+ 報告必須附照片

### Task 2.1 — 增強勾選式欄位偵測

**檔案**: `backend/app/services/form_fill.py`

**需求**: 偵測「合格/不合格分成兩欄」的表格結構

**常見定檢表格式**:
```
  檢查項目      │ 合格 │ 不合格 │ 備註
  ─────────────┼──────┼────────┼──────
  絕緣電阻      │      │        │
  接地電阻      │      │        │
```

**實作重點**:
```python
# 在 _deep_analyze_excel() 中新增:
#
# 1. 偵測表頭列（含有「合格」「不合格」「正常」「異常」等字樣的列）
# 2. 當偵測到此結構時，每個檢查項目產生一個 "dual_column_checkbox" 類型的欄位
# 3. field_map 中記錄:
#    - "pass_cell": 合格欄的位置
#    - "fail_cell": 不合格欄的位置
#    - "remarks_cell": 備註欄位置（如有）
#
# 新增欄位類型: "dual_column_checkbox"
# {
#   "field_id": "excel_Sheet1_row10",
#   "field_name": "絕緣電阻",
#   "field_type": "dual_column_checkbox",
#   "pass_cell": {"sheet": "Sheet1", "cell": "C10"},
#   "fail_cell": {"sheet": "Sheet1", "cell": "D10"},
#   "remarks_cell": {"sheet": "Sheet1", "cell": "E10"},
#   "check_symbol": "✓"   # 或 "○", "V", "v" — 依表格慣例
# }
```

**新增: 勾選符號偵測邏輯**:
```python
# _detect_check_symbol(worksheet) -> str
# 掃描表單中已有的勾選符號，學習該表的慣用符號
# 優先順序: ✓ > ○ > V > ✔ > √
# 如果表單全空，預設使用 "✓"
```

**驗收標準**:
- [ ] 能正確偵測「合格/不合格兩欄」結構
- [ ] 能自動偵測表單慣用的勾選符號
- [ ] field_map 中包含 pass_cell 和 fail_cell

---

### Task 2.2 — 回填引擎支援勾選寫入

**檔案**: `backend/app/services/form_fill.py`

**修改**: `_auto_fill_excel()` 方法

**新增邏輯**:
```python
# 當欄位類型為 "dual_column_checkbox" 時:
#
# if ai_result.is_anomaly == False:
#     write pass_cell = "✓"    # 在合格欄打勾
#     write fail_cell = ""     # 不合格欄留空
# else:
#     write pass_cell = ""
#     write fail_cell = "✓"    # 在不合格欄打勾
#     write remarks_cell = ai_result.anomaly_description  # 備註寫異常描述
```

**Excel 勾選符號格式保留**:
```python
# 寫入勾選符號時，確保:
# 1. 字型大小與周圍一致
# 2. 水平置中對齊
# 3. 如果原表有邊框，保留邊框
```

**驗收標準**:
- [ ] 合格項目正確在合格欄打勾
- [ ] 不合格項目正確在不合格欄打勾 + 備註填入異常描述
- [ ] 勾選符號格式與原表一致

---

### Task 2.3 — 照片自動插入報告

**檔案**: `backend/app/services/form_fill.py`

**需求**: 將拍攝的照片自動插入到 Word/Excel 報告中

**Excel 照片插入**:
```python
# 新增方法: _insert_photos_excel(workbook, photo_bindings)
#
# 策略 A: 如果表單有「照片」欄位 → 插入到對應位置
# 策略 B: 如果沒有 → 在最後一個工作表後新增「照片附件」工作表
#
# 照片附件工作表格式:
# ┌──────┬────────────────┬──────────────────┐
# │ 編號 │ 檢查項目        │ 現場照片          │
# ├──────┼────────────────┼──────────────────┤
# │  1   │ 絕緣電阻測量    │ [插入照片 300x225]│
# │  2   │ 接地電阻測量    │ [插入照片 300x225]│
# └──────┴────────────────┴──────────────────┘
#
# 使用 openpyxl.drawing.image.Image 插入
```

**Word 照片插入**:
```python
# 新增方法: _insert_photos_word(document, photo_bindings)
#
# 策略 A: 如果表單有「照片」預留位置 → 插入到對應位置
# 策略 B: 如果沒有 → 在文件末尾新增「照片記錄」章節
#
# 照片記錄格式:
# === 照片記錄 ===
# 1. 絕緣電阻測量
#    [照片] (寬度 12cm)
#    拍攝時間: 2026-03-13 14:30
#
# 使用 python-docx add_picture() 插入
```

**照片處理**:
```python
# _prepare_photo_for_insert(photo_base64, max_width_cm=12) -> BytesIO
# 1. base64 解碼為 PIL Image
# 2. 壓縮至合理大小（< 500KB）
# 3. 保持比例縮放
# 4. 轉為 BytesIO 供 openpyxl/docx 使用
```

**驗收標準**:
- [ ] Excel 報告自動產生照片附件工作表
- [ ] Word 報告自動在末尾插入照片
- [ ] 照片大小合理、不會撐爆檔案
- [ ] 每張照片標註對應的檢查項目名稱

---

### Task 2.4 — 照片自動命名與編號

**檔案**: `flutter_app/lib/services/photo_service.dart` (新建)

**需求**:
```dart
// 照片命名規則:
// {序號}-{項目簡稱}_{時間戳}.jpg
// 例: "03-絕緣電阻_20260313_143052.jpg"
//
// PhotoService 職責:
// 1. 管理照片的 task_id 綁定
// 2. 自動命名
// 3. 壓縮與格式轉換
// 4. 本地儲存管理（避免 localStorage 爆滿）
// 5. 提供上傳佇列
```

**驗收標準**:
- [ ] 照片按規則自動命名
- [ ] 照片與 task_id 綁定關係持久化
- [ ] 儲存空間管理（單張壓縮 < 300KB）

---

## Sprint 3：法規標準值 + 歷史資料

> **目標**: AI 不再只是「讀數字」，還能自動判定合格/不合格

### Task 3.1 — 建立法規標準值資料庫

**檔案**: 新建 `backend/app/data/inspection_standards.py`

**資料結構**:
```python
# InspectionStandard 結構:
# {
#   "standard_id": "elec_insulation_lv",
#   "category": "electrical",           # 大類: electrical / fire / mechanical / pressure
#   "equipment_type": "低壓配電設備",
#   "inspection_item": "絕緣電阻",
#   "unit": "MΩ",
#   "pass_condition": ">=",              # >=, <=, ==, range, in
#   "pass_value": 1.0,                   # 合格閾值
#   "warning_value": 2.0,               # 警告閾值（接近不合格）
#   "regulation": "屋內線路裝置規則第 59 條",
#   "notes": "三相各相分別量測"
# }

# 第一版覆蓋範圍（最常見的定檢類型）:
ELECTRICAL_STANDARDS = [
    # 低壓配電
    {"item": "絕緣電阻", "unit": "MΩ", "pass": ">=1.0", "reg": "屋內線路裝置規則§59"},
    {"item": "接地電阻", "unit": "Ω", "pass": "<=100", "reg": "屋內線路裝置規則§59"},
    {"item": "漏電斷路器動作時間", "unit": "ms", "pass": "<=100", "reg": "CNS 14816"},
    {"item": "漏電斷路器動作電流", "unit": "mA", "pass": "<=30", "reg": "CNS 14816"},
    # ...
]

FIRE_STANDARDS = [
    {"item": "滅火器壓力", "unit": "MPa", "pass": "range:0.7-0.98", "reg": "消防法§6"},
    {"item": "緊急照明持續時間", "unit": "min", "pass": ">=30", "reg": "消防法§6"},
    # ...
]

MECHANICAL_STANDARDS = [
    {"item": "馬達溫度", "unit": "°C", "pass": "<=80", "reg": "CNS 14400"},
    {"item": "振動值", "unit": "mm/s", "pass": "<=4.5", "reg": "ISO 10816"},
    # ...
]
```

**驗收標準**:
- [ ] 至少覆蓋電氣(15項)、消防(10項)、機械(10項) 共 35 項標準
- [ ] 每項標準都有法規依據
- [ ] 支援 >=, <=, range, enum 四種比較模式

---

### Task 3.2 — AI 分析結果自動比對標準值

**檔案**: `backend/app/services/form_fill.py`

**新增方法**:
```python
# auto_judge(ai_result, field_name, standards_db) -> JudgmentResult
#
# JudgmentResult:
# {
#   "field_name": "絕緣電阻",
#   "measured_value": 52.3,
#   "unit": "MΩ",
#   "standard": ">=1.0 MΩ",
#   "judgment": "pass",          # pass / fail / warning / unknown
#   "regulation": "屋內線路裝置規則§59",
#   "confidence": 0.98
# }
#
# 邏輯:
# 1. 從 ai_result.readings 中取出數值
# 2. 根據 field_name 和 unit 在 standards_db 中查找匹配的標準
# 3. 比對數值與標準值
# 4. 回傳判定結果
#
# 當無法匹配標準時:
# - judgment = "unknown"
# - 提示使用者人工判定
```

**整合到回填流程**:
```python
# 在 map_fields() 中:
# 1. 數值欄位 → 填入量測值
# 2. 判定欄位 → 根據 auto_judge 結果填入「合格」/「不合格」
# 3. 勾選欄位 → 根據 judgment 在正確的欄位打勾
#
# 這樣就不需要 AI 猜測合格/不合格，而是有明確的法規依據
```

**驗收標準**:
- [ ] 能根據量測值自動判定合格/不合格
- [ ] 判定結果正確回填到表單
- [ ] 無法匹配標準時標記為 unknown，不會誤判

---

### Task 3.3 — 歷史資料儲存與查詢

**檔案**: 新建 `backend/app/services/history_service.py`

**資料結構**:
```python
# InspectionHistory 結構:
# {
#   "history_id": "uuid",
#   "equipment_id": "EQ-001",        # 設備編號
#   "equipment_name": "B棟1F配電盤",
#   "template_id": "tmpl_001",       # 使用的表單模板
#   "inspection_date": "2026-03-13",
#   "inspector": "王小明",
#   "results": [
#     {
#       "field_name": "絕緣電阻_R相",
#       "value": 52.3,
#       "unit": "MΩ",
#       "judgment": "pass"
#     },
#     ...
#   ]
# }
```

**儲存**: 第一版用 SQLite（本地），未來遷移到 Supabase

**查詢 API**:
```
GET  /api/history?equipment_id=EQ-001          # 查某設備所有歷史
GET  /api/history?equipment_id=EQ-001&latest=1 # 查最近一次
POST /api/history                               # 儲存本次結果
```

**驗收標準**:
- [ ] 每次定檢完成後自動儲存歷史
- [ ] 能根據設備編號查詢歷史記錄
- [ ] 資料持久化在 SQLite

---

### Task 3.4 — 前次數值自動帶入

**檔案**: `backend/app/services/form_fill.py`

**需求**: 定檢表常有「前次數值」欄位，自動帶入上次的量測值

**實作**:
```python
# 在 map_fields() 中新增:
#
# 1. 偵測欄位名稱含有「前次」「上次」「前回」等關鍵字
# 2. 如果 history_service 中有該設備的歷史資料
# 3. 自動填入上次對應欄位的值
#
# 同時: 產出趨勢警告
# if 連續 3 次值持續惡化 (如電阻持續下降):
#     warning = "⚠ 絕緣電阻連續 3 次下降 (80→65→52 MΩ)，建議安排維修"
```

**驗收標準**:
- [ ] 「前次數值」欄位自動帶入歷史值
- [ ] 無歷史資料時該欄位留空，不會報錯
- [ ] 趨勢異常時產出警告訊息

---

## Sprint 4：端到端流程整合

> **目標**: 把所有模組串成「一條龍」—— 使用者只做三件事：上傳表單、拍照、下載

### Task 4.1 — 設計一條龍工作流

**檔案**: 新建 `flutter_app/lib/screens/one_stop_inspection_screen.dart`

**完整流程**:
```
┌─────────────────────────────────────────────────────────────┐
│  STEP 0: 選擇表單                                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ 📄 上傳新表單 │  │ 📋 最近使用   │  │ 📁 範本庫    │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│                                                              │
│  上傳/選擇 Excel 或 Word 定檢表                              │
│  → 系統自動分析結構（已有功能）                               │
│  → 自動產出拍照任務清單（Sprint 1 新功能）                    │
└──────────────────────────┬──────────────────────────────────┘
                           ↓
┌──────────────────────────────────────────────────────────────┐
│  STEP 1: 填寫基本資訊                                        │
│                                                              │
│  設備名稱: [B棟1F配電盤     ]  ← 可從歷史自動帶入             │
│  設備編號: [EQ-001          ]                                │
│  檢查日期: [2026-03-13      ]  ← 自動填今天                  │
│  檢查人員: [王小明           ]  ← 記住上次輸入                │
│  廠區位置: [B棟1樓電氣室    ]                                 │
│                                                              │
│  [下一步 →]                                                  │
└──────────────────────────┬──────────────────────────────────┘
                           ↓
┌──────────────────────────────────────────────────────────────┐
│  STEP 2: 逐項拍照（使用 Sprint 1 的 guided_capture）         │
│                                                              │
│  系統依序顯示拍照任務:                                        │
│  "第 3 項 / 共 15 項：絕緣電阻 R相"                          │
│  "請拍攝三用電表的讀數畫面"                                   │
│                                                              │
│  [📷 拍照]  [⏭ 跳過]  [← 上一項]                            │
│                                                              │
│  拍完最後一項 → 自動進入下一步                                │
└──────────────────────────┬──────────────────────────────────┘
                           ↓
┌──────────────────────────────────────────────────────────────┐
│  STEP 3: AI 自動處理（全自動，使用者等待）                    │
│                                                              │
│  ⏳ 正在分析 15 張照片...  (3/15)                             │
│  ⏳ 正在比對法規標準值...                                     │
│  ⏳ 正在映射到表單欄位...                                     │
│  ⏳ 正在產出回填預覽...                                       │
│                                                              │
│  內部流程:                                                    │
│  1. 批次上傳照片 → Gemini AI 分析                            │
│  2. 分析結果 + photo_task_bindings → 精準映射                │
│  3. auto_judge() 自動判定合格/不合格                         │
│  4. 歷史資料帶入「前次數值」                                  │
│  5. 產出預覽結果                                              │
└──────────────────────────┬──────────────────────────────────┘
                           ↓
┌──────────────────────────────────────────────────────────────┐
│  STEP 4: 預覽確認                                            │
│                                                              │
│  ┌─────────────────────────────────────────────────┐        │
│  │ 欄位            │ 回填值      │ 信心度 │ 判定   │        │
│  ├─────────────────┼─────────────┼────────┼────────┤        │
│  │ 絕緣電阻 R相    │ 52.3 MΩ    │ 🟢 95% │ ✅合格 │        │
│  │ 絕緣電阻 S相    │ 48.7 MΩ    │ 🟢 93% │ ✅合格 │        │
│  │ 接地電阻        │ 85.2 Ω     │ 🟡 78% │ ✅合格 │ ← 可編輯│
│  │ 漏電斷路器      │ ⚠ 未拍照   │ 🔴     │ ⬜     │        │
│  └─────────────────┴─────────────┴────────┴────────┘        │
│                                                              │
│  🔴 低信心度項目需確認 (2 項)                                │
│  ⚠ 跳過未拍照項目 (1 項)                                    │
│                                                              │
│  [✏️ 修改]  [📥 產出報告]                                    │
└──────────────────────────┬──────────────────────────────────┘
                           ↓
┌──────────────────────────────────────────────────────────────┐
│  STEP 5: 下載完成的報告                                      │
│                                                              │
│  ✅ 報告產出完成！                                            │
│                                                              │
│  📄 電氣設備定期檢查表_B棟1F配電盤_20260313.xlsx             │
│     [📥 下載]  [📤 分享]  [📧 Email]                        │
│                                                              │
│  📸 照片附件已自動插入報告                                    │
│  📊 歷史記錄已儲存                                           │
│                                                              │
│  [🔄 開始下一台設備]  [🏠 回首頁]                            │
└──────────────────────────────────────────────────────────────┘
```

**驗收標準**:
- [ ] 完整走完 Step 0-5 不需跳到其他畫面
- [ ] Step 1 基本資訊能從歷史自動帶入
- [ ] Step 2 拍照任務與表單欄位正確綁定
- [ ] Step 3 全自動處理（使用者只看進度條）
- [ ] Step 4 低信心度項目有明顯標記
- [ ] Step 5 下載的檔案格式正確、可直接上繳

---

### Task 4.2 — 基本資訊記憶功能

**檔案**: `flutter_app/lib/services/user_defaults_service.dart` (新建)

**需求**:
```dart
// 記住使用者常用的基本資訊:
// - 檢查人員姓名（上次輸入的）
// - 常用廠區位置（下拉選單）
// - 常用設備清單（搜尋建議）
//
// 儲存在 SharedPreferences
// 下次開啟自動帶入
```

**驗收標準**:
- [ ] 檢查人員姓名自動帶入上次輸入的
- [ ] 檢查日期自動填入今天
- [ ] 設備名稱有歷史搜尋建議

---

## Sprint 5：批次定檢 + 範本庫

> **目標**: 50 台同型設備，用同一表單快速定檢

### Task 5.1 — 批次定檢模式

**檔案**: 新建 `flutter_app/lib/screens/batch_inspection_screen.dart`

**UI 流程**:
```
1. 選擇表單範本
2. 輸入設備清單（手動輸入 或 匯入 CSV 或 掃描 QR Code）
   - 設備 1: B棟1F配電盤 (EQ-001)
   - 設備 2: B棟2F配電盤 (EQ-002)
   - ...
3. 開始批次定檢:
   - 系統顯示「目前: 設備 3/50 - B棟3F配電盤」
   - 每台設備走完拍照流程後自動跳到下一台
   - 支援暫停/繼續（可跨時段完成）
4. 全部完成後:
   - 一次產出 50 份已填好的定檢表
   - 打包為 ZIP 下載
```

**後端支援**:
```python
# 新增端點: POST /api/auto-fill/batch-execute
# Input: {
#   "template_id": "tmpl_001",
#   "equipment_list": [
#     {"equipment_id": "EQ-001", "equipment_name": "B棟1F配電盤", "photo_bindings": [...]}
#   ]
# }
# Output: ZIP file containing all filled forms
```

**驗收標準**:
- [ ] 能輸入設備清單（至少支援手動輸入）
- [ ] 逐台引導拍照
- [ ] 一次產出所有報告
- [ ] 支援暫停/繼續

---

### Task 5.2 — 範本庫（最近使用 + 預設範本）

**檔案**: 修改 `flutter_app/lib/screens/template_selection_screen.dart`

**需求**:
```
範本庫分三區:

┌─── 最近使用 ───────────────────────────┐
│ 📄 電氣設備定期檢查表.xlsx  (3天前)     │
│ 📄 消防安全設備檢查表.docx  (1週前)     │
└────────────────────────────────────────┘

┌─── 預設範本 ───────────────────────────┐
│ ⚡ 電氣設備定期檢查（通用）              │
│ 🔥 消防安全設備檢查（通用）              │
│ ⚙️ 馬達/泵浦定期檢查（通用）            │
│ 🏗️ 廠區 5S 巡查表（通用）              │
└────────────────────────────────────────┘

┌─── 上傳新表單 ─────────────────────────┐
│ 📤 上傳 Excel (.xlsx)                   │
│ 📤 上傳 Word  (.docx)                   │
└────────────────────────────────────────┘
```

**「最近使用」邏輯**:
```dart
// 每次使用表單後，記錄到本地:
// - template_id
// - 檔案名稱
// - 最後使用時間
// - 使用次數
// 按最後使用時間排序，最多保留 10 筆
```

**驗收標準**:
- [ ] 最近使用的表單出現在最上方
- [ ] 預設範本可直接選用（不需上傳檔案）
- [ ] 上傳過的表單下次不需重新上傳

---

### Task 5.3 — 預設範本製作

**檔案**: 新建 `backend/app/data/default_templates/`

**第一批範本**:
```
default_templates/
├── electrical_inspection.xlsx     # 電氣設備定期檢查表（通用版）
├── fire_safety_inspection.xlsx    # 消防安全設備檢查表（通用版）
├── motor_inspection.xlsx          # 馬達/泵浦定期檢查表
├── 5s_audit.xlsx                  # 廠區 5S 巡查表
└── templates_index.json           # 範本索引
```

**templates_index.json**:
```json
[
  {
    "template_id": "default_electrical",
    "name": "電氣設備定期檢查表（通用版）",
    "category": "electrical",
    "icon": "⚡",
    "description": "適用於低壓配電盤、開關箱等電氣設備定期檢查",
    "fields_count": 25,
    "file": "electrical_inspection.xlsx"
  }
]
```

**驗收標準**:
- [ ] 至少 4 種預設範本
- [ ] 每種範本覆蓋該類型最常見的檢查項目
- [ ] 範本格式接近業界通用格式

---

## Sprint 6：整合測試 + 真實表單驗證

> **目標**: 用真實的工廠定檢表走完整個流程，確保可以上線

### Task 6.1 — 端到端自動化測試

**檔案**: 新建 `backend/tests/test_e2e_inspection.py`

**測試案例**:
```python
# Test Case 1: 電氣設備定檢 — 全合格場景
# 1. 上傳 electrical_inspection.xlsx
# 2. 模擬 15 個拍照任務的 AI 結果（全合格）
# 3. 執行回填
# 4. 驗證: 所有合格欄打勾、數值正確、備註為空

# Test Case 2: 電氣設備定檢 — 有異常場景
# 1. 上傳同表單
# 2. 模擬第 3 項不合格（絕緣電阻 0.5 MΩ < 1.0 MΩ）
# 3. 執行回填
# 4. 驗證: 第 3 項不合格欄打勾、備註有異常描述

# Test Case 3: 消防設備定檢 — Word 格式
# 1. 上傳 fire_safety_inspection.docx
# 2. 模擬結果
# 3. 驗證 Word 回填正確

# Test Case 4: 勾選式表單
# 1. 上傳含「合格/不合格」兩欄的表單
# 2. 驗證勾選符號寫入正確位置

# Test Case 5: 照片插入
# 1. 回填 + 照片
# 2. 驗證照片出現在附件頁

# Test Case 6: 歷史資料
# 1. 先做一次定檢並儲存
# 2. 再做第二次，驗證「前次數值」自動帶入
```

**驗收標準**:
- [ ] 6 個測試案例全部通過
- [ ] 產出的 Excel/Word 可用 Office 正常開啟
- [ ] 格式與原表一致

---

### Task 6.2 — 真實表單驗證清單

**用真實的工廠定檢表測試**:

| # | 表單名稱 | 格式 | 頁數 | 驗證重點 |
|---|---------|------|------|---------|
| 1 | 電氣設備定期檢查表 | .xlsx | 2頁 | 勾選欄 + 數值欄 |
| 2 | 消防安全設備定期檢查表 | .docx | 3頁 | Word 表格回填 |
| 3 | 馬達定期維護紀錄表 | .xlsx | 1頁 | 多設備同表 |
| 4 | 壓力容器定期檢查紀錄 | .xlsx | 4頁 | 跨頁表格 |
| 5 | 廠區 5S 巡查表 | .xlsx | 1頁 | 大量勾選 |

**每份表單的驗證步驟**:
1. 上傳表單 → 確認欄位偵測正確率 > 90%
2. 模擬拍照 → 確認任務清單合理
3. AI 分析 → 確認數值提取正確
4. 自動判定 → 確認合格/不合格正確
5. 回填下載 → 用 Office 開啟確認格式正確
6. 與人工填寫版本對比 → 確認內容一致

**驗收標準**:
- [ ] 5 份真實表單全部走完流程
- [ ] 每份表單欄位偵測率 > 90%
- [ ] 回填結果與人工填寫版本一致度 > 85%
- [ ] 格式保留完整，可直接上繳

---

## 附錄 A：檔案修改清單

| Sprint | 檔案 | 動作 | 說明 |
|--------|------|------|------|
| 1 | `backend/app/services/form_fill.py` | 修改 | 新增 generate_photo_tasks() |
| 1 | `backend/app/api/auto_fill.py` | 修改 | 新增 /generate-photo-tasks 端點 |
| 1 | `flutter_app/lib/screens/guided_capture_screen.dart` | 新建 | 引導拍照畫面 |
| 1 | `backend/app/services/form_fill.py` | 修改 | map_fields() 支援 photo_task_bindings |
| 2 | `backend/app/services/form_fill.py` | 修改 | 勾選欄位偵測 + 回填 |
| 2 | `backend/app/services/form_fill.py` | 修改 | _insert_photos_excel/word() |
| 2 | `flutter_app/lib/services/photo_service.dart` | 新建 | 照片管理服務 |
| 3 | `backend/app/data/inspection_standards.py` | 新建 | 法規標準值資料庫 |
| 3 | `backend/app/services/form_fill.py` | 修改 | auto_judge() |
| 3 | `backend/app/services/history_service.py` | 新建 | 歷史資料服務 |
| 4 | `flutter_app/lib/screens/one_stop_inspection_screen.dart` | 新建 | 一條龍主畫面 |
| 4 | `flutter_app/lib/services/user_defaults_service.dart` | 新建 | 使用者偏好記憶 |
| 5 | `flutter_app/lib/screens/batch_inspection_screen.dart` | 新建 | 批次定檢 |
| 5 | `flutter_app/lib/screens/template_selection_screen.dart` | 修改 | 範本庫 UI |
| 5 | `backend/app/data/default_templates/` | 新建 | 預設範本檔案 |
| 6 | `backend/tests/test_e2e_inspection.py` | 新建 | 端到端測試 |

---

## 附錄 B：每個 Sprint 完成後的里程碑檢查

### Sprint 1 完成時 ✅
- 能上傳表單 → 自動產出拍照清單 → 拍照綁定欄位 → 精準映射
- **實測**: 上傳一份電氣定檢表，走完拍照流程，確認映射結果

### Sprint 2 完成時 ✅
- 勾選式表單正確打勾 + 照片自動插入報告
- **實測**: 用含「合格/不合格」兩欄的表單，確認勾選和照片

### Sprint 3 完成時 ✅
- AI 能自動判定合格/不合格 + 歷史資料帶入
- **實測**: 模擬異常數值，確認自動判定正確；做兩次定檢，確認歷史帶入

### Sprint 4 完成時 ✅
- 使用者只需: 選表單 → 填基本資訊 → 拍照 → 下載報告
- **實測**: 請一位非開發人員走完整個流程，計時 < 15 分鐘

### Sprint 5 完成時 ✅
- 50 台同型設備可批次定檢，一次產出所有報告
- **實測**: 模擬 5 台設備批次定檢，確認 5 份報告正確產出

### Sprint 6 完成時 ✅
- 用 5 份真實工廠表單驗證，全部通過
- **可以正式上線部署**

---

## 附錄 C：技術決策記錄

| 決策 | 選擇 | 理由 |
|------|------|------|
| 歷史資料儲存 | SQLite (本地優先) | 離線可用、部署簡單、未來可遷移 |
| 法規標準值 | Python dict (硬編碼) | 第一版快速上線，未來改 DB |
| 勾選符號 | Unicode ✓ | 跨平台相容性最佳 |
| 照片壓縮 | JPEG quality=75, max 300KB | 平衡畫質與檔案大小 |
| 批次報告打包 | ZIP | 50 份報告合理的傳輸方式 |

---

*本文件為活文件，隨開發進展持續更新每個 Task 的完成狀態*
