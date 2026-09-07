# InduSpect AI — 專案開發規則

## 專案定位
工業設備智慧巡檢系統，Flutter 行動 App + FastAPI 後端 + Gemini AI。

## 核心功能（僅兩個）
1. **完整檢測 Pipeline**：上傳定檢表 → 一鍵自動檢測（引導拍照 → AI 批次分析 → 自動回填 → 自動 AI 報告）→ 分享（離線暫存）
2. **歷史紀錄**：GPS 定位、可編輯標題、搜尋、重新分享

其餘功能（快速分析、範本系統、設備管理、雲端同步等）目前為隱藏狀態，非核心開發重點。

## 關鍵檔案
| 檔案 | 用途 |
|------|------|
| `flutter_app/lib/screens/form_inspection_screen.dart` | ★ 核心：5 步驟檢測流程 |
| `flutter_app/lib/screens/unified_history_screen.dart` | 歷史紀錄 |
| `flutter_app/lib/screens/dashboard_screen.dart` | 主頁（2 入口） |
| `flutter_app/lib/models/form_inspection_record.dart` | 檢測紀錄 model |
| `flutter_app/lib/services/database_service.dart` | SQLite v3 CRUD |
| `flutter_app/lib/services/location_service.dart` | GPS 定位 |
| `flutter_app/lib/services/share_queue_service.dart` | 離線分享佇列 |
| `flutter_app/lib/services/standards_engine.dart` | ★ Tier 0 離線法規判定引擎 |
| `flutter_app/lib/services/ocr_reading_parser.dart` | Tier 1a 離線 OCR 讀值解析 |
| `flutter_app/lib/services/image_quality_service.dart` | 拍照品質閘門（模糊/曝光/反光，純本機） |
| `flutter_app/lib/services/pdf_report_service.dart` | 申報用 PDF 報告產生器（純 Dart 離線，內嵌 `assets/fonts/` 繁中字型） |
| `backend/app/services/gemini_client.py` | ★ 後端唯一 Gemini 入口（google-genai SDK，延遲建立 + 快取） |
| `flutter_app/DEVELOPMENT.md` | 完整開發文件 |
| `LAUNCH_PLAN.md` | 產品化評估與 90 天上線行動計畫 |
| `BLADE_INSPECTION_SPEC.md` | 風力機葉片地面目視檢測模組規格（獨立功能，Phase 0） |
| `blade_prototype/` | ★ 葉片模組 Phase 0 演算法原型（Python/OpenCV；分割、三片互比、前緣粗糙度、影片六點鐘取幀、逐片聲音異常、圖文報告產生器、拍攝品質閘門；`SENSITIVITY.md` 合成影像靈敏度、`REAL_IMAGE_VALIDATION.md` 真實影像實測、`scripts/` 語料抓取/驗證/圖文報告三支腳本） |

## 開發慣例
- 路徑操作用 `package:path/path.dart`，不手動 `split('/')`
- photoPaths 用 JSON array 序列化（向後相容 `|||`）
- 日期用 ISO8601 字串存 SQLite
- DB migration 必須處理既有使用者升級路徑
- 繁體中文註解，技術術語保留英文

## 測試
```bash
flutter test          # 全部 155 tests（widget_test 已修復，不再排除）
cd backend && GEMINI_API_KEY=ci-fake-key pytest tests/ --asyncio-mode=auto   # 191 pytest
cd blade_prototype && pip install -r requirements.txt && pytest              # 67 tests（葉片原型，合成影像/音軌夾具）
```
Flutter 155 tests / 後端 191 pytest 全綠（2026-09-04 實測）。DB 測試使用 `sqflite_common_ffi` in-memory。標準資料為單一來源：改 `backend/app/data/inspection_standards.py` 後必須跑 `python backend/scripts/export_standards.py` 重新匯出 JSON（有同步守門測試）。

## 已知問題追蹤
- GitHub Issues #14-#19 已全數修復並關閉（2026-04-16）
- GitHub Issues #27-#28 自動化 AI 定檢功能增強（2026-04-17）
- 自動定檢標準判定單位換算修正（2026-05-25）：修正 kΩ/MΩ 單位數量級誤判與匹配假陽性，新增 `judge-readings` 端點。詳見 `flutter_app/DEVELOPMENT.md` 變更紀錄
- 自動 AI 定檢標準判定串接（2026-05-28）：`judge-readings` 串入 `form_inspection_screen.dart`，量測欄位 AI 辨識後自動帶出合格/不合格/警告與法規依據
- 現場惡劣環境因應（2026-08-31）：拍照品質閘門（Laplacian 模糊/曝光/反光偵測，不合格提示重拍）+ 連線可達性探測（廠區有 AP 沒 uplink 時快速失敗走離線路徑，不再空等 60 秒）
- 後端 SDK 汰換（2026-09-04）：`google-generativeai`（已停止維護）→ `google-genai`；新增 `backend/app/services/gemini_client.py` 為唯一 Gemini 入口（延遲建立 client、依 key 快取），AI 呼叫一律走 `gemini_client.generate_text()`。相依鏈連帶升版 httpx/pydantic/fastapi。
- PDF 報告輸出（2026-09-02）：LAUNCH_PLAN 第 5-8 週項目完成；`pdf_report_service.dart` 純 Dart 離線產生申報用 PDF（判定/法規依據/單位換算/AI 報告/照片附件），完成頁與歷史紀錄皆可匯出。字型子集重新產生用 `flutter_app/scripts/subset_pdf_font.py`
- 葉片模組真實影像驗證（2026-09-06）：75 張公開 CC 授權真實風機照片實測分割與結構定位。修好「地面與塔架相連導致輪轂落在地面」與「塔軸走訪提早停住」兩個 bug（設計範圍內輪轂命中 10/30 → 14/30），新增 `blade_proto/quality.py` 拍攝品質閘門（零誤放行）。**關鍵發現：晴空無雲命中 12/14、有雲只有 1/13——天空模型是唯一真正的瓶頸，Phase 1 之前要先補**。詳見 `blade_prototype/REAL_IMAGE_VALIDATION.md`
- 產品化 P0 批次 + Tier 0 離線判定（2026-08-31）：Issues #44/#45/#47 完成；判定引擎 Dart 化（離線判定取代「待判定」）、判定持久化（SQLite v4）、release 簽署/後端認證/模型 ID 汰換/CI 全量收緊。詳見 `LAUNCH_PLAN.md` 與 `flutter_app/DEVELOPMENT.md` 變更紀錄

## 既有 error（已修復）
- ~~`measurement.dart`: `sqrt` 未 import `dart:math`~~ → 已修復
- ~~`widget_test.dart`: `MyApp` 已不存在~~ → 已更新為 `InduSpectApp`
