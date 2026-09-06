# InduSpect 產品化評估與上線行動計畫

> 評估日期：2026-08-31
> 評估範圍：全 repo（Flutter App、FastAPI 後端、文件、CI、GitHub Issues）
> 導向：**以「可上線作為實用產品」為目標**，提出實用方案、應用實例與技術特性
> 後端測試已於本次評估實際執行驗證：`150 passed`（3.5 秒，fake API key）

---

## 1. 執行摘要（TL;DR）

**專案已具備一個真實可賣的核心賣點**：「拍照 → AI 讀值 → 台灣法規自動判定（含單位換算防呆）→ 回填客戶原本的 Excel/Word 定檢表」。這條 pipeline 在市面主流巡檢 SaaS（SafetyCulture、MaintainX 等）中沒有等價物，是明確的差異化。

**但目前距離「可上線」還隔著一層工程債**，其中三項是硬性擋路石（P0）：

1. **從未在實機上跑過完整流程**（Issue #43 / G1）——最新的法規判定串接只做過靜態審查。
2. **Android release 簽署仍用 debug keystore**（`build.gradle` release block 直接引用 `signingConfigs.debug`）——這個 APK 無法上架 Google Play。
3. **後端 25 個端點全部無認證**且 Cloud Run 部署參數為 `--allow-unauthenticated`、CORS `allow_origins=["*"]`——公開部署等於把 Gemini quota 與資料開放給全網。

**關於「手機載入小模型離線使用」**（本次提問核心）：**可行，但要分層做，而且第一步不是 LLM**。
CVPR 2026 的 MeasureBench 基準顯示指針式儀表讀值對「所有」VLM 仍是弱項，小模型更差；反而本專案的法規判定引擎（`judgment_service.py` 252 行 + `inspection_standards.py` 1089 行）是**零 AI 的純規則邏輯**，移植成 Dart 內嵌 App 即可讓「合格/不合格判定」完全離線、零成本、零延遲、全機型可用——直接消滅現有的「待判定」狀態。端側小模型（Gemma 3n via `flutter_gemma`、ML Kit）則定位在「離線初判 + OCR + 拍照品質把關」，聯網後由雲端 Gemini 覆核。詳見 §5。

**建議上線路徑**：先以「免費工具 + 自帶 API Key」型態上架 Play Store 封測與試點（4-6 週可達成），同步把離線判定引擎做進去；驗證留存與付費意願後，再演進為管理式訂閱（後端代 key + 配額）。資安敏感廠區以「地端部署」作為高單價 B2B 選項並行洽談。90 天行動計畫見 §7。

---

## 2. 現況盤點：做到哪裡了

### 2.1 功能面（完成度高）

| 能力 | 狀態 | 佐證 |
|------|------|------|
| 完整檢測 pipeline（上傳定檢表 → 一鍵自動檢測 → 引導拍照 → AI 批次分析 → 自動回填 → AI 報告 → 分享） | ✅ 程式完成，**待實機驗證** | `form_inspection_screen.dart`（2319 行）、PR #42 |
| 法規標準自動判定（56 條：電氣/消防/機械各 15、壓力 11） | ✅ 已串入 pipeline | `inspection_standards.py`、`judge-readings` 端點 |
| 單位換算防呆（500 kΩ vs ≥1.0 MΩ 誤判修正、℃/°C 正規化、affine 溫度換算） | ✅ 2026-05-25 修復 + 25 測試 | `test_unit_conversion_judgment.py` |
| 離線優先（拍照離線可完成、離線分享佇列、判定離線標記「待判定」+ 重試） | ✅ | `share_queue_service.dart`、`connectivity_service.dart` |
| 原格式回填（Excel/Word 結構分析 → 欄位映射 → 寫回原檔） | ✅ 後端完成 | `/api/auto-fill/*` 10 個端點、`autofill_core/` |
| GPS 定位 + 反向地理編碼 + 歷史紀錄搜尋 | ✅ | `location_service.dart`、SQLite v3 |
| 後端失敗時本地降級（本地模板解析、JSON 摘要匯出） | ✅ 但**降級是無聲的**（見 §3） | `local_template_creator.dart` |

### 2.2 工程面

- **測試**：後端 150 pytest 全綠（本次實測），Flutter 58 tests（文件寫 59，一項漂移）。**但** CI 只跑 5/15 個後端測試檔，其中 2 檔使用 `results.check()` 而非 `assert`——在 pytest 下永遠 PASS、無法擋退化（已列 Issue #45）。`flutter analyze` 為 `continue-on-error: true`，lint 不擋 PR。
- **Issue 管理健康**：僅 5 個 open issues，全部是目標型（G1-G4），#43 實機 E2E 為最高優先，#44 判定持久化需 schema 決策。
- **無密鑰外洩**：repo 掃描無 hardcoded API key、無 IP。但根目錄 `.gitignore` 沒列 `.env`（legacy React 原型的 `vite.config.ts` 會讀根目錄 `.env`），是個潛在事故點。
- **死程式碼**：`lib/screens/` 有約 5,200 行不可達的舊畫面（step1-4 舊流程、one_stop、template_selection 等）；根目錄 legacy React 原型（1,208 行 `index.tsx`）已休眠 3 個月，建議歸檔。
- ~~**相依老化**：後端 `google-generativeai==0.3.2` 為已棄用的舊 SDK；`embedding.py` 引用未列入 requirements 的新 `google-genai`（永遠落入 ImportError 分支）。~~ → 後端已於 2026-09-04 遷移完成（見 §3 P1「SDK 汰換」）。Flutter 端 `google_generative_ai ^0.4.6` 仍已停止維護，待處理。
- **模型 ID 風險**：全程式碼使用 `gemini-3-flash-preview` / `gemini-3.1-pro-preview` 等 **preview 版模型 ID**，且 Flutter 端寫死在 `constants.dart`（改模型要重新發版）。preview 模型會被 Google 下架，**這是一顆定時炸彈**——上線前必須改為 GA 版模型 ID 並支援遠端切換。

### 2.3 架構現況（實然，非文件應然）

```
Flutter App（Android / Web / Windows；無 iOS）
 ├─ 照片 AI 分析：App 直連 Gemini API（使用者自帶 key，.env / 設定頁輸入）
 ├─ 法規判定：POST 後端 /api/auto-fill/judge-readings（純規則，無 AI）
 ├─ 表單結構分析/回填：後端 /api/templates、/api/auto-fill（Gemini + openpyxl/python-docx）
 └─ 本地：SQLite v3、離線分享佇列、後端失敗時本地降級
FastAPI 後端（未部署；Dockerfile/cloudbuild.yaml 備妥但有 5 項阻塞，見 CLOUD_RUN_ASSESSMENT.md）
```

---

## 3. 產品化差距分析（Gap Analysis)

### P0 — 不解決就不能上線

| # | 差距 | 位置 | 建議解法 |
|---|------|------|---------|
| 1 | **實機端到端驗證從未執行**（含 2026-05-28 判定串接） | Issue #43 | 兩台實機（中階 + 旗艦 Android）跑完整流程 + 斷網情境；建立 e2e 檢查清單 |
| 2 | **Release 用 debug keystore 簽署** | `android/app/build.gradle:51-56` | 建 upload keystore + `key.properties`（不入版控），開 R8 minify |
| 3 | **後端全端點無認證 + CORS `*` + `--allow-unauthenticated`** | `main.py`、`cloudbuild.yaml` | 最小可行：全域 API-Key middleware（`X-API-Key`）+ CORS 白名單 + Secret Manager 存 key；`/docs` 生產環境關閉 |
| 4 | **`BACKEND_API_URL` 未寫入 `.env.example`**，release 會無聲退回 `http://localhost:8000` | `backend_api_service.dart:21` | 文件化 + 啟動時檢查並顯性提示；後端失敗的兩處無聲降級（模板解析、匯出）改為明確告知使用者 |
| 5 | **判定結果未持久化**（重開草稿即遺失合格/不合格） | Issue #44 | 併入 `ai_results` JSON 或新欄位 + v3→v4 migration（法規判定是稽核依據，必須留存） |
| 6 | **preview 模型 ID 寫死** | `constants.dart:6-7`、`config.py:24-26` | 改 GA 模型；Flutter 端改為可由設定/遠端 config 覆寫 |
| 7 | **隱私合規缺件**：照片 + GPS 上傳雲端，無隱私權政策、無 Play Data Safety 宣告 | — | 撰寫隱私政策頁（上架必填）；App 內首次使用告知；照片上傳 Gemini 的資料處理說明（付費 tier 不用於訓練） |
| 8 | **Release build 洩露資訊**：dio `LogInterceptor` 全量記錄 request/response、後端把原始 exception 文字回傳客戶端 | `backend_api_service.dart:33-37` | `kReleaseMode` 下停用 interceptor；後端統一錯誤格式，內部細節只進 log |

### P1 — 試點階段要補

- **後端部署**：依 `CLOUD_RUN_ASSESSMENT.md` 清單執行（Cloud SQL 或先不用 DB、Secret Manager、Artifact Registry）。注意 agent 發現的新問題：**報告狀態存在 in-process 記憶體**（`form_fill.py:51`），Cloud Run 多實例/scale-to-zero 下 `GET /reports/{id}/status` 會 404——需改存 DB 或改為同步回傳。
- **崩潰回報與監控**：接 Crashlytics 或 Sentry（Flutter）+ Cloud Run 結構化 log。沒有這個，試點回饋等於盲飛。
- **CI 收緊**：把 15 個測試檔全部納入 CI；#45 把 `results.check` 改 `assert`；移除 `flutter analyze` 的 `continue-on-error`；加 `flutter build apk` 煙霧測試。
- [x] **SDK 汰換（後端）** ✅ 2026-09-04：已遷移至 `google-genai`；新增 `app/services/gemini_client.py` 統一入口（client 延遲建立 + 依 key 快取），移除各 service 的 `genai.configure()` 全域狀態；連帶必須升版 `httpx` 0.26→0.28.1、`pydantic` 2.5.3→2.13.5、`fastapi` 0.109→0.116.1（相依鏈強制，見下）。**待辦**：Flutter 端評估 `firebase_ai`（Firebase AI Logic，可搭配 App Check 防濫用）或維持直連但集中封裝。
- **iOS**：目前無 `ios/` 目錄。建議**延後**——台灣工業現場以 Android 為主，iOS 等產品驗證後再 `flutter create --platforms=ios` 補做。
- **repo 清理**：legacy React 原型移入 `legacy/` 或 `_local_archive/`；刪除 `backend/` 根目錄的 dev-scratch 腳本（`reset_rag_db.py` 放在生產程式旁是個 footgun）；根目錄 `.gitignore` 補 `.env`。

### P2 — 成長階段

多使用者/團隊帳號與 RBAC、雲端同步、設備檔案與趨勢對比、PDF 申報格式報告、範本市場。

---

## 4. 目標市場與應用實例

**定位一句話**：「把師傅口袋裡的紙本定檢表，變成拍照就自動填好、自動依法規判定合格與否的數位流程——而且交付物還是客戶原本的表格格式。」

法規資料庫已含台灣現行法規引用（屋內線路裝置規則、CNS、電業法施行細則、消防法規、IEEE/NEMA/API），天然對準以下場景：

### 實例 1：消防設備檢修申報公司（消防設備師/士事務所）
- **法規驅動**：消防法第 9 條，場所每半年/一年須檢修申報，全台數十萬場所，旺季人力吃緊。
- **現行痛點**：現場抄錶（滅火器壓力、警報系統電壓）→ 回辦公室人工謄寫申報表 → 漏抄回場補拍。
- **InduSpect 流程**：帶著該場所的申報 Excel → 逐點引導拍照 → 壓力/電壓自動讀值 + 依標準自動判定（range 判定滅火器壓力上下限已在標準庫）→ 回填原表 → GPS + 時間戳作為「確實到場」佐證。
- **量化效益**：單場所文書時間預估從 40-60 分降至 10-15 分；GPS 紀錄同時回應「代簽不到場」的稽查風險。

### 實例 2：電機技師事務所——用電場所年度定檢
- **法規驅動**：高壓用電場所每年須由電氣技術人員或委託檢驗維護業定期檢驗。
- **對準功能**：絕緣電阻（gte 判定，kΩ/MΩ 換算防呆正是為此修的安全 bug）、接地電阻（lte）、漏電流（lte，mA/A 換算）。
- **賣點**：AI 讀指針錶 + 法規判定引用條文自動寫進紀錄，檢驗報告的「法規依據」欄不再靠老師傅記憶。

### 實例 3：工廠設備課月巡檢（自主檢查）
- **場景**：馬達溫度、振動、油位、管線壓力的例行巡檢，常見 Excel 自製表單。
- **對準功能**：「一鍵自動檢測」批次模式 + 智慧拍照提示（依欄位類型給拍攝指引）+ 歷史紀錄趨勢。
- **延伸價值**：異常照片 + GPS + 判定結果形成可稽核軌跡，對 ISO 45001 / 職安衛稽核直接有用。

### 實例 4：鍋爐壓力容器代檢機構
- **法規驅動**：職安法指定的定期檢查，壓力類標準庫已有 11 條。
- **特殊需求**：這類客戶常在**無網路或禁網的廠區**作業——正是 §5 離線架構與 §6 路徑 C（地端部署）的目標客群。

### 競品定位

| 競品 | 價格 | 缺什麼 |
|------|------|--------|
| SafetyCulture (iAuditor) | ~US$29/人/月 | 通用檢查表工具；無台灣法規判定、無原格式 Excel/Word 回填、AI 僅報告摘要 |
| MaintainX | ~US$16/人/月 | CMMS 導向；同上 |
| GoAudits / Lumiform | ~US$10/人/月 | 表單數位化為主，AI 讀值能力弱 |

**InduSpect 的三個別人沒有的點**：(1) 台灣法規標準自動判定與條文引用；(2) 交付物是客戶「原本的表格檔案」而非平台專屬報表（導入阻力極低——不用改客戶的表單習慣）；(3) 離線優先設計。建議定價錨點：NT$300-600/人/月（低於 SafetyCulture、對齊在地購買力），或按份計費（NT$30-50/份報告）適配申報型事務所的專案性質。

---

## 5. ★ 離線 AI 深度評估：手機載入小模型可行嗎？

### 5.1 結論先講

**可行，但「不要用小模型去做讀值」。** 分四層做，優先順序如下：

| 優先 | 方案 | 解決什麼 | 需要 AI 嗎 |
|:---:|------|---------|:---:|
| ① | **法規判定引擎 Dart 化** | 「待判定」狀態整個消失；判定離線、零成本、零延遲 | 否（純規則） |
| ② | **ML Kit OCR（離線）** | 數位式儀表、銘牌型號的離線讀值 | 傳統 CV |
| ③ | **Gemma 3n 端側 VLM（`flutter_gemma`）** | 離線「初判」：外觀異常描述、拍照品質把關、報告草稿 | 端側 LLM |
| ④ | **雲端 Gemini（現況）** | 指針錶精確讀值、複雜異常、正式報告 | 雲端 LLM |

### 5.2 為什麼讀值不能靠端側小模型——證據

- CVPR 2026 的 **MeasureBench** 基準（[論文](https://openaccess.thecvf.com/content/CVPR2026/papers/Lin_Do_Vision-Language_Models_Measure_Up_Benchmarking_Visual_Measurement_Reading_with_CVPR_2026_paper.pdf)）系統性評測 VLM 讀儀表：**數位顯示類準確率尚可，多指針/指針錶盤對所有模型（含雲端大模型）都是難題**；小模型差距更大。
- 目前做到工業可用精度的做法是**專用微調**：如以 Qwen2.5-VL-7B 微調的指針錶專用模型達 MPE 1.93-3.4%（[SSRN 論文](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6749578)）——但 7B 模型量化後仍需 5-6GB 記憶體，超出主流工地用機負荷，且僅覆蓋單一儀表類型。
- **啟示**：把「指針錶讀值」留在雲端（或未來自己微調專用小模型、蒸餾到端側——這也是很好的論文題目）；端側 AI 做它擅長的事。

### 5.3 四層架構具體設計

```
拍照
 ├─ Tier 1a【離線・全機型】ML Kit Text Recognition v2
 │    數位錶読值/銘牌 OCR → 有數值 → 直接進判定
 ├─ Tier 1b【離線・8GB RAM 機】Gemma 3n E2B/E4B (flutter_gemma)
 │    外觀異常初判（鏽蝕/滲漏/破損）、拍照品質檢查（模糊/眩光→即時請使用者重拍）
 │    → 結果標記「離線初判」
 ├─ Tier 0【離線・全機型】判定引擎 (Dart port of judgment_service)
 │    56 條標準 + normalize_unit/convert_value → 合格/不合格/警告 + 法規依據
 └─ Tier 2【聯網】Gemini Flash 精判（指針錶、複雜場景）+ Gemini Pro 報告
      → 聯網後自動覆核離線初判（沿用現有 pendingShare/待判定的佇列模式）
```

**Tier 0 是本評估最重要的單一建議**：`judgment_service.py`（252 行）+ `inspection_standards.py`（1089 行，純資料 + 純函式）沒有任何 AI 呼叫、沒有 DB 相依，移植成 Dart package（標準資料轉 JSON asset 或 Dart const）預估 1-2 週工作量，測試可直接對照後端 25 條單位換算測試逐條移植。移植後：
- 現有「離線 → 待判定 → 重試」的整段補償邏輯退化為備援；
- 後端在「判定」這件事上不再是單點故障；
- 每次判定省一次 round-trip（現場網路差時體感明顯）。
- 維護策略:標準資料以單一 JSON 為 source of truth，後端與 App 共用（版本欄位 + App 啟動時可拉更新），避免兩份資料漂移。

### 5.4 端側模型選項比較（2026-08 現況）

| 方案 | 平台 | 模型下載 | 記憶體 | 能力 | 適用 |
|------|------|---------|--------|------|------|
| [`flutter_gemma`](https://pub.dev/packages/flutter_gemma) + Gemma 3n E2B/E4B | Android/iOS/桌面 | ~3-4GB（一次性） | 2-3GB RAM | 多模態（圖+文+音）、function calling、端側 RAG | 中高階機（8GB RAM）離線初判 |
| [ML Kit GenAI APIs（Gemini Nano）](https://developer.android.com/ai/gemini-nano) | 僅 Android 旗艦（Pixel 8+、S24+，Prompt API 以 Pixel 10 最佳） | 0（系統管理） | 系統管理 | 圖片描述、摘要、Prompt API | 旗艦機零下載的加值體驗 |
| ML Kit Text Recognition v2 | 全 Android/iOS | ~數十 MB | 極低 | OCR（含中文） | **所有機型**的數位錶/銘牌離線讀值 |
| 自行微調專用讀錶模型（長期） | — | — | — | 指針錶專精 | 論文產出 + 差異化壁壘 |

**落地建議**：Tier 0 + Tier 1a 是「必做」（全機型受益、工程風險低）；Tier 1b 以 PoC 分支驗證（E4B 在 8GB 機的延遲/發熱/電池實測），以「進階功能」形式提供下載開關，不綁進主 APK（避免安裝包暴增）。

### 5.5 「或是?」——第三種部署形態：地端邊緣伺服器

台灣許多工廠/機房**禁止照片上雲**（資安規範），這反而是商機：

- 現有 FastAPI 後端本來就能跑在一台 mini-PC/NB 上（`docker-compose.yml` 已備）；
- 把 Gemini 呼叫抽象成 provider 介面，接 **Ollama/vLLM + 開源 VLM（如 Qwen3-VL、Gemma 3 27B）**，在廠區內網提供與雲端相同的 API 合約；
- App 端只是把 `BACKEND_API_URL` 指向內網位址——**現有架構幾乎不用改**；
- 商業上這是高單價 B2B 年約（設備 + 部署 + 法規庫訂閱），與 App 訂閱互不衝突。

這個形態同時回答了「離線」的另一種解讀：不是每支手機都要載模型，而是**讓 AI 跟著巡檢車/機房走**。

---

## 5.6 平行軌：風力機葉片地面目視檢測（獨立功能）

2026-09-06 新增的獨立模組，**與本計畫的定檢表主線互不相依**，可獨立排程、獨立找客戶。
它不共用定檢表的資料模型（資產驅動 vs 表單驅動），但共用 GPS、離線佇列、品質閘門、PDF 產生器。

**為什麼值得排**：這是手機做得比無人機服務商更好的一件事——**頻率**。
無人機定檢一年一次，手機可以每次到場都拍，價值在跨次比對出「新增的東西」。

**能做到哪（已量化，不是估計）**：`blade_prototype/SENSITIVITY.md` 用合成影像量出上限——
正視整轉子在 12 MP 橫幅需 ≥ 4.8 cm/px（1x 約 130 m）才塞得進畫面，此時 50 cm 葉尖偏移可分辨、
25 cm 不行；側視垂掛葉片用直幅 2.5–3.5 cm/px；5x 長焦在 50 m 可分辨 1 cm 深的前緣凹坑。
**髮絲裂縫、早期蝕點在任何手機倍率下都看不到**，所以定位是 Level 1 篩檢，補位而非取代無人機定檢。

**熱像儀不列入前提**（2026-09-06 決策）：機艙元件溫度已由 SCADA 監測，另購外接熱像模組
＋自寫原生 plugin（Flutter 無現成套件、iOS 幾乎只剩 FLIR 官方 SDK）＋每台裝置發射率校正，
門檻不值得。若客戶已有 FLIR，日後以「選配輸入」處理。真要看機艙溫度，
拍風機控制器 HMI 畫面就是現有 OCR + 判定引擎的既有場景，零硬體。

**下一步**：一次外業（停機 + 怠速各一台風機）就能回答三層各能做到什麼，再決定 Phase 1 押哪一層。
規格與分期見 `BLADE_INSPECTION_SPEC.md`。

---

## 6. 上線路徑三選一（建議 A → B，C 並行洽談）

| | 路徑 A：免費工具 + 自帶 Key | 路徑 B：管理式訂閱 SaaS | 路徑 C：B2B 地端部署 |
|---|---|---|---|
| 形態 | 現況延伸；使用者用自己的 Gemini API key（免費 tier 即可跑） | 後端代理 Gemini（伺服器 key）+ 帳號 + 配額 + 訂閱 | 廠區內網伺服器 + 開源 VLM |
| 上市時間 | **4-6 週**（P0 清單 + 上架） | +8-12 週（auth、計費、代理、濫用防護） | 按案，隨時可談 |
| 收入 | 0（換取場域驗證與口碑） | NT$300-600/人/月 或按份計費 | 年約（六位數起） |
| 主要風險 | key 申請是 onboarding 最大流失點 → 做「30 秒引導申請」精緻化（settings 頁已有雛形） | Gemini 成本需控（好消息：Flash 分析一場 30 張照片的巡檢成本約 NT$1-3，毛利結構健康） | 開源 VLM 讀值精度需驗證 |
| 適用 | 學術發表、試點、早期採用者 | 事務所/檢測公司規模化 | 資安敏感工廠、政府場域 |

**建議**：路徑 A 立即執行（它同時是路徑 B 的封測期），並在 A 期間即埋好量測（哪些欄位被人工修改 = AI 準確率的真實數據，`feature_enhancements.md` 早已規劃此回饋機制，是未來微調的資料資產）。

---

## 7. 90 天行動計畫

### 第 1-4 週：實機驗證 + 上架準備（對應 G1）
- [ ] 實機 E2E（#43）：上傳 Excel → 一鍵自動檢測 → 判定回填 → 匯出 → 分享；斷網全流程（**需實體裝置**；斷網判定已改走本地引擎）
- [x] `flutter analyze` + `flutter test` 在真 SDK 環境跑通並修 lint ✅ 2026-08-31（88 tests 綠、0 warning、widget_test 修復）
- [x] P0-2 簽署金鑰（key.properties 模式 + R8）/ P0-4 `BACKEND_API_URL` 顯性化 + 降級提示 / P0-6 GA 模型 ID + 可設定化 / P0-8 移除 release 日誌洩漏 ✅ 2026-08-31
- [x] #44 判定持久化（v3→v4 migration + 測試）✅ 2026-08-31（欄位設計：獨立 `standard_judgments` JSON 欄，請劉老師 review）
- [~] 隱私權政策草稿完成（`docs/PRIVACY_POLICY.md`）；**待辦**：法律審閱 + 發布公開 URL + Play Data Safety 表 + 內部測試軌上架（需 Play 帳號）
- [ ] 接 Crashlytics/Sentry（需 Firebase/Sentry 帳號設定）
- **退出條件**：兩台實機全綠、internal testing 軌可安裝、崩潰回報看得到資料

### 第 5-8 週：離線能力 v1 + 後端最小安全部署（對應 G3/G4）
- [x] **判定引擎 Dart 化（Tier 0）** ✅ 2026-08-31：標準資料 JSON 單一來源（含後端同步守門測試）、24 條 Dart 測試移植、離線判定取代「待判定」（僅本地引擎也失敗時退回）
- [x] ML Kit OCR 數位錶離線讀值（Tier 1a）✅ 2026-08-31：拍照 → 離線 OCR → 解析（誤讀修正/雜訊過濾）→ Tier 0 判定 → 持久化；OCR 品質待實機驗證
- [~] 後端：API-Key middleware + CORS 白名單 + 422/500 淨化 ✅；報告狀態記憶體問題 ✅（class-level + `/generate` 同步化 + 404）；cloudbuild.yaml 已改 Artifact Registry + Secret Manager；**待辦**：實際部署 Cloud Run（需 GCP 帳號操作）
- [x] #47 judge-readings 輸入驗證（含 NaN→500 修復）、#45 測試假陽性修正（11 檔）、CI 納入全部測試檔 + analyze 轉硬性 ✅ 2026-08-31
- [x] **PDF 報告輸出（申報場景的交付格式）** ✅ 2026-09-02：裝置端純 Dart 產生（`pdf` 套件 + 內嵌 Noto Sans TC 子集），離線可用；含基本資料/判定統計/逐項法規依據與單位換算/異常清單/AI 總結/照片附件；完成頁與歷史紀錄皆可匯出（18 測試）
- **退出條件**：斷網可完成「拍照→判定→匯出（JSON/PDF）」全流程（程式面已達成，待實機驗證）；後端公網部署且非匿名可用

### 第 9-12 週：試點計畫（todo.md 第二階段的落地）
- [ ] 2-3 個場域、5-10 名巡檢員（建議組合：一家消防檢修 + 一個工廠設備課，覆蓋§4 實例 1 與 3）
- [ ] 量測指標：單場巡檢總時間（目標：紙本流程的 50%）、AI 讀值免修改率（目標 ≥70%）、判定引用正確率（抽查）、每週活躍留存
- [ ] Gemma 3n E4B PoC 平行進行（Tier 1b）：延遲/發熱/準確度實測報告 → 決定是否進 roadmap
- [ ] 依回饋決策：路徑 B（訂閱）開工 vs. 先擴大試點
- **退出條件**：至少 1 個場域願意付費或簽 LOI；發表用數據齊備（時間節省 %、準確率）

> 產學雙軌提醒：`STATUS.yaml` 的 outputs 含 paper——「雲端-端側混合 AI + 法規知識庫自動判定的工業巡檢系統 + 試點實測數據」本身即是完整的系統論文題目，試點指標設計請同時滿足論文實驗需求。

---

## 8. 技術特性彙整（行銷/論文用賣點清單)

1. **法規知識庫驅動的自動判定**：56 條台灣法規/國際標準（含條文引用），gte/lte/range/eq/in_set 五種判定型態，判定結果附法規依據＝可稽核。
2. **單位感知的安全防呆**：讀值先換算到法規標準單位再比較（kΩ→MΩ、mA→A、affine 溫度），杜絕數量級誤判——這是安全等級的功能，競品沒有。
3. **原格式回填**：交付客戶「原本的 Excel/Word」，導入零學習成本。
4. **離線優先**：拍照、暫存、分享佇列全離線可用；判定、OCR 讀值與 PDF 申報報告亦全程離線（2026-09-02 起）。
5. **一鍵自動檢測 pipeline**：引導拍照（依欄位類型給專業拍攝提示）→ 併發批次 AI 分析（concurrency cap = 3）→ 自動回填 → 自動報告。
6. **人在迴路**：所有 AI 結果可審可改，修改紀錄即未來微調資料資產。
7. **GPS + 時間戳稽核軌跡**：回應「確實到場」的合規需求。
8. **混合 AI 架構（規劃）**：規則引擎（0 token）→ 端側小模型（隱私/離線）→ 雲端大模型（精度），成本與能力分層。

---

## 9. 風險與對策

| 風險 | 等級 | 對策 |
|------|:---:|------|
| preview 模型被 Google 下架，App 全面故障 | 高 | P0-6：GA 模型 + 遠端可切換；模型名進設定而非 const |
| 指針錶讀值準確率不足，現場信任崩壞 | 高 | 試點量測免修改率；低信心讀值 UI 上強制人工確認；長期微調專用模型 |
| BYO key onboarding 流失 | 中 | 引導精緻化；路徑 B 移除此摩擦 |
| 後端公開後被濫用（燒 quota） | 高 | P0-3 認證 + 限流；Secret Manager |
| 法規資料維護漂移（後端/App 兩份） | 中 | 單一 JSON source of truth + 版本號 + App 啟動拉更新 |
| 單人維護的 bus factor | 中 | 持續 weekly routine agent + CI 收緊（已在做，方向正確） |
| 試點資料隱私疑慮（照片上雲） | 中 | 隱私政策明示；付費 Gemini tier 不訓練聲明；資安敏感客戶導向路徑 C |

---

## 10. 附錄：本次評估的佐證

- 後端測試實測：`GEMINI_API_KEY=ci-fake-key python -m pytest tests/ --asyncio-mode=auto` → **150 passed, 3.52s**（2026-08-31，本評估環境）
- 程式碼級發現（全文位置）：debug 簽署 `flutter_app/android/app/build.gradle:51-56`；localhost fallback `lib/services/backend_api_service.dart:21`；CORS `backend/app/main.py:32-38`；in-memory 模板 `backend/app/services/form_fill.py:50`；preview 模型 `flutter_app/lib/utils/constants.dart:6-7`、`backend/app/config.py:24-26`
- 外部佐證：
  - [MeasureBench (CVPR 2026)](https://openaccess.thecvf.com/content/CVPR2026/papers/Lin_Do_Vision-Language_Models_Measure_Up_Benchmarking_Visual_Measurement_Reading_with_CVPR_2026_paper.pdf) — VLM 儀表讀值基準
  - [指針錶專用 VLM 微調 (SSRN)](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6749578) — Qwen2.5-VL-7B 微調達 MPE 1.93-3.4%
  - [Gemma 3n 開發者指南](https://developers.googleblog.com/en/introducing-gemma-3n-developer-guide/)、[flutter_gemma](https://pub.dev/packages/flutter_gemma)、[MediaPipe LLM Inference](https://ai.google.dev/edge/mediapipe/solutions/genai/llm_inference)
  - [ML Kit GenAI APIs / Gemini Nano](https://developer.android.com/ai/gemini-nano)（旗艦機支援清單）
  - 競品價格：[SafetyCulture 替代品比較 (Lumiform)](https://lumiformapp.com/comparisons/best-safetyculture-alternatives)、[Clappia 比較](https://www.clappia.com/blog/top-8-safetyculture-alternatives)
