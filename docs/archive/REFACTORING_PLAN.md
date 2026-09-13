# InduSpect AI — 程式碼重構計畫

> **建立日期**: 2026-03-13
> **目標**: 移除冗餘程式碼、合併重複功能、提升可維護性
> **原則**: 重構不改變外部行為，所有測試必須通過

---

## 現況問題

### 核心問題：`form_fill.py` 3,053 行巨獸
一個檔案承擔了 7 種不同職責：
- 拍照任務產生 (lines 91-335)
- 勾選欄位偵測 (lines 353-852)
- 精準欄位映射 (lines 854-1048)
- 範本建立/解析 (lines 1049-1545)
- 表單結構分析 (lines 1546-1877)
- 自動回填引擎 (lines 1878-2451)
- 照片插入/判定/批次 (lines 2452-3053)

### 具體冗餘清單

| # | 冗餘類型 | 位置 | 說明 |
|---|---------|------|------|
| 1 | 重複方法 | `preview_fill()` + `preview_auto_fill()` | 兩個 preview，差異僅在回傳格式 |
| 2 | 重複方法 | `analyze_template()` + `analyze_structure()` | 兩個分析，差異僅在深度 |
| 3 | 重複方法 | `_deep_analyze_excel()` + `_parse_excel_template()` | 兩套 Excel 解析 |
| 4 | 重複方法 | `_deep_analyze_word()` + `_parse_word_template()` | 兩套 Word 解析 |
| 5 | 重複方法 | `_auto_fill_excel()` + `_auto_fill_excel_enhanced()` | 兩套 Excel 回填 |
| 6 | 重複方法 | `_auto_fill_word()` + `_auto_fill_word_enhanced()` | 兩套 Word 回填 |
| 7 | 無用儲存 | `self._templates = {}` | 記憶體 dict，重啟消失，已有 TemplateService |
| 8 | 無用儲存 | `self._reports = {}` | 記憶體 dict，報告狀態無法持久化 |
| 9 | 重複 API | `/analyze` → `/map` → `/preview` → `/execute` | 步驟式 API 與 `/one-stop-process` 重複 |
| 10 | 重複 API | `/upload` + `/create-from-file` | 兩個範本上傳端點功能相同 |

---

## 重構執行計畫

### 🔴 高優先 Phase 1：拆分 + 合併

#### Task R1: 拆分 `form_fill.py` 為 5 個專責服務
```
form_fill.py (3053行)
    ↓ 拆分為
├── form_analysis_service.py    — 表單結構分析 + 欄位偵測
├── form_filling_service.py     — 自動回填 + preview + 報告產生
├── checkbox_service.py         — 勾選欄位偵測 + 回填
├── photo_processing_service.py — 照片插入 + 準備
├── judgment_service.py         — 自動判定 + 批次判定
└── form_fill.py                — 精簡為 orchestrator（呼叫上述服務）
```

#### Task R2: 合併重複的 Auto-Fill 方法
- `_auto_fill_excel_enhanced()` 取代 `_auto_fill_excel()`
- `_auto_fill_word_enhanced()` 取代 `_auto_fill_word()`
- `auto_fill_with_checkboxes()` 整合進 `auto_fill()`

#### Task R3: 統一 API 端點
- 步驟式 API (`/analyze`, `/map`, `/preview`, `/execute`) → 改為內部方法
- 保留 `/one-stop-process` 和 `/batch-process` 作為主要 API
- 合併 `/upload` 和 `/create-from-file` 為 `/templates/create`

### 🟡 中優先 Phase 2：清理 + 品質

#### Task R4: 移除無用程式碼
- 刪除 `self._templates`, `self._reports` 記憶體儲存
- 刪除 `list_templates()`, `get_template()`, `delete_template()` 舊方法
- 刪除 `get_report_status()`, `get_report_file()` 無用追蹤
- 清除未使用的 import (`copy`, 未用的 `WD_ALIGN_PARAGRAPH`)

#### Task R5: 建立共用基礎設施
- `conftest.py` — 測試共用 fixture，移除 11 個測試檔的重複前置碼
- `constants.py` — 集中管理魔術字串 (field types, judgment values)
- 統一錯誤處理模式

### 🟢 低優先 Phase 3：後續改善（暫不執行）
- 合併重複的分析方法 (`analyze_template` + `analyze_structure`)
- 合併重複的解析方法 (`_deep_analyze_*` + `_parse_*_template`)
- 統一儲存層（全部改用 SQLite 或 PostgreSQL）

---

## 測試策略
- 每完成一項重構，執行全部 448 個測試
- 測試全通過才進入下一項
- 重構後產生最終測試報告

---

## 實際成果 ✅ 已完成

| 指標 | 重構前 | 重構後 | 改善 |
|------|--------|--------|------|
| form_fill.py 行數 | 3,053 | 2,208 | -28% |
| 服務檔案數 | 3 | 7 | 模組化 |
| 重複方法對數 | 6 | 0 | 100% |
| templates API 端點 | 8 | 3 | -63% |
| 無用 import | 11 | 0 | 100% |
| 測試通過率 | 448/448 | 448/448 | 維持 |

> 詳細測試報告：`backend/tests/REFACTORING_TEST_REPORT.md`
