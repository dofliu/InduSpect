---
name: vendor-form-filling
description: 自動辨識定檢資訊並回填至不同廠商格式的表單文件
---

# 廠商表單自動回填技能

## 功能概述

此技能可在完成巡檢工作後，自動將定檢結果回填至不同廠商提供的 Excel/Word 模板中，產生符合廠商格式的正式文件。

## 工作流程

### 1. 模板預處理 (一次性設定)

```
1. 上傳廠商提供的空白表單 (Excel/Word)
2. AI 分析表格結構，識別欄位位置
3. 建立欄位對應表 (Mapping)：
   - 廠商欄位名稱 → 系統標準欄位 ID
4. 儲存為 JSON 模板配置
```

### 2. 巡檢資料收集

```
1. 使用 InduSpect AI 完成現場巡檢
2. 所有資料存入標準化 JSON 格式
3. 包含：設備資訊、量測數值、照片、異常描述
```

### 3. 自動回填產生文件

```
1. 選擇目標廠商模板
2. 系統讀取模板配置與 Mapping
3. 將巡檢資料填入對應位置
4. 產生完成的 Excel/Word/PDF 文件
```

## 技術實作

### 模板配置格式

```json
{
  "vendor_id": "VENDOR_A",
  "vendor_name": "台灣電力公司",
  "template_type": "excel",
  "template_file": "templates/taipower_form.xlsx",
  "field_mappings": [
    {
      "vendor_field": "設備編號",
      "cell_position": "B3",
      "system_field": "equipment_id"
    },
    {
      "vendor_field": "檢測日期",
      "cell_position": "D3",
      "system_field": "inspection_date",
      "format": "YYYY/MM/DD"
    },
    {
      "vendor_field": "溫度(°C)",
      "cell_position": "C15",
      "system_field": "temperature"
    }
  ],
  "photo_placement": {
    "sheet": "照片附件",
    "start_cell": "A1",
    "layout": "grid_2x3"
  },
  "signature_position": "E25"
}
```

### 使用的套件

- **Excel**: `excel` (Dart) / `openpyxl` (Python)
- **Word**: `docx` (Python) / `python-docx`
- **PDF**: `pdf` (Dart) / `reportlab` (Python)

## 執行步驟

### 手動觸發

```bash
# Python 版本
python scripts/fill_vendor_form.py \
  --inspection-data data/inspection_2025-01.json \
  --vendor-template templates/taipower_form.xlsx \
  --output output/filled_report.xlsx
```

### 在 App 中使用

1. 點擊「匯出報告」
2. 選擇「廠商格式」
3. 選擇目標廠商模板
4. 系統自動產生文件

## 新增廠商模板

### 步驟 1: 準備空白模板

將廠商提供的空白表單放入 `templates/` 目錄

### 步驟 2: 建立配置檔

```bash
python scripts/create_vendor_mapping.py \
  --template templates/new_vendor_form.xlsx \
  --output configs/new_vendor.json
```

### 步驟 3: AI 輔助識別 (可選)

```bash
python scripts/ai_analyze_template.py \
  --template templates/new_vendor_form.xlsx
```

AI 會自動識別欄位並建議對應關係

### 步驟 4: 手動調整配置

編輯 JSON 配置檔，確認欄位對應正確

## 支援的文件格式

- Excel (.xlsx, .xls)
- Word (.docx)
- PDF (填入可編輯欄位)

## 限制與注意事項

- 鎖定的 Excel 儲存格可能無法填入
- PDF 需預先建立表單欄位
- 圖片插入位置可能因版本差異而偏移
