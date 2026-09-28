# InduSpect AI — 專案開發規則

## 專案定位
工業設備智慧巡檢系統，Flutter 行動 App + FastAPI 後端 + Gemini AI。

## 核心功能（僅兩個）
1. **完整檢測 Pipeline**：上傳定檢表 → 一鍵自動檢測（引導拍照 → AI 批次分析 → 自動回填 → 自動 AI 報告）→ 分享（離線暫存）
2. **歷史紀錄**：GPS 定位、可編輯標題、搜尋、重新分享

其餘功能（快速分析、範本系統、雲端同步、舊四步流程等）**不是隱藏，是沒有入口的死碼**（約 7,900 行，App 端 23%），
排定分批移除；清單見 `docs/PROJECT_ASSESSMENT.md` §3.A／§5。**不要往那些檔案加東西。**

另有一條平行產品線：**風力機葉片檢測**（Mode A 地面整機已上線、Mode B 近身影像規格完成未實作），
與定檢表 pipeline 不共用流程也不共用資料。

## 文件地圖（2026-09-13 整理過）
| 要找什麼 | 去哪裡 |
|---|---|
| 系統總覽、運作原理、快速開始 | `README.md` |
| 操作步驟、離線行為、常見問題 | `docs/USER_GUIDE.md` |
| App 架構、DB schema、變更紀錄 | `flutter_app/DEVELOPMENT.md` |
| **專案評估：現況／值不值得推廣／該砍什麼／下一步** | `docs/PROJECT_ASSESSMENT.md`（2026-09-16） |
| 已完成／卡在哪／下一步／刻意不做 | `ROADMAP.md`（功能願望清單已歸檔到 `docs/archive/`） |
| 產品化評估與上線計畫（快照） | `LAUNCH_PLAN.md` |
| 接棒筆記（下一個 session 先讀這個） | `docs/handover/session-handover.md` |
| **已完成或已被取代的文件** | `docs/archive/`——留作決策紀錄，**不要照著做** |

根目錄只留現行有效的文件。`arch.md`／`database.md`／`ui.md`／`prj.md`／`todo.md`／
`feature_enhancements.md`／`COMPILE_CHECK_REPORT.md` 描述的是**專案沒有採用的架構**
（Supabase、GCP 無伺服器、登入流程），已刪除（內容仍在 git 歷史），不要照它們寫程式。

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
| `flutter_app/lib/services/ai/ai_router.dart` | ★ Tier 1b：這一次分析走哪一層（`chooseAiTier` 純函式在 `ai_tier_policy.dart`）；雲端 `GeminiCloudBackend`／端側 `GemmaLocalBackend` 都實作 `AiBackend`。**端側只是備援不是取代、不做讀值、結果標「離線初判」、查不到就不開** |
| `flutter_app/lib/services/ai/flutter_gemma_runner.dart` | 全 App **唯一** import `flutter_gemma` 的檔案；沒有單元測試（沒原生可跑），靠實機。上游換版只改這裡 |
| `backend/app/services/gemini_client.py` | ★ 後端唯一 Gemini 入口（google-genai SDK，延遲建立 + 快取） |
| `flutter_app/DEVELOPMENT.md` | 完整開發文件 |
| `LAUNCH_PLAN.md` | 產品化評估與 90 天上線行動計畫 |
| `flutter_app/lib/screens/blade_inspection_screen.dart` | ★ 葉片檢測五步流程（選資產 → 引導拍攝 → 分析 → 人工確認 → 報告） |
| `flutter_app/lib/screens/blade_capture_guide_screen.dart` | 葉片引導拍攝（格位清單 + 上次同格位照片對照 + GPS 導回拍攝點；用系統相機保住 5x 長焦與全解析度） |
| `flutter_app/lib/services/blade_surface_service.dart` | ★ 表面層前緣粗糙度（`surface.py` 的 Dart 對照實作，跑在 isolate） |
| `flutter_app/lib/services/blade_analysis_service.dart` | ★ 葉片分析編排 + **門檻表單一來源**（前後緣 rms 比 5.0/2.0/1.5） |
| `flutter_app/lib/services/blade_capture_gate.dart` | 葉片照拍攝品質判定：影像層（模糊/曝光）+ **結構層**（`quality.py` 移植，三片半徑離散是唯一有鑑別力的拒收條件；**側視另走一組規則** `detectSideView`：恰好兩片、一上一下、垂直 ±12°、有塔架 → 不套三片規則、只量垂掛葉片彎曲） |
| `flutter_app/lib/services/blade_image_ops.dart` | ★ OpenCV 對照的影像運算（8-bit Lab、**網格大核中值**、REFLECT_101 高斯、5×5 橢圓閉、連通元件、chamfer 距離變換） |
| `flutter_app/lib/services/blade_geometry_service.dart` | ★ 幾何層分割（`segmentation.py` 的局部天空模型 + 遮罩清理 + 地平線） |
| `flutter_app/lib/services/blade_structure_service.dart` | ★ 結構定位（輪轂/塔架/三片葉片、第二個轉子） |
| `flutter_app/lib/services/blade_geometry_compare.dart` | ★ 三片剪影互比（`geometry.py` 移植）+ `runGeometryPipeline`；**型錄轉子半徑 → cm/px**（`resolveScale` 單一規則：半徑 ÷ 三片葉長中位數；側視用垂掛那片），只換單位不改判定，沒填就沒有 cm 值 |
| `flutter_app/lib/services/blade_pose_service.dart` | ★ **相機姿態估計 + 透視補償**（`pose.py` 對照，SPEC §13-11）：仰角 = 輪轂高 ÷ 距離（距離由 EXIF 35 mm 焦距 × 型錄半徑 ÷ 量到葉長）、yaw = 塔軸偏移 ÷ overhang 預設 5 m（粗估）；留一法擬合預彎、殘差互比；半徑 |yaw| ≤ 15° 才補。**沒姿態就不補、原始值一律留、閘門看原始半徑離散** |
| `flutter_app/lib/services/blade_trend_service.dart` | ★ 跨次趨勢（**只比無因次的前後緣 rms 比**，px 值跨次不可比） |
| `flutter_app/lib/services/blade_ai_retry_service.dart` | AI 解讀補跑佇列（只補 `human_status = pending` 的） |
| `flutter_app/lib/services/blade_dsp.dart` | ★ 純 Dart DSP（FFT／STFT／自相關／savgol／medfilt）+ **葉片模組唯一一份**多項式擬合與中位數 |
| `flutter_app/lib/services/blade_audio_decode.dart` | WAV 讀取（只支援 PCM，每種讀不了的情況都有可顯示的原因） |
| `flutter_app/lib/services/blade_acoustic_service.dart` | ★ 逐片聲音異常（`acoustics.py` 的 Dart 對照）+ **三重守門**，不可用時不給數字 |
| `flutter_app/lib/services/blade_dynamics_service.dart` | 動態層編排；抽幀是注入點（`BladeFrameExtractor`），由下一行的 Android 原生實作接上 |
| `flutter_app/lib/services/blade_video_frames.dart` | ★ 裝置端抽幀（platform channel → `android/.../BladeVideoFrames.kt` 的 `MediaMetadataRetriever`）；**只有 Android**，其他平台回 null 讓服務層寫「尚未接上」；抽不到一律 null 不丟例外 |
| `flutter_app/lib/services/blade_audio_recorder.dart` | App 內錄音（`record` plugin 收在一處）+ **錄音參數的量測要求**（WAV／單聲道／自動增益與降噪一律關） |
| `flutter_app/lib/services/blade_dataset_service.dart` | ★ Phase 4 前置：訓練語料的標記規則（**標記來源是人工確認不是演算法**；`humanClean` 三個條件缺一不可） |
| `flutter_app/lib/services/blade_dataset_export.dart` | 語料打包（manifest + zip + 分享） |
| `flutter_app/lib/screens/blade_history_screen.dart` | 葉片歷史與趨勢（資產驅動資料模型的兌現處） |
| `flutter_app/lib/services/blade_ai_service.dart` | 葉片專用 AI prompt（正常結構清單）+ 值域夾回 |
| `flutter_app/lib/services/blade_report_builder.dart` | 葉片報告（**不輸出「合格」**），交給 `pdf_report_service.dart` |
| `BLADE_INSPECTION_SPEC.md` | 風力機葉片地面目視檢測模組規格（獨立功能，Phase 0 原型 + Phase 1 App 化已完成） |
| `BLADE_CLOSEUP_SPEC.md` | ★ **Mode B：葉片近身影像檢測規格**（無人機距離與角度、外觀判讀、IEA Level 1–2；規格草案，未實作，預定由學生展開；§12 是 B0 實測回饋） |
| `docs/USER_GUIDE.md` | 使用手冊（操作步驟；README 不再重複這一段） |
| `BLADE_CLOSEUP_TAXONOMY.md` | ★ Mode B 標註分類表（B0 產出）。**產物不要手改**——單一來源是 `blade_prototype/data/closeup_taxonomy.json`，改完跑 `render_closeup_taxonomy.py` |
| `blade_prototype/BLADE_TEST_REPORT.md` | ★ **葉片模組現況測試報告**（2026-09-14）：自動化測試、75 張真實影像逐張回歸、四層合成端到端、圖文報告產生、運動分割重跑、Mode B 現況、沒測到的。真實影像那一節的數字由 `scripts/blade_test_report.py` 產生（`--baseline` 逐張比對） |
| `blade_prototype/CLOSEUP_HEALTHY_SET.md` | ★ Mode B 健康照與正常結構第一版：全語料取像判定、正常結構普查、健康候選挖掘（`scripts/closeup_healthy_candidates.py`）、概略框、**人工複核工具（§6）**。三份標記檔在 `data/closeup_*_wtb.json`，**單一標註者未複核**，測試守「不得偷偷簽核」；§7 是 1,842 格健康候選的**第一遍逐格標記**（788 格純表面／42.8%，仍全部 unreviewed） |
| `blade_prototype/scripts/closeup_candidate_firstpass.py` | ★ Mode B 第一遍逐格標記（**不是簽核**）：1,842 格健康候選逐格看過，`annotator` 一律 `claude-first-pass`、狀態一律 `unreviewed`——這個名字正好被複核工具的模型名規則擋住，所以它只能改**複核順序與先驗**。實測純表面 788 格（42.8%），比 64 格抽樣推估的 64% 低 21 個百分點（邊界格被算成表面） |
| `blade_prototype/blade_proto/intake.py` + `scripts/closeup_intake_gate.py` | ★ Mode B **§1.2 取像閘門程式化**（A3）：兩層——整張丟進 Mode A，**放行 = 整機照 = 硬拒收**；凍結 ResNet18 + 邏輯迴歸判 P／W／T 給拒收理由（建議性，量不到 1/3；**B3 跨語料實測不能當閘門**，見 `CROSS_CORPUS_VALIDATION.md`）。「簡單的前景占比」實測判不出來（局部天空模型把填滿畫面的葉片當背景）。逐張結果 `data/closeup_intake_gate_wtb.json`，報告 `CLOSEUP_INTAKE_GATE.md` |
| `blade_prototype/scripts/closeup_baseline.py` | Mode B 離線基線（B2）：手工特徵 + 純 numpy 邏輯迴歸，平均逐類 recall 0.308 與 1-NN 打平。**規格 §8 三條基線未跑**（§8.1/8.2 要 Gemini 金鑰、§8.3 要 PyTorch，本容器都沒有） |
| `blade_prototype/scripts/closeup_review_tool.py` | ★ Mode B 人工複核的那道門：離線工作區（切圖 + 單檔 HTML）+ `ingest` 四條簽核規則。決策寫進 `data/closeup_review_decisions.json`（目前 0 筆） |
| `blade_prototype/CLOSEUP_EVAL_PROTOCOL.md` | ★ Mode B 評估協定（B1）：`scripts/closeup_eval.py` 把 §6 四條規則變成會拒跑的程式（切分宣告不符／未知類別／< 30 張不報數字／未普查的誤報不併進乾淨那格）＋**洩漏值 0.204 的配對實驗**＋1-NN 地板。評估域預設取像合格 839 張。真值與子集旗標已進版控，評估不需要語料本體 |
| `blade_prototype/CLOSEUP_SPLIT_GROUPS.md` | ★ Mode B 切分群組（§6 第 1 條的執行依據）：影像重疊連出 524 個 `split_group` + 群感知 5 折；**語料自己附的切分洩漏 63.4% 不可用**。產出 `data/closeup_blade_groups_wtb.json`，由 `scripts/closeup_blade_groups.py` 產生 |
| `blade_prototype/CLOSEUP_BASELINE_REPORT.md` | ★ Mode B 語料現況實測（B0）：授權盤點、開放網路可用率、cm/px 可得率、可商用語料的類別分布與標註者一致度、Mode A 閘門跨模式回歸 |
| `blade_prototype/scripts/closeup_cross_corpus.py` + `CROSS_CORPUS_VALIDATION.md` | ★ Mode B **跨語料驗證（B3）**：wtb 上訓好的取像探針與缺陷探針**不重訓**丟到 WTBs2025（CC0，7,544 張）與 HF sees-innovation（1,855 張，授權未標、只算數字）。**取像探針不能當閘門**（廂型車 59/62 判成近身葉片照；唯一跨語料成立的是 W 101/104）、Mode A 正視硬規則誤觸 3/7,544（每張人工看過，`HARD_REJECT_REVIEW` 有測試守）、側視漏洞 94/7,544 與 37/1,444、**缺陷探針 lift 0.74–1.21 ≈ 亂猜**（只有雷擊 7.7）、域分類器 0.956／0.989。逐張結果欄式打包 `data/closeup_cross_corpus.json`（約 450 KB）；外部語料的影像與特徵留在 scratchpad。WTBs2025 對照表在 `closeup_taxonomy.json` 的 `dataset_class_map.wtbs2025`（渲染器已支援多份語料） |
| `blade_prototype/scripts/fetch_commons_turbines.py` + `scripts/real_pose_validation.py` + `REAL_POSE_VALIDATION.md` | ★ Mode A **Commons 真實照片上的姿態估計與補償**（SPEC §13-11 第一次真實驗證）：Commons API 掃 32 個機型分類頁，只收 CC／PD + EXIF 35 mm 焦距 + 寬 ≥ 1600 的照片（431 頁 → 158 張可用，manifest 進版控、照片不進）；下載**只能用常用縮圖寬度**（`standard_thumb_url`，非常用寬度與原圖都會被 429）。每張走與 App 同一條路徑到 `compensate_comparison`，加輪轂高度 ±20% 靈敏度。86 張裡閘門放行 5（正視 3、側視 2），姿態可用 3/3；原始三片互比標記葉尖偏移 1 張 → 補償後 1（消掉 0、留下 1、新增 0），半徑 1 → 1；預彎擬合落在 0–8 m 的 1/3，仰角中位 4.81°；輪轂高度 ±20% 翻掉補償結論 0/3 張（model 53、model-subcat 32、view 1）——**正視放行仍只有個位數，補償在真實照片上的成績還撐不起結論**。 偏軸夾具上要重現 `blade_offaxis_reference.json`（測試守） |
| `blade_prototype/` | ★ 葉片模組 Phase 0 演算法原型（Python/OpenCV；分割、三片互比、前緣粗糙度、影片六點鐘取幀、逐片聲音異常、圖文報告產生器、拍攝品質閘門、**運動分割輪轂定位 `motion_hub.py`**、**太陽方位 `sunpos.py`**；`SENSITIVITY.md` 合成影像靈敏度、**`OFFAXIS_SENSITIVITY.md` 偏軸透視靈敏度**（`synth.render_perspective` 針孔投影，真實照片的 226 cm 假葉尖偏移在合成上重現）、`REAL_IMAGE_VALIDATION.md` 真實影像實測、**`INNOVATION_REVIEW.md` 改進方向的文獻對照與離線驗證**、**`CLOSEUP_BASELINE_REPORT.md` Mode B 語料實測**、`scripts/` 語料抓取/驗證/圖文報告/運動分割實測/近身語料抓取/分類表渲染/**人工複核工具**/**切分群組**八類腳本） |

## 開發慣例
- 路徑操作用 `package:path/path.dart`，不手動 `split('/')`
- photoPaths 用 JSON array 序列化（向後相容 `|||`）
- 日期用 ISO8601 字串存 SQLite
- DB migration 必須處理既有使用者升級路徑
- 繁體中文註解，技術術語保留英文
- **讀寫兩端要一起接**：新的 service public 方法要有人叫、新的 DB 欄位要有人寫也要有人讀，否則 CI 的死角查核（`scripts/audit_dead_ends.py`）會紅。刻意保留的死角寫進 `scripts/audit_allowlist.json` 附理由；問題修好後要把條目移除（過期條目一樣紅）

## 測試
```bash
python3 scripts/audit_dead_ends.py   # 死角查核（service 零引用／DB 欄位只讀不寫）；--report 看全部
flutter test          # 全部 599 tests（widget_test 已修復，不再排除）
cd backend && GEMINI_API_KEY=ci-fake-key pytest tests/ --asyncio-mode=auto   # 197 pytest
cd blade_prototype && pip install -r requirements.txt && pytest              # 282 tests（葉片原型，合成影像/音軌夾具 + Mode B 分類表與標記檔守門 + 測試報告聚合器 + 側視閘門 + 複核工具 + 切分群組 + 評估協定 + 普查覆蓋 + 第一遍標記守門 + 離線基線 + IEA 兩軌 + 線性探針 + §1.2 取像閘門 + 偏軸透視夾具 + 姿態估計補償 + 跨語料驗證 + Commons 真實照片姿態驗證 + Commons 抓取器）
```
Flutter 599 tests / 後端 197 pytest / 葉片原型 282 pytest 全綠（2026-09-19 本機實測；**GitHub Actions 停用期已於 2026-09-28 結束、CI 又會跑了**（見下方「本機 Flutter」條目末），本機三軌仍可先跑）。DB 測試使用 `sqflite_common_ffi` in-memory。標準資料為單一來源：改 `backend/app/data/inspection_standards.py` 後必須跑 `python backend/scripts/export_standards.py` 重新匯出 JSON（有同步守門測試）。

## 已知問題追蹤
- GitHub Issues #14-#19 已全數修復並關閉（2026-04-16）
- GitHub Issues #27-#28 自動化 AI 定檢功能增強（2026-04-17）
- 自動定檢標準判定單位換算修正（2026-05-25）：修正 kΩ/MΩ 單位數量級誤判與匹配假陽性，新增 `judge-readings` 端點。詳見 `flutter_app/DEVELOPMENT.md` 變更紀錄
- 自動 AI 定檢標準判定串接（2026-05-28）：`judge-readings` 串入 `form_inspection_screen.dart`，量測欄位 AI 辨識後自動帶出合格/不合格/警告與法規依據
- 現場惡劣環境因應（2026-08-31）：拍照品質閘門（Laplacian 模糊/曝光/反光偵測，不合格提示重拍）+ 連線可達性探測（廠區有 AP 沒 uplink 時快速失敗走離線路徑，不再空等 60 秒）
- 後端 SDK 汰換（2026-09-04）：`google-generativeai`（已停止維護）→ `google-genai`；新增 `backend/app/services/gemini_client.py` 為唯一 Gemini 入口（延遲建立 client、依 key 快取），AI 呼叫一律走 `gemini_client.generate_text()`。相依鏈連帶升版 httpx/pydantic/fastapi。
- PDF 報告輸出（2026-09-02）：LAUNCH_PLAN 第 5-8 週項目完成；`pdf_report_service.dart` 純 Dart 離線產生申報用 PDF（判定/法規依據/單位換算/AI 報告/照片附件），完成頁與歷史紀錄皆可匯出。字型子集重新產生用 `flutter_app/scripts/subset_pdf_font.py`
- 葉片模組 Phase 1 App 化（2026-09-07）：SQLite **v5** 三張獨立表（`wt_assets`/`wt_capture_sessions`/`wt_detections`，既有定檢三表不動）、表面層 Dart 移植（與 Python 原型逐 zone 對照到小數第三位一致）、分析編排層、葉片專用 AI prompt、葉片拍攝閘門、三個畫面 + dashboard 第三個入口。三個**不可退化**的約定：①`WtMedia.qualityOk` 未分析時是 `null`，判斷一律用 `!= true`；②`human_status` 預設 `pending`，葉片報告**不輸出「合格」**；③演算法的 severity 是下限，AI 只能往上加不能往下砍。兩個規格修正：取像用系統相機（`camera` plugin 碰不到 5x 望遠與最高像素模式）、不給 `image_quality_service` 加遮罩而另寫 `blade_capture_gate.dart`（遮罩要先分割，而分割正是要被閘門守的那一步）
- 解碼守門（2026-09-07）：`package:image` 的 `decodeImage` **會丟例外不只回 null**（短位元組在格式嗅探階段就 RangeError）。`lib/utils/image_decode.dart` 的 `safeDecodeImage` 是唯一入口，五處呼叫端全部走它；放在 `utils/` 是刻意的（定檢與葉片是兩條獨立功能線，不該為了一個 helper 互相 import）。實際影響是**診斷性不是崩潰**：`compressPhoto` 本來就有外層 try/catch 接得住，`image_service` 則是漏出 RangeError 而不是它自己寫的 `Exception('Failed to decode image')`
- 葉片模組 Phase 2 幾何層 Dart 移植（2026-09-07）：`segmentation.py` + `geometry.py` + `quality.py` 移植完成，整機照現在會真的被量測（三片剪影互比）。**中值改成網格模式**是這批唯一的行為改變：逐像素大核中值在手機上跑不動（1024×820×3 約 1.4G 次 bin 運算），改成只在 step=16 的網格點上算真中值 + 雙線性內插（約 64M 次）；真實照片代價是設計範圍內輪轂命中 23/30 → 22/30。**降工作尺度是更糟的選擇**（512/384/256 → 20/19/18，而且時間幾乎沒省，瓶頸在結構定位不在中值）。三個不可退化的約定：①色空間必須是 OpenCV 的 8-bit Lab（`minScale = 1.2` 是那個空間的絕對下限）；②距離變換用 OpenCV 的 5×5 chamfer 近似而非精確 EDT（Python 用 chamfer，輪轂靠 DT 最大值定位，兩邊要一致）；③拍攝閘門在三片互比**之前**且拒收時不算互比。改 `surface.py`/`segmentation.py` 後要重跑 `blade_prototype/scripts/make_*_fixture.py`，否則 Flutter 交叉驗證會紅
- 葉片模組 Phase 1 缺口已補（2026-09-07）：跨次趨勢畫面（只比無因次比值）、AI 補跑佇列（只補 `human_status = pending`，合併走與線上分析同一條規則）、葉片報告接進離線分享佇列
- 葉片模組 Phase 1 **原始缺口紀錄**（2026-09-07 盤點，已於同日補完）：①`geminiOfflinePending` 的偵測沒有補跑機制——離線時存下來、畫面也標示了，但連線後沒有任何東西把 AI 解讀跑完（`share_queue_service` 有現成模式可沿用）；②沒有葉片歷史／趨勢畫面，`getWtSessions()` 只被用來拿上次照片（`limit: 1`）、`getWtSessionsPendingShare()` 零呼叫端，所以葉片報告也還沒接離線分享佇列。資產驅動資料模型的整個價值（跨次比對）目前沒有 UI
- 葉片模組取景歧義（2026-09-07）：`find_second_rotor` 找畫面裡的第二個轉子，做成**警告不是拒收**——閘門在 75 張上已零誤放行，加拒收只會擋掉 8 張正確放行中的 2 張。過程記在 `REAL_IMAGE_VALIDATION.md` §6
- 葉片模組天空模型汰換（2026-09-07）：`segmentation.py` 預設改為**局部天空模型**（`sky_mode="local"`：大核中值估背景 + 同核估局部尺度 + 門檻 7.0），取代原本「邊緣取樣逐列多項式 + 全域尺度」（仍保留給長焦分區段照）。假設從「整張天空單一漸層」改成「天空局部平滑」。真實照片輪轂命中 14/30 → **23/30**、有雲 1/13 → **10/13**、遮罩全空 4 → **0**、holdout 1/11 → **8/11**。門檻同時對真實語料與合成夾具兩組獨立測試集取；連帶修好輪轂精修守門的尺規（`4×hub_r` → 轉子半徑）。詳見 `blade_prototype/REAL_IMAGE_VALIDATION.md` §5
- 葉片模組真實影像驗證（2026-09-06）：75 張公開 CC 授權真實風機照片實測分割與結構定位。修好「地面與塔架相連導致輪轂落在地面」與「塔軸走訪提早停住」兩個 bug（設計範圍內輪轂命中 10/30 → 14/30），新增 `blade_proto/quality.py` 拍攝品質閘門（零誤放行）。**關鍵發現：晴空無雲命中 12/14、有雲只有 1/13——天空模型是唯一真正的瓶頸，Phase 1 之前要先補**。詳見 `blade_prototype/REAL_IMAGE_VALIDATION.md`
- 產品化 P0 批次 + Tier 0 離線判定（2026-08-31）：Issues #44/#45/#47 完成；判定引擎 Dart 化（離線判定取代「待判定」）、判定持久化（SQLite v4）、release 簽署/後端認證/模型 ID 汰換/CI 全量收緊。詳見 `LAUNCH_PLAN.md` 與 `flutter_app/DEVELOPMENT.md` 變更紀錄

- 葉片模組 Phase 3 動態層（2026-09-07）：**聲音層完整移植**（`acoustics.py` → `blade_dsp.dart` + `blade_audio_decode.dart` + `blade_acoustic_service.dart`），逐片寬頻位準／高頻占比／窄頻哨音互比，轉速由包絡自相關取得（夾具上與真值差 0.1%）。三個不可退化的約定：①三重守門（週期信賴度／包絡訊噪比／低頻占比）任一不過就 `usable = false`，而**不可用時 `blades` 與 `comparisons` 是空的**，不是「全部正常」；②聲學量互比一律 `MetricDirection.high`——不限方向的話最安靜的那片會被標成前緣侵蝕；③兩層（聲音／動態）的葉片標籤用同一個規則（依通過六點鐘的先後循環），且都明寫不是實際葉片編號。
  **影片那一半只做到接縫**：Flutter 沒有純 Dart 的 H.264 解碼器，抽幀留成 `BladeFrameExtractor` typedef，編排與判定用注入的抽幀器測到底。未接上時報告寫「裝置端抽幀尚未接上」而不是「未實作」。`dynamics.py` 的逐幀角度追蹤**刻意沒有移植**——轉速已由音軌取得、三片一致性已由幾何層取得，搬過來會是「跑不動又重複」。
  移植期間發現兩件事：`compareMetric` 少了 `direction`（真缺口，已補）；`tonal_exclusive` 在手機取樣率下沒有真的驗過獨有性（Python 既有缺陷，**照原樣移植**並記在 SPEC §13，因此哨音只給 severity 2）。
  驗證方式：先把 scipy 的慣例（STFT 縮放／savgol 邊緣／medfilt 邊界）在 Python 端釘死，再逐行轉寫，最後把整條 `analyzeSamples` 轉寫回 Python 對照——兩段夾具音軌上每個輸出都到機器精度一致。改 `acoustics.py` 後要重跑 `blade_prototype/scripts/make_acoustic_fixture.py`（該產生器會**自我對帳**，與 `acoustics.py` 漂開時直接爆掉不寫檔）
- `replaceWtDetections` 跨層清除修正（2026-09-07）：原本只清傳進來那一層的 `pending`，但 `analyzeSession` 回傳的是整個場次三層的完整結果，於是上一輪標記過、這一輪不再標記的發現會留在報告上。改為清整個場次的 `pending`，`confirmed`/`rejected` 不動

- 葉片聲音層兩個未決事項結案（2026-09-07）：①**`tonal_exclusive` 修好了**——原本的「只有這片有」複查在 ±3% 窄頻帶上重跑 9 點中值濾波，但手機取樣率下那個頻帶只有 4–5 個 bin，達不到需要的 13 個，複查回 NaN 被當成「另兩片沒有」，於是它等同「突出量 ≥ 6 dB」。改成讀各片**全頻帶**突出量在該頻率上的值。實測三片同頻哨音由 3 片誤判降到 0、兩片同頻由 2 降到 0，單片仍抓得到（共消 5 個誤報）。Python/Dart 同步改、夾具重跑（既有兩段夾具的值不變——它們沒有多片同頻的情況）。②**加入 `record: ^6.2.1`** 做 App 內錄音，專案 SDK 下限 `>=3.2.0` → `>=3.5.0`。**刻意不用 7.x**（要 Dart ^3.12/Flutter 3.44，下限太高）。錄音參數是量測要求：WAV／單聲道／44.1 kHz／**自動增益與降噪一律關**（自動增益會拆掉三片互比的基準、降噪削掉要量的寬頻噪音），有測試釘住。`file_picker` 保留為備援。iOS 的 `NSMicrophoneUsageDescription` 待 `ios/` 目錄建立時補

- 葉片 Phase 4 前置：訓練語料的累積與匯出（2026-09-07）。**Phase 4 的模型本身（PatchCore/TFLite）還做不了，卡在資料不是工程**：它的前提是「同一支手機、同一台風機」的健康 patch 記憶庫，而這樣的照片目前 0 張（既有 75 張公開語料是整機照，轉子占畫面 ≤ 1/3；標註的是輪轂座標與天空條件，沒有缺陷標註）。合成影像不能替代——那是循環驗證。
  所以先做**讓那件事變得可能**的部分：`blade_dataset_service.dart` 把第四步的 `humanStatus`（原本寫進 DB 就沒有出口）整理成自我描述的語料。三個不可退化的標記規則：①**標記來源是人不是演算法**——拿 severity 當標籤只會讓模型學會模仿演算法含它的誤報；②`humanClean` 同時要求「場次已簽核 + 這份媒體沒有成立的發現 + 照片過了品質閘門」，缺一就不是健康樣本（「演算法沒報」≠「人看過沒問題」，混用會讓記憶庫摻進漏檢的真缺陷，模型把缺陷學成正常且毫無徵兆）；③簽核過的場次裡若還有 `pending` 的發現，整份媒體退回 `unreviewed`——寧可少收一筆不要收一筆錯的。
  畫面上顯示「還差多少」：規格把 Phase 4 的估時寫成「視資料量」，而在此之前沒有任何地方看得到資料量

- Issue #43 可自動化的兩項（2026-09-07）：①**lint 清理 102 → 6**。`flutter analyze` 本來就綠（CI 的門檻是 warning 以上），但 102 條 info 會把真正該看的訊息埋掉。其中 3 條 `use_build_context_synchronously` 是**真的潛在崩潰**（await 後才用 context）不是風格問題；`withOpacity` → `withValues` 連帶把 Flutter 下限提到 **3.27**（`withValues` 是 3.27 才有的——用 framework 自己的 `cupertino/colors.dart` 在 3.27 用了它、3.24 沒有來確認，不是憑印象）。刻意**留下 6 條**：`WillPopScope`→`PopScope`（`onWillPop` 是 async 而 `canPop` 必須同步，要重構）、Radio→`RadioGroup`（結構性遷移且要 Flutter 3.32）、`dart:html`（web 不是產品目標）。②**歷史列表分頁**：`ListView.builder` 本來就只建可見項目，所以卡的**不是滾動而是載入**——`FormInspectionRecord.fromMap` 每列要 `jsonDecode` 三個欄位，而列表上的「已填 N 項／異常 N 項」正是從那些欄位算出來的，省不掉解析只能限量。改成一頁 30 筆、捲到底再載（`itemBuilder` 同一幀會被呼叫多次，所以有重入守門，否則同一頁會抓好幾遍）
  **Issue #43 的另外兩項（實機完整流程、離線→恢復網路）沒有實機做不了**，issue 仍開著
- Issue #43 第二項回頭補（2026-09-07）：「離線→恢復網路」不只是沒實機驗過。①**自動分享那一半沒測過**——`ShareQueueService` 是 singleton + static 分享動作，三個邊界都沒縫，於是「把不存在的檔案標成已分享」（使用者會以為客戶收到了報告）沒有任何地方擋。沿用 `ConnectivityService` 的 `@visibleForTesting` 覆寫慣例開縫，`processPendingShares()` 改為回傳 `ShareQueueOutcome`，14 條測試守的是**什麼情況下不准標記完成**。②**「待判定」重新判定那一半根本沒實作**——畫面提示寫著「恢復網路後可重新判定」，但全 app 唯一的連線監聽是分享佇列。補上 `_watchConnectivityForRejudge()`，判斷抽成頂層純函式 `shouldRejudgeOnReconnect` / `rejudgeTargets` 才測得到。`pendingOnly` 只挑還卡在「待判定」的：本地引擎與後端讀同一份標準資料，重跑已判過的只會無聲換掉使用者看過的判定
- 離線交付的規則（2026-09-07）：**離線佇列只套在「交付」動作上**（定檢的分享／重新分享、葉片報告），**匯出動作照樣開分享面板**——面板上「儲存到檔案」／AirDrop 離線可用，擋掉等於拿掉功能，而 PDF 寫在 app 文件目錄裡使用者自己拿不到。`_exportPdfReport`／`_shareReport` 兩處各留註解說明為什麼刻意不擋。同批修掉一個已出貨的缺口：`blade_report_export` 的註解說「`pendingShare` 由呼叫端決定」但**兩個呼叫端都沒決定**，於是葉片那半條佇列從來沒被觸發過（上一批接的是讀的那端，寫的那端沒接上）；政策搬進 `exportAndShare`，回傳 `(path, shared)` 讓提示說對，並開 `isOnline`/`outputDir`/`shareSink` 三個縫讓它測得到
- 全 codebase 查核（2026-09-08）：把「這個欄位有沒有人寫、這個服務有沒有人叫」跑遍整個 codebase（348 個 service 公開方法的呼叫端數、六張表每欄位讀寫端、畫面每句「稍後／自動／恢復後」對回程式碼、每個 singleton 的測試縫）。抓到：①**`capture_points` 有人讀沒人寫**——引導拍攝畫面算「到上次拍攝點的距離」，但全 app 沒有地方寫入拍攝點，功能永遠不會亮。修法是每張**全機照**當場取 GPS 寫進 `WtMedia.latitude/longitude`（分區段照不取），`_commitMedia` 再 upsert 成資產拍攝點；位置是每張自己的不是場次的（正視與側視站在不同地方）。②`turbine_state`／`weather_note`／`inspector`／`hub_height_m` 規格 §10.2 要記、schema 有、**沒有畫面收**——補場次 metadata 對話框（可略過）、資產加輪轂高度並提示站位距離、報告摘要開頭多一行、語料 manifest 帶 `turbine_state`。③說明頁「並由雲端 AI 覆核」沒有任何實作，改成說實話。④`deleteWtAsset` 零呼叫端，補刪除入口。⑤移除死碼 `saveWtDetections`。刻意不動：`bbox_json` 無產生端、隱藏舊流程沒有連線監聽的重試、三個沒縫的 singleton（平台包裝／隱藏流程）
- 查核變成 CI 守門（2026-09-11）：`flutter_app/scripts/audit_dead_ends.py` 排在 `flutter analyze` 之前。**保守**（寧可漏報不可誤攔）：callers 只抓全 `lib/` 零引用；columns 穿過 model 方法追讀寫到不動點，但 `toString`／序列化成員／建構子不算（第一版把它們算進去，每個欄位都變成有人碰）。名單 `scripts/audit_allowlist.json` 每條附理由、**過期條目一樣紅**。基準線 4 整檔／43 成員／3 欄位放行，全部有理由。四個反向測試（拿掉拍攝點寫入、塞死方法、塞過期條目、基準）都驗過會關會開
- 影片抽幀的 Android 原生實作（2026-09-11）：`BladeFrameExtractor` 注入點由 `blade_video_frames.dart`（Dart，platform channel `com.induspect/blade_video`）+ `BladeVideoFrames.kt`（`MediaMetadataRetriever`）接上。三個決定：①`OPTION_CLOSEST` 不用 `CLOSEST_SYNC`——關鍵幀可能離要求時刻 1–2 秒，12 rpm 時 1 秒是 72°，六點鐘就不是六點鐘；②長邊縮到 1280（幾何層工作尺度 1024 留餘裕），API 27+ 用 `getScaledFrameAtTime` 省掉 4K 全尺寸 bitmap；③抽不到、解碼失敗、平台不支援**一律回 null 不丟例外**，因為 `analyzeFrames` 已把 null 定義成「這一幀沒有、其他幀照算」。畫面多了「附加轉動影片」：`file_picker` 走路徑不進記憶體，當場 `probe` 長度／尺寸；**沒有音軌的影片解不了**（抽幀時刻由音軌決定），摘要會明講。發現順帶修掉一個死角：在此之前 `WtMediaKind.video` **全 app 沒有任何建立點**——影片只被讀、從沒被附加。Dart 端 16 條 channel 契約測試；**Kotlin 端 CI 不建 APK、完全未編譯**，第一次實機要先確認它能 build、`getFrameAtTime` 在目標機型上回得出幀
- 葉片檢測改進方向的評估（2026-09-12，`blade_prototype/INNOVATION_REVIEW.md`）：八個方向逐項對文獻與業界先例，桌面能驗的兩項先做成原型釘測試。①**太陽方位** `sunpos.py`（NOAA 算法，對 NREL SPA 範例差 0.003°、對 pvlib 全天 ≤ 0.02°）——逆光是閘門唯一擋不了的拒收原因，只能從站位消掉。②**運動分割輪轂定位** `motion_hub.py`：時間中位數背景 + 細長段共點投票，取代「不像天空的才是轉子」。真實地面影片（Commons CC 授權，14 段）實測：設計範圍內五段運動法 **5/5** 定位到主風機輪轂、奇偶幀兩個獨立子集差 ≤ 11 px；同樣五段既有天空模型只有 **1/5** 全對，其餘是「8 幀一致但一致地錯」（Masenberg 落在樹梢、Lawrence Weston 落在塔身）或「2/8 對」（兩台／四台同框選到遠台或沙丘）；設計範圍外（遠景風場、無人機、相機移動、側視、小型風機）兩法皆不可用，側視是顏色法較好。疊圖在 `blade_prototype/innovation_review_assets/`。四個不可退化的約定：①穩像用 ORB+RANSAC 且相似變換要過「無縮放、轉動 ≤ 3°、平移 ≤ 20%」，整張相位相關會被轉子拉走；②靜態邊緣在殘餘晃動下會閃成細長段（塔架 × 地平線交點曾拿到與真輪轂相當的票數），用背景梯度與跨幀同 (θ,ρ) 抑制；③三片葉根黏成 Y 形時逐幀用距離變換最厚點挖掉再拆臂；④票數相近的候選取掃過半徑最大的（取像規格是單台主風機，Montrigaud 兩台同框實測只看票數會選到遠處那台）。已知限制：斜視時掃過區是橢圓、半徑量到短軸。App 端零改動，SPEC §13 新增三個待決策項（人工定錨 + 型錄尺度、幾何層改吃影片、拍攝前顯示太陽方位）
- Mode B 的 B0 完成：分類表與語料實測（2026-09-13）。**分類表**（`data/closeup_taxonomy.json` 為單一來源，`BLADE_CLOSEUP_TAXONOMY.md` 是產物，15 條守門測試）：四個機制類 17 個子類、12 項正常結構、6 個品質旗標、8 條判定順序、紀錄格式。四個設計決定：①每個損傷子類都要填「多細才看得到」（`min_cm_per_px`），否則 §9.4「沒有尺度不得報 IEA Level」沒有執行依據；②正常結構要**正面標記**不能只是「沒有缺陷標記」，否則誤報落在哪裡無從歸因；③疑似 structural 分不出來時標 `uncertain` **不准倒向 healthy**（基線論文的失效模式正是裂縫被判成健康）；④`blade_id`/`flight_id` 必填——「按葉片切不按照片切」靠必填欄位執行不是靠記得。易混淆對照做成**雙向**且有測試守（寫這張表時測試抓到一個指錯的名字與 18 條缺的反向）。IEA Level 3–5 的門檻原本**刻意留白並標「待從原文核對」**；**2026-09-16 已逐條對原文 §4.3.1 核對填入**，並修正兩軌壓成一軌的問題（見 A1 條目）。
  **語料實測**（200 張開放網路 + 1065 張 figshare 語料）五個結論：①三份主力語料只有一份可商用——**DTU v2 是 CC BY-NC 3.0 而 v1 才是 CC BY 4.0**（規格原本連的是 v2）、Blade30 **完全沒有授權聲明**、Scientific Data 那份是 CC BY 4.0；②開放網路湊不出語料——200 張裡符合取像條件的 23 張、表面可判讀 8 張、**有缺陷的 0 張**，54% 根本不是風機葉片（"turbine blade" 撈到噴射引擎、"rotor blade" 撈到直升機）；③**cm/px 量不到**——EXIF 0/200 與 3/1065，圖床重編碼與研究語料統一裁切都會剝掉，是結構性的不是找對語料就能解決；④**§1.2 的取像規則不保證解析度**——「弦向 ≥ 1/3」在 1024 px 畫面上是 0.73 cm/px，比 Mode A 地面 5x 的 0.37 還差，中段弦長要 Level 1 得要一萬像素寬的畫面，Level 1 只能靠拍外段或**讓葉片溢出畫面**；⑤可商用語料**一張健康照都沒有**，§6 第 4 條的誤報分項統計在它上面執行不了。另外量到兩位標註者的**類別一致率 94.0%**（kappa 0.897），92 次分歧全落在 `surface_injure`↔`corrosion` 與 `hide_craze`↔`craze` 兩對——那是任何模型在這份語料上的可量測上限。順帶做了一條**跨模式回歸**：把 Mode A 的分割+結構定位+拍攝閘門餵進 179 張非 Mode A 照片，**放行 0 張**，而且是靠對的條件擋的（葉片數不對、葉尖半徑離散）不是靠程式丟例外；這條寫進測試，閘門被放寬時會先紅

- Mode B 健康照與正常結構第一版（2026-09-13，`blade_prototype/CLOSEUP_HEALTHY_SET.md`）：接 B0「一張健康照都沒有」的結論做**讓那件事變得可能**的部分。四個 pass：①全部 1065 張取像判定——**839 合格、`crack` 類 0/177**（174 張整機），B0 的 32 張抽樣結論升級成全語料；②192 張正常結構普查——**避雷接點、VG 板、排水孔 0 張**（正是與結構類缺陷最易混淆的三種），出現的是紅色葉尖塗裝 10%、比例尺 6%；而**標註／前處理痕跡（灰色矩形塗抹 20%、時間戳 12%、人手工具 8%）出現在 35% 的影像上，比任何正常結構都多**——模型會學到「灰色矩形附近有缺陷」，這是比缺健康照更迫切的洩漏風險；③`closeup_healthy_candidates.py` 從兩位標註者框外挖 256 px 候選格：6,880 格 → `blade_like` 1,842 格 → 目視 64 格約 64% 真的是葉片表面 ≈ 1,200 格可用；第一版沒有紋理下限，四成是平塗灰塊與過曝白，補了 `gray_std < 4 → flat_or_blank` 才降下來；④8 張全解析度概略框。三個不可退化的約定：**全部 `unreviewed`／`pending`、annotator 是 `claude-first-pass`、測試守任何一筆不得在沒有人簽核下變 confirmed**——「兩位標註者都沒框」≠「確認乾淨」，他們只框自己要框的。一個判錯的例子留在報告裡：654 在印樣上看成硬邊陰影，全解析度看是葉片與天空的邊界，所以 Pass 2 的 `x` 標記全部要在全解析度上複核。健康候選與缺陷影像**同源**（同葉片同飛行），按葉片切時必須分在同一側，而語料沒有葉片編號——B1 要先解這個

- 葉片模組現況測試報告（2026-09-14，`blade_prototype/BLADE_TEST_REPORT.md`）：把現在能測的全部跑一遍。**沒有退化**——75 張真實照片逐張與 2026-09-07 比對 0 個欄位有差（23/30、閘門 8 放行全對、範圍外 45 張誤放行 0）；四層合成端到端數字對得上 `SENSITIVITY.md`（正視 300 cm 偏移量到 24.8/25.0 px、2 cm 侵蝕 rms 比 3.09、+4 dB 侵蝕 z=4.6、哨音 13.9 dB 獨有、風噪 0.5 判不可用且不給數字、影片 11.999/12 rpm）；運動分割 6 段真實影片重跑與 `INNOVATION_REVIEW.md` §3.1 逐段一致。**兩個新發現**寫進 `BLADE_INSPECTION_SPEC.md` §13 第 11、12 項：①閘門放行的 8 張真實照片裡**三片互比標記了 5 張**，量級是偏軸透視差不是缺陷（ed894e7a 葉尖偏移 226 cm、z=12.8），葉尖方位角間距偏離 120° 當偏軸指標鑑別力不夠（有標記者中位 6°、無標記者 2°，但 3° 的也被標）；②**側視全機照會被閘門拒收**（合成 3000×4000：只定位到 2 片、半徑差 66%）——規格 §5.1 的側視模式與 `quality.py`／`blade_capture_gate.dart` 的「葉片數 ≠ 3」規則衝突，`SENSITIVITY.md` §2 的側視數字是繞過閘門直接算的；側視**影片**不受影響。真實影像那一節的數字由 `scripts/blade_test_report.py` 產生（`--baseline` 逐張比對；5 條測試守它）。環境備註：本容器沒有 Flutter SDK（App 端引用 CI 的 497）、沒有 Playwright（PDF 用 `/opt/pw-browsers` 的 chromium headless `--print-to-pdf`）

- 側視全機照的閘門規則（2026-09-14，SPEC §13-12 已決策）：規格 §5.1 的側視模式原本會被 `quality.py`／`blade_capture_gate.dart` 以「葉片數 ≠ 3」「半徑離散」拒收，而 App 的引導拍攝本來就會要使用者拍側視——拍了一定被拒、理由還指向「等轉子轉開」。改成**側視另走一組規則**：`detect_side_view`／`detectSideView` 判定（恰好 2 個伸長元件、全部在垂直 ±12° 內、一上一下、塔架找到）→ 不套那兩條、改發「三片互比不適用、只量垂掛葉片彎曲」警告；幾何層走 `side_view_summary`／`sideViewSummary`（`comparisons` 空、多 `hanging_blade`），報告排「側視垂掛葉片彎曲」段，App 端只寫摘要備註、不產生發現、不進趨勢（單幀含預彎不是缺陷量，要等基線資料模型）。**12° 是拿 75 張真實照片定的**：≤12° 一張都不命中（語料裡沒有真正的側視照），所以真實影像閘門結果逐張 0 個欄位改變；唯一「轉子近側視」的 1573f056 是 6.6°／19.2° 的斜視，斜視含透視分量不放行。單獨一根垂直的東西不收。Dart 交叉驗證夾具 `scripts/make_side_fixture.py` → `blade_side_scene.png` + `blade_side_reference.json`（600×900、15 cm/px；改側視路徑要重跑）。順帶：`pubspec.lock` 補上 2026-09-07 加入 `record` 時漏掉的 8 條相依、windows 外掛註冊同步
- **本機 Flutter 取代 CI**（2026-09-14）：GitHub Actions 因帳號用量預算暫停，PR 上的 CI 一律秒紅（runner 未指派），**不是程式問題**。本容器可以裝 Flutter：`git clone --depth 1 -b stable https://github.com/flutter/flutter.git /opt/flutter && /opt/flutter/bin/flutter precache --linux && cd flutter_app && touch .env && flutter pub get`（storage.googleapis.com／pub.dev 從 proxy 可達，約 1.2 GB、5 分鐘），之後 `flutter analyze`（6 條已知 info）與 `flutter test`（506，約 40 秒）都能在本機跑。合併前的驗證改成本機三軌：`pytest`（blade_prototype）、`flutter test`、`scripts/audit_dead_ends.py`。
  **CI 2026-09-28 恢復**：PR #84 的四個檢查全綠（Flutter analyze+test 1m54s、Blade prototype pytest 2m23s、Backend pytest 26s、GitGuardian），runner 有被指派。停用期間的「秒紅」說法對新的 PR 已不適用；本機三軌仍然有用（比等 CI 快），但**合併前要看 PR 上的 CI 而不是只看本機**。

- 葉片近身影像檢測 Mode B 規格（2026-09-12，`BLADE_CLOSEUP_SPEC.md`）：與既有地面模式並列的**第二個模式**，輸入是「填滿畫面的葉片近身照」，靠外觀與領域知識判讀而非三片互比與物理。**輸入以無人機的距離與角度為硬約束**（8–16 m、上仰 15°、葉片弦向占畫面 ≥ 1/3），這個限縮讓 DTU 與 Blade30 等公開語料從「領域不匹配」變成可直接使用。物理上算出一個違反直覺的結果：**無人機 12 m 用廣角（24 mm eq）是 0.341 cm/px，與地面模式 5x 在 50 m 的 0.37 cm/px 幾乎相同**——提升解析度的是「近距離 **加上** 中長焦」，光是靠近沒有用；12 m / 120 mm eq 的 0.068 cm/px 才讓 IEA Level 1（1 cm² 約 15×15 px）可偵測，Level 0 針孔（< 1 mm，1.5 px）任何組態都做不到。基線是 Zhang 等人的知識增強 VLM（arXiv:2510.22868v2）：整體準確率 94.55% 看似很好，但**逐類拆開後 structural（裂縫）recall 只有 0.5**（12 張裡 6 張被判成健康，多為低光照），而 environmental 的 1.00/1.00 是在 **2 張**上得到的；重新訓練的 YOLOv8n 則是 structural 2/12、environmental 0/2，且 11 張健康照誤報在製造接縫與結構標記上。所以 §6 把評估協定寫成不可退化的四條：**按葉片切不按照片切**、**主指標是逐類 recall 不是 accuracy**、**每類少於 30 張不報 P/R/F1**、**健康照要含容易誤判的正常結構且誤報要分開報**。兩條新的不可退化約定：沒有尺度就不報 IEA 面積等級、取像條件不合就拒收並說明原因。輸出沿用 `WtDetection`，實作後 `wt_detections.bbox_json` 會第一次有生產端，屆時要移除 `audit_allowlist.json` 的對應條目

- Mode B 健康候選第一遍標記 + B2 離線基線（2026-09-14）：兩件都是「讓下一步變得可能」。①**1,842 格健康候選逐格看過一遍**（`closeup_candidate_sheets.py` 出印樣、`closeup_candidate_firstpass.py` 收成版控檔）：`b` 純表面 **788（42.8%）**、`e` 邊界格 648、`n` 不是葉片 274、`u` 判不了 132。**它改掉一個數字**——可用候選從「約 1,200 格」降到 788，原本的 64% 是 64 格抽樣，**抽樣把邊界格算成了葉片表面**（邊界格的對比來自天空不是漆面，混進健康記憶庫會讓模型把「有邊」學成正常）。三條不可退化（16 條反向測試）：`annotator` 一律 `claude-first-pass`、狀態一律 `unreviewed`，這個名字正好落在複核工具的模型名黑名單裡**進不了決策檔**（`pack` 會自我對帳，黑名單放寬到擋不住它就拒絕產出）；它只改**複核順序與先驗**（`build` 把 `b` 排最前、每格標「第一遍 b（…，未複核）」、`status` 印出各碼還差多少），不寫任何決策；`item_id` 與 `healthy` 佇列同一套雜湊，候選重新產生後對不上的由 `verify` 點名。決策檔仍 **0 筆**——先驗不是簽核。②**B2 離線基線**（`closeup_baseline.py`，寫進 `CLOSEUP_EVAL_PROTOCOL.md` §3.6）：123 維手工特徵 + 純 numpy 一對多邏輯迴歸（零初始化、無隨機種子，重跑逐位元相同）、群感知 5 折，**平均逐類 recall 0.308 對 1-NN 的 0.344、平均 F1 0.374 對 0.369——打平**，一組設計過的紋理特徵贏不了「抄最像的鄰居」。它把 `crack` 的 117 個誤報清成 0；`craze` 反贏、`hide_craze` 反輸，而那正是標註者一致率最低的一對（多半在量標註噪音）。域外 226 張整機照預測 26/56/39/23/14、命中 2/2/8/5/0——**§8.3 的縮影，§1.2 的取像閘門不是形式要求**。**規格 §8 三條基線仍未跑**：§8.1/8.2 要 Gemini API key、§8.3 要 PyTorch，本容器兩樣都沒有（環境事實不是取捨）

- **SPEC §13-11 決策：站位規範 + 報告措辭 + 姿態估計補償**（2026-09-16，三個都做）：①**站位**：`standingDistanceHint` 1.5–2× → **3–4× 輪轂高**——舊規則是仰角 27–34°，E 組掃描顯示 2.5× 以內三片投影半徑離散 > 15%、閘門**一律拒收**，3× 起放行；再遠也消不掉假葉尖偏移（6× 仍 100 cm 級），站位只讓閘門放行、讓補償有東西可補。引導拍攝改寫「站在軸線上、3–4× 輪轂高、2x 填半個畫面」。②**措辭**：正視發現沒補償一律掛「含透視分量，站位未驗證，不是缺陷量」，補了就寫仰角／偏軸／預彎擬合／原始三片值；`basisOf` 同步；側視不掛。③**姿態估計 + 補償**（`blade_proto/pose.py` ↔ `blade_pose_service.dart`）：仰角**不由塔架收斂估**（錐度與透視收斂同向、分不開），改由「輪轂高 − 1.6」÷ 直線距離，距離 = EXIF 35 mm 焦距 × 型錄半徑 ÷ 量到葉長（合成誤差 < 2°）；yaw = (塔軸外推到輪轂列的 x − hub_x) ÷ overhang 預設 5 m（對渲染的 6 m 偏大 1.2 倍，粗估；`TurbineStructure.tower_x_at_hub_px`／`BladeStructure.towerXAtHub` 新欄位）。補償模型：預彎 w 在已知姿態下對每片的假彎曲是已知比例 g_i·w（針孔投影算 t = 1 處垂直軸位移，與量到的差 < 1 px），**留一法**擬合 w——三片一起最小平方會把單片缺陷吃掉一半（400 cm 只剩 124 cm、w 變負）；殘差才互比。半徑：除掉平面比例、減葉尖上風側偏移**先驗 6 m**（擬合在 yaw = 0 奇異、對 yaw 誤差極敏感，W 在 −7 到 +18 m 亂跳），|yaw| > 15° 不補。合成掃描（估計姿態）：原始標記 5/8 → 補償後 5/8 不再標、殘差 ≤ 40 cm、預彎擬合 2.8–3.6 m；注入 400 cm 缺陷留得住且指對片；短 3% 葉片半徑仍抓到。**三個發現順帶**：近六點鐘 35° 內的葉片與塔架合併會產生 30 px 假彎曲（平面葉片也有，不是透視），補償算不掉、只點名 `blades_near_tower`；真實照片那 8 張沒有輪轂高與焦距，補償**只在合成上驗過**；yaw 的 overhang 先驗是最弱一環（資產加 `nacelleOverhangM` 要 DB v6，下一步）。三條不可退化：沒有姿態就不補、原始值一律留在輸出、拍攝閘門仍看原始半徑離散。夾具 `blade_offaxis_scene.png` + `make_offaxis_fixture.py`
- **葉片 Mode A 三件桌面能做的事 A4／A5／A6**（2026-09-16）：①**幾何層 cm/px**——`geometry.py::compare_blades` 早就會拿 `rotor_radius_m` 由三片葉長中位數反推尺度，Dart 移植時 `cmPerPx`／`rotorRadiusM` 漏掉，`blade_report_builder.dart` 一直在渲染沒有產生端的 `tip_deflection_cm`。補齊：`resolveScale` 單一規則（直接給的優先；否則型錄半徑 ÷ 參考葉長；不是正數就沒有尺度）、`BladeGeometryAnalyzer` typedef 多 `{double? rotorRadiusM}`（測試的假分析器要改簽名）、`analyzeSession(rotorRadiusM:)` 由畫面傳 `_asset?.rotorRadiusM`、發現多 `cm_per_px`／`tip_deflection_cm`／`<metric>_deviation_cm`、報告多印「葉片長度差」與「尺度」。**只換單位不改判定**，沒填型錄直徑就一個 cm 都沒有。夾具帶轉子半徑：正視反推 37.51 對真值 37.5、側視 15.23 對 15.0（垂掛葉片投影長度含預彎），Dart 與 Python 同一個數。②**偏軸透視夾具**（`synth.render_perspective` + `CameraSpec`，`scripts/offaxis_sensitivity.py` → `OFFAXIS_SENSITIVITY.md`）：把「相機在軸線上、葉片是平面」兩個假設拿掉——針孔投影、yaw、仰角、預彎 t²、轉子傾角、錐角線性。四個結論：**平面葉片再怎麼偏軸葉尖偏移都量不到**（直線的投影仍是直線，透視全落在半徑上）；**真實照片的 226 cm 重現了**——預彎 3 m、地面 300／480 m、yaw 0–30°，放行的 8 個情境量到 125–299 cm 假葉尖偏移（z 14–30，標記 5/8），來源是預彎被投影成 in-plane 彎曲；閘門只擋仰角 ≥ 25°（水平 180 m 全擋、300 m 以外全放行）；SPEC §13-11 的選項 (b) 校準雜訊底**否決**（要放大十倍等於關掉）、選項 (a) 兩個指標不夠，可行的是站位規範（水平 ≥ 4× 輪轂高、仰角 ≤ 14°）+ 報告措辭 + 相機姿態估計。**App 判定未改，待決策。** D 組（轉子方位角）只有兩個放行、分不出「跟位置」還是「跟葉片」，多幀抵消要用影片驗、本批沒做。錐角測試留了 3 px 的餘裕：透視會把線性偏移微彎（實測 2.4 px），預彎是它的好幾倍。③**葉片線接 `AiBackend`**——`blade_inspection_screen` 走與定檢線同一個 `AiRouter`。三條不可退化：端側判讀冠「【離線初判】」+ `metricJson['ai_source']`；**來源留在 `geminiOfflinePending`**（初判不是終判，補跑佇列連線後拿雲端覆核）；覆核的下限是**演算法**的等級（另存 `algorithm_severity`，`algorithmFloorOf` 在補跑前還原、prompt 帶給雲端的也是演算法數值）——否則一個 2B 模型抬上去的等級會變成退不回去的地板。`algorithmFloorOf` **刻意不轉傳 `bboxJson`**：那欄目前沒有產生端，轉傳會讓死角查核把它算成有人寫。三軌：Flutter **588**（+13）／後端 197／葉片原型 **234**（+6）
- **葉片 Mode B 三件桌面能做的事 A1／A2／A3**（2026-09-16）：①**IEA Task 46 分級表對原文核對**——原本三級共用 `min_cm_per_px 0.46` 沒有依據、Level 0 錨點寫錯。改成 **LEP／No-LEP 兩軌**（原文 §4.3.1 就是兩軌），每級 `threshold_cm2` 抄自原文、`min_cm_per_px = √面積/15 px` 由宣告的規則算出（Level 1 0.067、Level 2 LEP 0.211、Level 3 LEP 6.667）；Level 4/5 需 1 cm² 解析度，「Level 3 以上任何組態都可以」不成立。守門測試：兩軌只在原文有差的地方不同、門檻是原文不是猜的、`min_cm_per_px` 跟得上規則。②**線性探針落地**——`closeup_features_cnn.py` 是**唯一** import torch 的檔案（有測試守），凍結 ResNet18 512 維特徵抽好進版控（`closeup_features_resnet18_wtb.npz`，權重雜湊寫進 meta），`closeup_probe.py` 不需要 torch 也不需要語料：平均逐類 recall **0.632** 對 B2 0.308、1-NN 0.344，同一個分類器只換特徵就翻倍，§3.6 該讀成「手工特徵漏掉一半」不是「語料沒訊號」；域外 226 張仍崩。③**§1.2 取像閘門程式化**（`blade_proto/intake.py` + `closeup_intake_gate.py`，報告 `CLOSEUP_INTAKE_GATE.md`）：規格那句「簡單的前景占比」**實測不成立**——局部天空模型把填滿畫面的葉片當背景，P 的前景占比中位數 0.018 比 W 的 0.047 還低。改成兩層：Mode A **正視**放行 = 整機照 = 硬拒收；凍結特徵 + 同一個邏輯迴歸判 P／W／T 給拒收理由，P 對非 P 平衡準確率 **0.910**（P 0.992／W 0.946／**T 0.195**）。三個不可退化：硬規則只認 `view == "front"`（Mode A 放行的 10 張裡 **8 張是近身照、全走側視規則**——葉片被裂縫切成上下兩段 + 假塔架，記進 `BLADE_INSPECTION_SPEC.md` §13-13 待決策，Mode A 端 `quality.py`／`blade_capture_gate.dart` **未改**、75 張真實照片 0 改變）；探針是**建議性**判定（學的是取景碼、量不到 1/3），評估域仍用人工標記的 839 張不換成閘門輸出；T 的 recall **不設地板**——30 張判成 P 的 T 逐張看過，一半以上依 §1.2 字面該是 P（近距離俯拍葉根看起來像一條），是 `closeup_intake_wtb.json` 單一標註者的標記問題，**不改標記**、`false_accept` 清單當複核佇列
- **定檢主線三個接反的地方**（2026-09-16）：三個缺口疊在同一個出口——使用者拿到的回填定檢表與申報 PDF。全部是已出貨、桌面就驗得完的。
  ①**核心流程的 Gemini 是死的**：`form_inspection_screen.dart` 呼叫無參數 `init()`，而那只讀得到被 gitignore 的 `.env`（`pubspec.yaml` 把它列為 asset，打包進 APK 的是空檔）→ throw → catch → `_geminiService = null` → AI 靜默關閉退回手動模式。**設定頁的金鑰欄位對隱藏的舊流程有效、對核心功能無效。** 修法：金鑰解析抽成頂層純函式 `resolveGeminiConfig()`、缺金鑰丟具名 `MissingGeminiKeyException`（葉片線的 `catch` 要靠型別分辨「沒金鑰」與「真的離線」）、`SettingsProvider.applyToGeminiService()` 成為使用者金鑰**唯一的出口**（載入／換金鑰／換模型三處都推），核心流程改成**每次用之前重新解析**（使用者可能開頁之後才去填金鑰）。`init()` 加上「已初始化且沒帶新設定就沿用現狀」——`GeminiService` 是 singleton，沒有這一關，一個無參數呼叫會把已經可用的服務丟掉。順手修掉 `SettingsProvider` 的 race（建構子與 `init()` 各發一次沒人 await 的 `_loadSettings()`，晚完成的那個會把使用者剛存的金鑰蓋回 null）與死碼 `getEffectiveApiKey`（零呼叫端）
  ②**讀數跨量別假陽性**：`_findBestReadingMatch` 的關鍵字比對寫成交叉乘積——只要**欄位名**命中某組關鍵字就回傳**當下那一筆**讀數，於是「軸承溫度」會被填進「A 相電流 12.4 A」，而且下游拿它去判成「≤70 °C 合格／ISO 10816」。修法：抽成頂層純函式 `findBestReadingMatch`，用 `StandardsEngine.convertValue` 回傳的 `ok` 當**量綱閘門**（不寫第二份硬編表），關鍵字改成**兩邊要命中同一組**。「只有一筆讀數」那條退路分兩種：**有標準**時要求它自己帶對得上的單位（那筆值會被送去判定，沒單位就可能出現「3.0 ≤ 70 °C 合格」），**沒有標準**時放行（不會被判定，丟掉它沒有好處）。判定路徑的 `_extractNumericReading` 用**同一份標準表**取期望單位，不會出現「用溫度標準判一個電流值」
  ③**`/map-fields` 契約斷裂**：App 核心流程送 `{field_label, value, ai_result}`，而 `InspectionResult` 一個都沒宣告——pydantic 預設 `extra='ignore'`，**整包檢測資料被靜默丟掉**（實測 `model_dump()` 全是 None），AI 憑欄位名臆造值，端點還回報 `success: true`。修法：宣告 App 真的送的三個欄位、`ai_map_fields` 兩種形狀都吃得下（讀值藏在 `ai_result['readings']` 裡）、**全空的輸入不准送進 AI**（送了就是請它編，改回 `success: false` 說明形狀不符）、`extra='forbid'` 讓下一次契約漂開當場紅
  三軌：Flutter **575**（+27）／後端 **197**（+6）／葉片原型 207（A1–A3 後 **228**），死角查核通過

- **Tier 1b 端側 AI 的桌面半邊**（2026-09-16）：`LAUNCH_PLAN.md` §5.3 四層裡最後一層的骨架——`AiBackend` 抽象（雲端／端側同形狀）、`chooseAiTier` 純函式選層、`LocalModelManager`（三個縫）、`AiRouter`、`DeviceInfo.kt` 記憶體門檻、設定頁「離線 AI」卡片（匯入 `.litertlm`／從網址下載／Wi-Fi 限制／授權連結）、`FlutterGemmaRunner` 綁定 `flutter_gemma` 1.8.3 + `flutter_gemma_litertlm`。四條不可退化：①連得上且有金鑰一律雲端，端側就緒也不搶；②端側**不做讀值**（768 px 的圖讀不準數字，`readings` 永遠空、模型硬塞也不收）；③`aiResult['source']='local_llm'` + 狀況描述掛「【離線初判】」+ 總結開頭一行——報告與 PDF 讀這兩個欄位就印得出來；④查不到記憶體／沒有執行器／初始化失敗 → 一律退回 OCR，不假裝。連帶：SDK 下限 3.5/3.27 → **3.12/3.44**（`flutter_gemma` 硬要求；壓低下限的理由已不成立）、`share_plus` 7 → 10（`mime` 衝突）、`build.gradle` 限 **arm64-v8a**（`.litertlm` FFI 只出這個 ABI）。E2B int4 模型 **3.66 GB**、HF gated，不綁進 APK。**實機沒跑過**：一致率、耗時、JSON 遵循率三個數字等手機。刻意沒做：雲端覆核佇列、葉片線接端側、Gemini Nano

- **葉片模組三條外部語料驗證**（2026-09-19，全部只在桌面、沒有實機）：①**Commons 真實整機照的姿態估計與補償**（`fetch_commons_turbines.py` → `real_pose_validation.py` → `REAL_POSE_VALIDATION.md`）——第一次有帶 EXIF 焦距 + 已知機型的真實照片。86 張裡閘門放行 5（正視 3、側視 2），姿態可用 3/3；原始三片互比標記葉尖偏移 1 張 → 補償後 1（消掉 0、留下 1、新增 0），半徑 1 → 1；預彎擬合落在 0–8 m 的 1/3，仰角中位 4.81°；輪轂高度 ±20% 翻掉補償結論 0/3 張（來源 model 53、model-subcat 32、view 1）。**正視放行仍只有個位數，補償在真實照片上的成績還撐不起結論**。Commons 沒有取景類分類頁，第二批靠機型分類頁的子分類（檔案繼承機型）與地區分類頁的 `search-view`（機型由檔案分類／描述推斷）。 兩件工程事實：Wikimedia 對非常用縮圖寬度與原圖都會 429（要用 `Common_thumbnail_sizes` 那張表的寬度、步調 ≥ 10 s、UA 帶聯絡方式）；Commons 機型分類頁的照片大半不在設計範圍內（風場遠景、空拍、機艙特寫、廂型車、吊車），閘門放行率與 75 張 Flickr 語料一樣約一成。②**Mode B 跨語料（B3）**（`closeup_cross_corpus.py` → `CROSS_CORPUS_VALIDATION.md`）——分類器不重訓：**取像探針在乾淨負樣本上放錯 52%**（廂型車 59/62 判成近身葉片照，它學到的 P 其實是「不是整機遠景」，規格用語改成「不得單獨拒收或放行」）；Mode A 正視硬規則誤觸 3/7,544 且每張看過（背景有整機、葉片＋影子拆成三臂——「畫面裡有整機」≠「這是整機照」）；**缺陷探針跨語料 lift ≈ 1**（只有雷擊 7.7），同一個探針在 wtb 上是 0.632——§8.3 的「分布外崩掉」量到了。WTBs2025（CC0）的可用性寫進 `closeup_taxonomy.json`：640×640 重採樣、增強副本（`oil leakage` 520 張只有 29 個原始編號）、無 EXIF、無健康照。③**HF 整機照當 Mode A 閘門壓力測試**——無人機在輪轂高度拍的 104 張只放行 1 張，機制是**六點鐘那片落在地平線以下、背景是農田**，局部天空模型分不出來（SPEC §13-14）；Hub／Mast／Nacelle／Van 307 張放行 0；Blade 近身照 37/1,444 走側視規則放行（§13-13 的外部出現率）。三個不可退化：外部語料的影像與特徵**不進版控**（HF 授權未標）、硬拒收每一張都要有人工備註（`HARD_REJECT_REVIEW`，結果檔多一張沒備註就紅）、報告全部由結果檔渲染且有同步測試。**Flutter 端零改動**（三軌只跑 pytest + 死角查核）

## 既有 error（已修復）
- ~~`measurement.dart`: `sqrt` 未 import `dart:math`~~ → 已修復
- ~~`widget_test.dart`: `MyApp` 已不存在~~ → 已更新為 `InduSpectApp`
