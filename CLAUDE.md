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
| `flutter_app/lib/screens/dashboard_screen.dart` | 主頁（3 入口：檢測／歷史／葉片） |
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
| `flutter_app/lib/screens/blade_inspection_screen.dart` | ★ 葉片檢測五步流程（選資產 → 引導拍攝 → 分析 → 人工確認 → 報告） |
| `flutter_app/lib/screens/blade_capture_guide_screen.dart` | 葉片引導拍攝（格位清單 + 上次同格位照片對照 + GPS 導回拍攝點；用系統相機保住 5x 長焦與全解析度） |
| `flutter_app/lib/services/blade_surface_service.dart` | ★ 表面層前緣粗糙度（`surface.py` 的 Dart 對照實作，跑在 isolate） |
| `flutter_app/lib/services/blade_analysis_service.dart` | ★ 葉片分析編排 + **門檻表單一來源**（前後緣 rms 比 5.0/2.0/1.5） |
| `flutter_app/lib/services/blade_capture_gate.dart` | 葉片照拍攝品質判定：影像層（模糊/曝光）+ **結構層**（`quality.py` 移植，三片半徑離散是唯一有鑑別力的拒收條件） |
| `flutter_app/lib/services/blade_image_ops.dart` | ★ OpenCV 對照的影像運算（8-bit Lab、**網格大核中值**、REFLECT_101 高斯、5×5 橢圓閉、連通元件、chamfer 距離變換） |
| `flutter_app/lib/services/blade_geometry_service.dart` | ★ 幾何層分割（`segmentation.py` 的局部天空模型 + 遮罩清理 + 地平線） |
| `flutter_app/lib/services/blade_structure_service.dart` | ★ 結構定位（輪轂/塔架/三片葉片、第二個轉子） |
| `flutter_app/lib/services/blade_geometry_compare.dart` | ★ 三片剪影互比（`geometry.py` 移植）+ `runGeometryPipeline` |
| `flutter_app/lib/services/blade_trend_service.dart` | ★ 跨次趨勢（**只比無因次的前後緣 rms 比**，px 值跨次不可比） |
| `flutter_app/lib/services/blade_ai_retry_service.dart` | AI 解讀補跑佇列（只補 `human_status = pending` 的） |
| `flutter_app/lib/screens/blade_history_screen.dart` | 葉片歷史與趨勢（資產驅動資料模型的兌現處） |
| `flutter_app/lib/services/blade_ai_service.dart` | 葉片專用 AI prompt（正常結構清單）+ 值域夾回 |
| `flutter_app/lib/services/blade_report_builder.dart` | 葉片報告（**不輸出「合格」**），交給 `pdf_report_service.dart` |
| `BLADE_INSPECTION_SPEC.md` | 風力機葉片地面目視檢測模組規格（獨立功能，Phase 0 原型 + Phase 1 App 化已完成） |
| `blade_prototype/` | ★ 葉片模組 Phase 0 演算法原型（Python/OpenCV；分割、三片互比、前緣粗糙度、影片六點鐘取幀、逐片聲音異常、圖文報告產生器、拍攝品質閘門；`SENSITIVITY.md` 合成影像靈敏度、`REAL_IMAGE_VALIDATION.md` 真實影像實測、`scripts/` 語料抓取/驗證/圖文報告三支腳本） |

## 開發慣例
- 路徑操作用 `package:path/path.dart`，不手動 `split('/')`
- photoPaths 用 JSON array 序列化（向後相容 `|||`）
- 日期用 ISO8601 字串存 SQLite
- DB migration 必須處理既有使用者升級路徑
- 繁體中文註解，技術術語保留英文

## 測試
```bash
flutter test          # 全部 286 tests（widget_test 已修復，不再排除）
cd backend && GEMINI_API_KEY=ci-fake-key pytest tests/ --asyncio-mode=auto   # 191 pytest
cd blade_prototype && pip install -r requirements.txt && pytest              # 78 tests（葉片原型，合成影像/音軌夾具）
```
Flutter 286 tests / 後端 191 pytest / 葉片原型 78 pytest 全綠（2026-09-07 CI 實測）。DB 測試使用 `sqflite_common_ffi` in-memory。標準資料為單一來源：改 `backend/app/data/inspection_standards.py` 後必須跑 `python backend/scripts/export_standards.py` 重新匯出 JSON（有同步守門測試）。

## 已知問題追蹤
- GitHub Issues #14-#19 已全數修復並關閉（2026-04-16）
- GitHub Issues #27-#28 自動化 AI 定檢功能增強（2026-04-17）
- 自動定檢標準判定單位換算修正（2026-05-25）：修正 kΩ/MΩ 單位數量級誤判與匹配假陽性，新增 `judge-readings` 端點。詳見 `flutter_app/DEVELOPMENT.md` 變更紀錄
- 自動 AI 定檢標準判定串接（2026-05-28）：`judge-readings` 串入 `form_inspection_screen.dart`，量測欄位 AI 辨識後自動帶出合格/不合格/警告與法規依據
- 現場惡劣環境因應（2026-08-31）：拍照品質閘門（Laplacian 模糊/曝光/反光偵測，不合格提示重拍）+ 連線可達性探測（廠區有 AP 沒 uplink 時快速失敗走離線路徑，不再空等 60 秒）
- 後端 SDK 汰換（2026-09-04）：`google-generativeai`（已停止維護）→ `google-genai`；新增 `backend/app/services/gemini_client.py` 為唯一 Gemini 入口（延遲建立 client、依 key 快取），AI 呼叫一律走 `gemini_client.generate_text()`。相依鏈連帶升版 httpx/pydantic/fastapi。
- PDF 報告輸出（2026-09-02）：LAUNCH_PLAN 第 5-8 週項目完成；`pdf_report_service.dart` 純 Dart 離線產生申報用 PDF（判定/法規依據/單位換算/AI 報告/照片附件），完成頁與歷史紀錄皆可匯出。字型子集重新產生用 `flutter_app/scripts/subset_pdf_font.py`
- 葉片模組 Phase 1 App 化（2026-09-07）：SQLite **v5** 三張獨立表（`wt_assets`/`wt_capture_sessions`/`wt_detections`，既有定檢三表不動）、表面層 Dart 移植（與 Python 原型逐 zone 對照到小數第三位一致）、分析編排層、葉片專用 AI prompt、葉片拍攝閘門、三個畫面 + dashboard 第三個入口。三個**不可退化**的約定：①`WtMedia.qualityOk` 未分析時是 `null`，判斷一律用 `!= true`；②`human_status` 預設 `pending`，葉片報告**不輸出「合格」**；③演算法的 severity 是下限，AI 只能往上加不能往下砍。兩個規格修正：取像用系統相機（`camera` plugin 碰不到 5x 望遠與最高像素模式）、不給 `image_quality_service` 加遮罩而另寫 `blade_capture_gate.dart`（遮罩要先分割，而分割正是要被閘門守的那一步）
- 葉片模組 Phase 2 幾何層 Dart 移植（2026-09-07）：`segmentation.py` + `geometry.py` + `quality.py` 移植完成，整機照現在會真的被量測（三片剪影互比）。**中值改成網格模式**是這批唯一的行為改變：逐像素大核中值在手機上跑不動（1024×820×3 約 1.4G 次 bin 運算），改成只在 step=16 的網格點上算真中值 + 雙線性內插（約 64M 次）；真實照片代價是設計範圍內輪轂命中 23/30 → 22/30。**降工作尺度是更糟的選擇**（512/384/256 → 20/19/18，而且時間幾乎沒省，瓶頸在結構定位不在中值）。三個不可退化的約定：①色空間必須是 OpenCV 的 8-bit Lab（`minScale = 1.2` 是那個空間的絕對下限）；②距離變換用 OpenCV 的 5×5 chamfer 近似而非精確 EDT（Python 用 chamfer，輪轂靠 DT 最大值定位，兩邊要一致）；③拍攝閘門在三片互比**之前**且拒收時不算互比。改 `surface.py`/`segmentation.py` 後要重跑 `blade_prototype/scripts/make_*_fixture.py`，否則 Flutter 交叉驗證會紅
- 葉片模組 Phase 1 缺口已補（2026-09-07）：跨次趨勢畫面（只比無因次比值）、AI 補跑佇列（只補 `human_status = pending`，合併走與線上分析同一條規則）、葉片報告接進離線分享佇列
- 葉片模組 Phase 1 **原始缺口紀錄**（2026-09-07 盤點，已於同日補完）：①`geminiOfflinePending` 的偵測沒有補跑機制——離線時存下來、畫面也標示了，但連線後沒有任何東西把 AI 解讀跑完（`share_queue_service` 有現成模式可沿用）；②沒有葉片歷史／趨勢畫面，`getWtSessions()` 只被用來拿上次照片（`limit: 1`）、`getWtSessionsPendingShare()` 零呼叫端，所以葉片報告也還沒接離線分享佇列。資產驅動資料模型的整個價值（跨次比對）目前沒有 UI
- 葉片模組取景歧義（2026-09-07）：`find_second_rotor` 找畫面裡的第二個轉子，做成**警告不是拒收**——閘門在 75 張上已零誤放行，加拒收只會擋掉 8 張正確放行中的 2 張。過程記在 `REAL_IMAGE_VALIDATION.md` §6
- 葉片模組天空模型汰換（2026-09-07）：`segmentation.py` 預設改為**局部天空模型**（`sky_mode="local"`：大核中值估背景 + 同核估局部尺度 + 門檻 7.0），取代原本「邊緣取樣逐列多項式 + 全域尺度」（仍保留給長焦分區段照）。假設從「整張天空單一漸層」改成「天空局部平滑」。真實照片輪轂命中 14/30 → **23/30**、有雲 1/13 → **10/13**、遮罩全空 4 → **0**、holdout 1/11 → **8/11**。門檻同時對真實語料與合成夾具兩組獨立測試集取；連帶修好輪轂精修守門的尺規（`4×hub_r` → 轉子半徑）。詳見 `blade_prototype/REAL_IMAGE_VALIDATION.md` §5
- 葉片模組真實影像驗證（2026-09-06）：75 張公開 CC 授權真實風機照片實測分割與結構定位。修好「地面與塔架相連導致輪轂落在地面」與「塔軸走訪提早停住」兩個 bug（設計範圍內輪轂命中 10/30 → 14/30），新增 `blade_proto/quality.py` 拍攝品質閘門（零誤放行）。**關鍵發現：晴空無雲命中 12/14、有雲只有 1/13——天空模型是唯一真正的瓶頸，Phase 1 之前要先補**。詳見 `blade_prototype/REAL_IMAGE_VALIDATION.md`
- 產品化 P0 批次 + Tier 0 離線判定（2026-08-31）：Issues #44/#45/#47 完成；判定引擎 Dart 化（離線判定取代「待判定」）、判定持久化（SQLite v4）、release 簽署/後端認證/模型 ID 汰換/CI 全量收緊。詳見 `LAUNCH_PLAN.md` 與 `flutter_app/DEVELOPMENT.md` 變更紀錄

## 既有 error（已修復）
- ~~`measurement.dart`: `sqrt` 未 import `dart:math`~~ → 已修復
- ~~`widget_test.dart`: `MyApp` 已不存在~~ → 已更新為 `InduSpectApp`
