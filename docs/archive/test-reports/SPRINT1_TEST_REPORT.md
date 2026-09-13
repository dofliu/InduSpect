# Sprint 1 測試報告

> **測試日期**: 2026-03-13
> **測試範圍**: Task 1.1, 1.2, 1.4 (Backend)
> **測試結果**: **52/52 全部通過 (100%)**

---

## 測試範圍

| Task | 功能 | 測試項目數 | 結果 |
|------|------|-----------|------|
| 1.1 | generate_photo_tasks() | 22 | 全部通過 |
| 1.4 | precision_map_fields() | 16 | 全部通過 |
| - | 邊界情況 | 6 | 全部通過 |
| - | 單位推測 | 8 | 全部通過 |

---

## Task 1.1 測試明細: generate_photo_tasks()

### 基本資訊分類
- [x] 設備名稱正確歸類為基本資訊
- [x] 設備編號正確歸類為基本資訊
- [x] 檢查日期正確歸類為基本資訊（含預設值=今天）
- [x] 檢查人員姓名正確歸類為基本資訊
- [x] 基本資訊共 4 個欄位（不含簽名）

### 結論/簽核分類
- [x] 綜合判定結論正確歸類為結論
- [x] 檢查人員簽名正確歸類為結論（不被「人員」關鍵字搶走）
- [x] 結論共 2 個欄位

### 拍照任務合併邏輯
- [x] 同一列(Row)的數值+判定+備註欄位合併為一個拍照任務
- [x] Row 6 三個欄位合併為一個任務，主要名稱=「絕緣電阻 R相」
- [x] 任務內部正確分類 value/judgment/remarks field_ids
- [x] 預期類型 = number，預期單位 = MΩ（絕緣優先於電阻）
- [x] 拍照提示語包含單位
- [x] 所有 15 個原始欄位都被覆蓋（無遺漏）
- [x] 基本資訊欄位不出現在拍照清單中

### 修正紀錄
1. **絕緣電阻單位**: `_guess_unit` 改用有序搜尋，「絕緣」(MΩ) 優先於「電阻」(Ω)
2. **簽名欄位分類**: 結論判斷優先於基本資訊判斷，避免「簽名」被「人員」搶走
3. **備註欄位識別**: `_is_judgment_field` 排除備註類，「異常說明」歸備註不歸判定

---

## Task 1.4 測試明細: precision_map_fields()

### 數值精準映射
- [x] 絕緣電阻 R相 → 52.3 (信心度 95%)
- [x] AI readings 正確匹配到對應欄位

### 判定自動映射
- [x] is_anomaly=False → 合格
- [x] is_anomaly=True → 不合格

### 備註智慧映射
- [x] 異常項目 → 填入異常描述（含具體數值 85.2Ω）
- [x] 正常項目 → 填入「正常」或摘要（不填「不合格」）

### 基本資訊回填
- [x] 設備名稱 = B棟1F配電盤（從 inspection_results 取得）
- [x] 檢查日期 = 2026-03-13
- [x] 未映射欄位 <= 4 個（結論/簽核類不會被自動映射）

---

## 新增/修改檔案清單

| 檔案 | 動作 | 說明 |
|------|------|------|
| `backend/app/services/form_fill.py` | 修改 | 新增 generate_photo_tasks(), precision_map_fields() 及輔助方法 |
| `backend/app/api/auto_fill.py` | 修改 | 新增 /generate-photo-tasks, /precision-map-fields 端點 |
| `backend/tests/test_sprint1_photo_tasks.py` | 新建 | Sprint 1 完整測試 (52 案例) |

---

## 新增 API 端點

| 端點 | 方法 | 說明 |
|------|------|------|
| `/api/auto-fill/generate-photo-tasks` | POST | 從 field_map 產生拍照任務清單 |
| `/api/auto-fill/precision-map-fields` | POST | 帶 photo_task_bindings 的精準映射 |
