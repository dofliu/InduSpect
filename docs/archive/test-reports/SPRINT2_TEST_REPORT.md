# Sprint 2 測試報告

> **測試日期**: 2026-03-13
> **測試範圍**: Task 2.1, 2.2, 2.3, 2.4 (Backend + Flutter)
> **測試結果**: **79/79 全部通過 (100%)**

---

## 測試總覽

| Task | 功能 | 測試項目數 | 結果 |
|------|------|-----------|------|
| 2.1 | detect_checkbox_columns() Excel | 13 | 全部通過 |
| 2.1 | detect_checkbox_columns() ○/× 符號 | 2 | 全部通過 |
| 2.1 | detect_checkbox_columns() Word | 3 | 全部通過 |
| 2.2 | auto_fill_with_checkboxes() Excel | 6 | 全部通過 |
| 2.2 | auto_fill_with_checkboxes() Word | 5 | 全部通過 |
| 2.3 | _prepare_photo_for_insert() | 8 | 全部通過 |
| 2.3 | insert_photos_into_report() Excel | 13 | 全部通過 |
| 2.3 | insert_photos_into_report() Word | 8 | 全部通過 |
| 2.3 | 邊界情況 | 6 | 全部通過 |
| 2.4 | 照片命名規則 | 10 | 全部通過 |
| 2.4 | 命名唯一性 | 2 | 全部通過 |
| 2.4 | 壓縮規格定義 | 3 | 全部通過 |

---

## Task 2.1 測試明細: detect_checkbox_columns()

### Excel 雙欄偵測
- [x] 偵測到至少 3 個勾選項目（合格/不合格雙欄）
- [x] 偵測到已有的勾選符號 = ✓
- [x] 每個項目都有 pass_cell / fail_cell
- [x] 至少一個項目有 remarks_cell
- [x] field_type = dual_column_checkbox
- [x] 項目名稱正確

### ○/× 符號偵測
- [x] 偵測到勾選項目（正常/異常模式）
- [x] 偵測到勾選符號 = ○

### Word 雙欄偵測
- [x] 偵測到 3 個勾選項目
- [x] 項目名稱正確

---

## Task 2.2 測試明細: auto_fill_with_checkboxes()

### Excel 勾選回填
- [x] 合格項目在合格欄寫入 ✓、不合格欄保持空白
- [x] 不合格項目在不合格欄寫入 ✓、合格欄保持空白
- [x] 不合格項目備註包含異常數值

### Word 勾選回填
- [x] 合格/不合格欄位正確寫入
- [x] 對應欄位保持空白

---

## Task 2.3 測試明細: insert_photos_into_report()

### 照片前處理 (_prepare_photo_for_insert)
- [x] base64 照片成功解碼處理
- [x] bytes 照片成功處理
- [x] 大照片縮放至 600x450 以內
- [x] 大照片壓縮至 500KB 以下
- [x] 無照片資料回傳 None（不崩潰）
- [x] 支援 data:image/jpeg;base64, 前綴格式
- [x] RGBA 照片自動轉為 RGB
- [x] 大照片壓縮後大小合理

### Excel 照片插入
- [x] 產生有效的 Excel 檔案
- [x] 新增「照片附件」工作表
- [x] 標題 = 「現場照片記錄」
- [x] 表頭正確（編號、檢查項目、現場照片、拍攝時間）
- [x] 資料列檢查項目名稱正確
- [x] 拍攝時間正確
- [x] 插入正確數量的照片
- [x] 原始工作表未被影響

### Word 照片插入
- [x] 產生有效的 Word 檔案
- [x] 原始內容保留
- [x] 包含「照片記錄」章節標題
- [x] 照片項目名稱正確
- [x] 拍攝時間正確
- [x] 插入正確數量的圖片
- [x] 檔案大小合理（< 2MB）

### 邊界情況
- [x] 無效照片不影響整體處理（跳過無效，繼續處理有效）
- [x] 不支援的檔案類型正確拋出 ValueError
- [x] 照片按 sequence 排序

---

## 新增/修改檔案清單

| 檔案 | 動作 | 說明 |
|------|------|------|
| `backend/app/services/form_fill.py` | 修改 | 新增照片插入方法 + Pillow import |
| `backend/app/api/auto_fill.py` | 修改 | 新增 /insert-photos 端點 |
| `backend/requirements.txt` | 修改 | 新增 Pillow==10.2.0 |
| `backend/tests/test_sprint2_checkbox.py` | 新建 | Task 2.1+2.2 測試 (29 案例) |
| `backend/tests/test_sprint2_photos.py` | 新建 | Task 2.3 測試 (35 案例) |
| `backend/tests/test_sprint2_photo_naming.py` | 新建 | Task 2.4 命名測試 (15 案例) |
| `flutter_app/lib/services/photo_service.dart` | 新建 | Flutter 照片管理服務 |
| `flutter_app/test/photo_service_test.dart` | 新建 | Dart 單元測試 |

---

## 新增方法/端點清單

### Task 2.3 新增方法
| 方法 | 說明 |
|------|------|
| `insert_photos_into_report()` | 入口：照片插入報告 |
| `_insert_photos_excel()` | Excel 照片附件工作表 |
| `_insert_photos_word()` | Word 照片記錄章節 |
| `_prepare_photo_for_insert()` | 照片前處理（解碼、縮放、壓縮） |

### Task 2.3 新增 API 端點
| 端點 | 方法 | 說明 |
|------|------|------|
| `/api/auto-fill/insert-photos` | POST | 上傳文件+照片，回傳含照片的文件 |
