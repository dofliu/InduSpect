# 動態模板建立功能 - 測試報告

> **測試日期**: 2026-03-06
> **測試環境**: Python 3.x, 無 Gemini API Key (走 fallback 路徑)
> **測試人員**: AI Assistant
> **測試分支**: `claude/dynamic-template-creation-aIDWG`

---

## 測試目標

驗證動態模板建立功能 (`FormFillService.create_template_from_file`) 能否正確地：

1. 解析真實格式的 Excel (.xlsx) 和 Word (.docx) 定檢表
2. 深度分析文件結構，提取欄位位置資訊 (field_map)
3. 透過 AI 或 fallback 路徑產生有效的 `InspectionTemplate` JSON
4. 綁定原始文件資訊 (`source_file`) 以供未來回填使用

---

## 測試環境設定

由於測試環境無法存取 Gemini API，測試腳本透過以下方式模擬：

- Mock `google.generativeai` 模組，`MockModel.generate_content()` 回傳空 JSON `{}`
- AI 驗證邏輯偵測到空 JSON 缺少 `sections`，自動降級至 fallback 路徑
- Mock `app.services.embedding` 和 `app.services.rag` 避免不必要的依賴

此設計驗證了：
- AI 回傳無效結果時的降級機制正確運作
- Fallback 規則引擎能獨立產生高品質模板

---

## 測試檔案

| 檔案 | 格式 | 說明 |
|------|------|------|
| `電氣設備定期檢查表.xlsx` | Excel | 模擬台北科技大學電氣設備定檢表，含 14 項目、8 量測項 |
| `消防安全設備定期檢查表.docx` | Word | 模擬消防安全設備定檢表，含滅火器/消防栓/火災警報等區段 |

---

## 測試結果摘要

| 測試項目 | Excel (.xlsx) | Word (.docx) | 結果 |
|----------|:------------:|:------------:|:----:|
| 深度結構分析 | 47 個欄位偵測 | 47 個欄位偵測 | PASS |
| 原始文字擷取 | 正確擷取 | 正確擷取 | PASS |
| 模板建立 (fallback) | 成功 | 成功 | PASS |
| JSON 格式驗證 | 通過 | 通過 | PASS |
| source_file 綁定 | 正確 | 正確 | PASS |

---

## 詳細測試結果

### 測試 1: 電氣設備定期檢查表 (Excel)

**模板 ID**: `TEMP-B3F00A19`

#### 深度分析結果
- 偵測到 **47 個欄位**
- 欄位類型涵蓋 `text`、`number`、`date` 等
- 正確識別 Cell 位置 (如 `A2`, `B3` 等)

#### 產出模板統計

| 區段 | Section ID | 欄位數 | 說明 |
|------|-----------|--------|------|
| 基本資訊 | `basic_info` | 13 | 表單編號、設備名稱、檢查日期等 |
| 檢測項目 | `inspection_items` | 11 | 外觀檢查、接線端子、接地系統等含判定選項 |
| 量測數據 | `measurements` | 16 | 電壓、電流、絕緣電阻等含單位與範圍 |
| 綜合評估 | `conclusion` | 4 | 總體評估、改善建議、簽名、照片 |
| **合計** | | **44** | |

#### 欄位品質
- 檢測項目欄位自動帶有 `radio` 選項 (合格/不合格/需改善)
- 量測欄位正確附帶 `unit` (V, A, MΩ, °C 等)
- 照片欄位自動加入各區段
- 預估檢測時間: 88 分鐘

---

### 測試 2: 消防安全設備定期檢查表 (Word)

**模板 ID**: `TEMP-CC6F288C`

#### 深度分析結果
- 偵測到 **47 個欄位**
- 包含表格欄位與段落欄位
- 正確識別 `table_row` 與 `paragraph` 類型位置

#### 產出模板統計

| 區段 | Section ID | 欄位數 | 說明 |
|------|-----------|--------|------|
| 基本資訊 | `basic_info` | 10 | 表單編號、建築物名稱、檢查日期等 |
| 檢測項目 | `inspection_items` | 18 | 滅火器、消防栓、火災警報器等含判定選項 |
| 量測數據 | `measurements` | 3 | 水壓、電壓等含單位 |
| 綜合評估 | `conclusion` | 3 | 總體評估、簽名、照片 |
| **合計** | | **34** | |

#### 欄位品質
- 正確過濾區段標題 (如「一、滅火器」不會變成欄位)
- 檢測項目帶有 `radio` 選項
- 預估檢測時間: 68 分鐘

---

## JSON 格式驗證

兩份模板均通過以下驗證：

- [x] 必要頂層欄位: `template_id`, `template_name`, `template_version`, `category`, `created_at`, `updated_at`, `metadata`, `sections`
- [x] metadata 包含: `company`, `department`, `inspection_cycle_days`, `estimated_duration_minutes`
- [x] 每個 section 包含: `section_id`, `section_title`, `section_order`, `fields`
- [x] 每個 field 包含: `field_id`, `field_type`, `label`
- [x] `source_file` 綁定包含: `file_name`, `file_type`, `field_map`

---

## 關鍵修復記錄

### 1. AI 回傳空 JSON 未觸發 fallback

**問題**: AI 回傳 `{}` 時，正規表達式匹配成功並解析為有效 JSON，導致模板缺少所有必要欄位。

**修復**: 新增驗證邏輯，檢查 `sections` 是否存在且非空：
```python
if template_json.get('sections') and len(template_json['sections']) > 0:
    return template_json
else:
    logger.warning("AI 回傳的模板 JSON 缺少 sections，使用 fallback")
```

### 2. 區段標題被誤判為可填欄位

**問題**: 「一、外觀檢查」等區段標題被 fallback 引擎當作可填欄位處理。

**修復**: 新增 `_is_section_header()` 和 `_is_non_field_item()` 輔助方法，過濾：
- 中文數字編號 (一、二、三...)
- 括號編號 (（一）（二）...)
- 表頭文字 (項次、檢查項目...)
- 過長/過短文字

### 3. Fallback 模板品質不佳

**問題**: 原始 fallback 只產生 2 個區段，欄位未分類，無單位/選項資訊。

**修復**: 重寫 fallback 引擎，智慧分類為 4 個區段：
- **基本資訊**: 日期、編號、名稱等
- **檢測項目**: 檢查項目 + 自動加入合格/不合格選項
- **量測數據**: 含單位的數值欄位 + 自動偵測單位
- **綜合評估**: 總體判定、建議、簽名

---

## 輸出檔案

| 檔案 | 說明 |
|------|------|
| `output_excel_template.json` | Excel 模板完整 JSON (44 欄位) |
| `output_word_template.json` | Word 模板完整 JSON (34 欄位) |
| `test_template_creation.py` | 測試腳本 |
| `create_test_forms.py` | 測試表單產生器 |

---

## 結論

動態模板建立功能在 fallback 路徑下運作正常，能夠：

1. **正確解析** Excel 和 Word 兩種格式的定檢表
2. **智慧分類** 欄位到適當的區段
3. **自動識別** 量測單位、判定選項、照片需求
4. **產出有效** 的 InspectionTemplate JSON，符合系統規格
5. **綁定原始文件**，為未來 AI 自動回填做準備

待 Gemini API Key 配置後，可進一步測試 AI 主路徑的模板產生品質。
