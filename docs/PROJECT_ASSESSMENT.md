# InduSpect 專案評估：現況、價值、該砍什麼（2026-09-16）

> 這份文件回答三個問題：**做到哪裡了、值不值得推廣、哪些東西該改掉或拿掉。**
> 每個判斷都附數字或檔案位置；沒有證據的話就寫「不知道」。
> 上一份同性質的評估是 [`LAUNCH_PLAN.md`](../LAUNCH_PLAN.md)（2026-08-31，產品化角度）；
> 這一份的角度是**專案本身**——它現在是什麼、對誰有用。

---

## 0. 一句話

**工程面接近完成、驗證面幾乎為零、文件比程式誠實、程式裡約四分之一是沒有入口的死碼。**
它現在最有價值的地方不是 App，是 **方法學與文件**——這也是它最適合的推廣方向。

---

## 1. 現況與進度

### 1.1 規模

| 部分 | 行數 | 檔數 | 備註 |
|---|---|---|---|
| Flutter `lib/` | 33,793 | 104 | 其中 screens 13,786／services 14,504 |
| ├ 葉片線（`blade_*`／`wt_*`） | 10,908 | — | services 7,775 + screens 2,614 + models 519 |
| ├ **沒有入口的畫面與服務** | **≈ 7,900** | — | 詳 §5；約 23% |
| Flutter `test/` | 8,584 | 35 | 533 tests |
| Backend `app/` | 8,357 | — | 24 個端點，App 端只呼叫 12 個 |
| Backend `tests/` | 8,573 | 21 | 197 tests |
| `blade_prototype/`（Python） | 13,261 | — | 228 tests |
| 葉片文件（`blade_prototype/*.md`） | 2,411 | 8 | |
| 根目錄文件 | 2,698 | 8 | `ROADMAP.md` 有 80% 是沒有排程的功能願望 |
| git | 204 commits | 45 個工作日 | 2025-10-08 → 2026-09-16 |

### 1.2 兩條產品線各自到哪

| | 定檢表 pipeline（主線） | 葉片 Mode A（地面整機） | 葉片 Mode B（近身影像） |
|---|---|---|---|
| 程式 | 完整（上傳→引導拍照→AI→回填→報告→分享） | 完整（表面／幾何／聲音／動態四層 Dart 化） | **零行演算法** |
| 演算法驗證 | — | 75 張公開照片逐張回歸、14 段影片運動分割 | 評估協定、切分群組、基線兩條 |
| **實機驗證** | **0 次** | **0 次**（Kotlin 抽幀昨天才第一次編過） | — |
| **真實手機拍的資料** | — | **0 張** | **0 張**；健康照 0 張、`crack` 類 0 張 |
| 人工簽核 | — | — | **0 筆**（工具做好、先驅排好，沒有人坐下來看） |
| 法規／標準來源 | 56 條，**至少 4 筆引用錯**（見 §4） | IEA Level 門檻 3–5 留白 | 分類表把 IEA 兩條軌壓成一條 |

### 1.3 這兩天修掉的東西說明了什麼

2026-09-16 的 [PR #77](https://github.com/dofliu/InduSpect/pull/77) 修了三個**已出貨**的缺口：
設定頁的金鑰從來沒接到核心流程（打包出去的 APK 上 AI 是死的）、讀數會被填進不同量別的欄位並判成合格、
`/map-fields` 把 App 送的檢測資料整包丟掉還回報成功。

這是同一個失敗模式的**第三、四例**（前兩例 2026-09-08：`capture_points` 有人讀沒人寫、
`blade_report_export` 的 `pendingShare` 兩個呼叫端都沒決定）。共同點：**兩端各自寫得對，接縫沒有人測**。
死角查核只查「有沒有人叫」，抓不到「叫了但傳錯東西」。這比任何單一 bug 更值得記住——
它代表的是**沒有一次端到端的實機驗證**，所以這類問題只會在被人讀程式時才被發現。

---

## 2. 值得推廣嗎？分四個面向講

### 2.1 實用價值：有真實痛點，但現在不能推給使用者

痛點是真的。台灣的電機技師、消防設備師、鍋爐代檢機構每個月都要填**客戶自己格式**的定檢表，
讀值抄錄、法規對照、報告排版占掉大半時間。「上傳客戶的表 → 拍照 → 自動回填原格式 → 帶法規依據的判定」
這條路線沒有現成產品在做（[`LAUNCH_PLAN.md`](../LAUNCH_PLAN.md) §4 有競品定位）。
**Tier 0 離線判定引擎**（56 條標準在裝置端、含單位換算）是真正的差異化。

但現在不能推，三個理由都不是「功能不夠」：

1. **從未在實機上跑過一次完整流程**。三個「接了但傳錯」的 bug 存在了好幾個月，任何一次實機測試都會抓到。
2. **法規引用有錯**。查證時對 `law.moj.gov.tw` 核過：絕緣電阻的依據應是「用戶用電設備裝置規則」第 10 條，
   而 `inspection_standards.py` 至少四筆寫的是「屋內線路裝置規則 第 59 條」（該條講中性線負載，法規名稱
   2018 年已更名）。這些字會印在申報 PDF 上。**一份會被拿去申報的文件，引用錯法條比沒有引用更糟。**
3. **API 金鑰明文存在 `SharedPreferences`**，沒有 `flutter_secure_storage`；帶 GPS 的照片會進 Google 備份
   （`AndroidManifest` 沒設 `allowBackup`）。試點前要處理。

**要推給使用者的最短路徑**：一台 Android 手機跑完整流程（Issue #43）+ 逐條核對 56 條標準的法規來源
+ 金鑰改安全儲存。這三件都不需要新功能。

### 2.2 學術價值：演算法不新，方法學有東西

先講不能拿去投的：Mode A 的天空分割、三片剪影互比、逐片聲學互比，是**紮實的工程**不是研究貢獻；
Gemini prompt 更不是。把 App 本身寫成論文會被問「novelty 在哪」而答不出來。

能拿去投的在 **Mode B 的評估方法學**，而且是**在還沒有模型的時候就做出來的**：

| 發現 | 位置 | 為什麼有價值 |
|---|---|---|
| 公開語料自附的切分**洩漏 63.4%**（test 集有近重複在 train），配對實驗量到它值 **0.204 recall** | `CLOSEUP_SPLIT_GROUPS.md`、`CLOSEUP_EVAL_PROTOCOL.md` §2 | 這份語料（figshare Multiclass WTB，CC BY 4.0）有人在用；洩漏量化是可直接引用的結果 |
| 兩位標註者類別一致率 **94.0%**（κ 0.897），分歧集中在兩對類別 | `CLOSEUP_BASELINE_REPORT.md` | 任何模型在這份語料上的**可量測上限**——超過它的分數是在報雜訊 |
| 手工特徵（123 維）與 1-NN **打平**（0.308 vs 0.344），但凍結 ResNet18 線性探針 **0.632** | `CLOSEUP_EVAL_PROTOCOL.md` §3.6、盤點查證 | 推翻「語料沒訊號」的解讀；也是一個「基線要選對」的教學案例 |
| IEA Task 46 分級表原文有 **LEP／No-LEP 兩條軌**，被普遍壓成一條 | 盤點查證（原文 PDF §4.3.1 Table 4-1） | 可寫成 erratum 型技術短文；對做葉片侵蝕分級的人有直接用處 |
| 開放網路**湊不出語料**（200 張裡 0 張有缺陷、54% 不是風機葉片）；**cm/px 結構性量不到**（EXIF 0/200、3/1065） | `CLOSEUP_BASELINE_REPORT.md` | 負面結果，省別人的時間 |
| 標註／前處理痕跡出現在 **35%** 的影像上，比任何正常結構都多 | `CLOSEUP_HEALTHY_SET.md` §3 | 洩漏風險的量化；訓練前要處理 |

**一篇可以寫的**：〈公開風機葉片缺陷語料的評估陷阱：洩漏、上限、與正確的地板〉（dataset audit／
evaluation protocol 類短文或期刊技術短文）。全部數字已在 repo 裡、腳本可重現、不需要新模型。
**第二篇**：IEA Task 46 兩軌分級表的解讀與可偵測性分析（結合 §1.2 的 cm/px 物理推算）。

Mode A 那邊唯一算得上方法學貢獻的是 **75 張真實照片的逐張回歸基線**（`blade_test_report.py --baseline`）
——「演算法沒有無聲漂移」的可證明方式，適合當工程實務的例子而不是論文。

### 2.3 教學價值：這是最強的一面

這個 repo 記錄了一個「AI 系統軟體工程」課程想教但很難找到真實例子的東西：

| 可教的 | 在哪裡 |
|---|---|
| **規格驅動 + 不可退化的約定**：每個模組有 3–4 條「不可退化」寫進 CLAUDE.md，**每條有反向測試** | `CLAUDE.md` 已知問題追蹤、`tests/` |
| **死角查核當 CI 守門**：「這個欄位有沒有人寫、這個方法有沒有人叫」機械化，過期名單一樣紅 | `flutter_app/scripts/audit_dead_ends.py` |
| **跨語言移植的交叉驗證**：Python 原型 → Dart，用夾具對到小數第三位，夾具產生器**自我對帳** | `blade_prototype/scripts/make_*_fixture.py` |
| **失敗模式目錄**：四例「接了但傳錯東西」，每例有根因、修法、守門測試 | 本文 §1.3、`DEVELOPMENT.md` 變更紀錄 |
| **評估協定設計成會拒跑的程式**：切分宣告不符／類別 < 30 張／未普查 → 程式拒絕給數字 | `closeup_eval.py` |
| **人工標註的邊界**：模型的第一遍標記進得了排序、進不了決策，靠黑名單而不是靠記得 | `closeup_review_tool.py`、`closeup_candidate_firstpass.py` |
| **誠實文件**：每個數字有來源、每個「沒做」有理由、每個更正留在原處 | 全部 `*.md` |

適合的用法：研究所「AI 系統工程」或大學部專題的**範本 repo**——學生不是從零寫，而是接手一個
有完整規格、測試、文件與**已知缺口清單**的專案，練習「在既有約定下加東西不弄壞它」。
Mode B 的 B3（第一個模型）正好是一個規模適中、有評估協定守著、資料齊備（除了健康照）的專題題目。

### 2.4 推廣的前提：先讓外人看得懂

不管往哪個方向推，現在的 repo 對外人不友善：

- **約 23% 的 Dart 沒有入口**（§5）——外人會以為那些是功能。
- **`ROADMAP.md` 有 406 行（80%）是五階段十個功能的願望清單**，與 `CLAUDE.md` 的「核心功能只有兩個」直接矛盾。
- **兩條沒有共用流程的產品線在同一個 repo 同一個 App**，文件要一直解釋「這兩個不相干」。
- 8 份根目錄文件 + 8 份葉片文件 + `docs/`，同一件事常出現在三處。

§3 逐項討論該怎麼收。

---

## 3. 該改掉或拿掉的：全面討論

原則：**不是「用不到就刪」，而是「留著會誤導人或會壞」才刪。** 每一項附證據與風險。

### 3.A 直接移除——沒有入口的程式（約 7,900 行）

「隱藏功能」這個說法要先修正：**repo 裡沒有任何隱藏旗標**（grep `hidden`／`kDebugMode`／`showAdvanced`
在 dashboard、settings、main 全部零命中）。所謂隱藏就是**沒有任何畫面能到達**，也就是死碼。
死碼的成本不是磁碟，是：①每次改 `GeminiService`／`DatabaseService` 這類共用服務都要顧到它們會不會編不過；
②`InspectionProvider` 的 `_initGeminiService()` 是**唯一另一個** Gemini 初始化點，這次金鑰 bug 的混淆有一半來自它；
③外人以為那些是功能。

| 移除批次 | 內容 | 行數 | 證據 |
|---|---|---|---|
| **A1 舊四步流程** | `home_screen`、`step1_upload_checklist`、`step2_capture_photos`、`step3_review_results`、`step4_records_report`、`quick_analysis_screen`、`history_screen`、`inspection_records_screen` | 2,276 | `HomeScreen` 0 入口；step1–4 只被 home 引用；`QuickAnalysisScreen` 只被 home 引用 |
| **A2 範本系統** | `template_selection_screen`、`template_filling_screen`、`widgets/template/*`、`widgets/field_inputs/*`（9 檔）、`stepper_widget`、`models/template_inspection_record`、`inspection_template`？ | ≈ 2,300 | `TemplateSelectionScreen` 0 入口；`TemplateFillingScreen` 只被它引用；field_inputs 只被 `section_card` 引用 |
| **A3 舊自動回填／一站式** | `auto_fill_screen`、`one_stop_inspection_screen` | 1,445 | 0 入口；核心流程的回填走 `form_inspection_screen` 自己那一段 |
| **A4 雲端遺留** | `providers/inspection_provider`（600）、`services/cloud_run_api_service`（239）、`services/photo_sync_service`（303）、`models/photo_sync_task`、`pending_upload_task`、`auth_tokens`、`inspection_job` | ≈ 1,400 | `CloudRunApiService` 只被 `InspectionProvider` 用；`PhotoSyncService` 的呼叫端全在 A1／A2；`InspectionProvider` 的活呼叫端只剩 `dashboard_screen` 的 `initialize()` 與一個沒用到的參數 |
| **A5 零引用 model** | `models/measurement.dart` | 163 | 0 個 import |
| **A6 後端死端點** | `/api/reports/*`（5 條，已被純 Dart PDF 取代）、`/api/templates/defaults`／`recent`／`record-usage`、`/api/auto-fill/generate-photo-tasks`／`insert-photos`／`one-stop-process`／`precision-map-fields`／`batch-process`，連同只服務它們的 `photo_task_service`、`photo_processing_service`、`checkbox_service`（600）、`template_service`、`history_service`、`reports.py` | ≈ 2,500 | App 端全 `lib/` 引用到的路徑只有 12 條（`analyze-structure`、`execute`、`judge-readings`、`map-fields`、`preview`、`rag/*` 5 條、`templates/create-from-file`、`health`） |

**風險與做法**：一次一個批次，每批次先跑三軌 + 死角查核，再刪。A4 要先把 `dashboard_screen`
對 `InspectionProvider` 的那兩處依賴拆掉（一處是 `initialize()`，一處是傳進 card 但沒用）。
A6 刪之前 `AUTO_FILL_SYSTEM.md` 要同步——它描述的四條端點是活的，其餘不是。
**刪掉的東西都在 git 歷史裡**，`docs/archive/` 不需要再放一份程式碼。

### 3.B 架構問題——要做決定，不是直接砍

**B1 兩個 Gemini 入口。** App 端用 `google_generative_ai` 直連（使用者的金鑰、prompt 在 `gemini_service.dart`）；
後端用 `google-genai`（伺服器的金鑰、prompt 在 `form_analysis_service.py`）。兩套 prompt、兩套模型 ID 設定、
兩套錯誤處理。**建議保留兩者但把分工寫死**：裝置直連負責「看照片」（離線優先的產品立場，後端不可用時仍能工作）；
後端只負責**需要 Python 函式庫的事**（`openpyxl`／`python-docx` 改寫客戶的 Excel／Word）。
`/map-fields` 用 AI 做欄位對應這件事其實可以搬到裝置端做——那樣後端就完全不需要 Gemini 金鑰，
部署與資安都簡單一階。這是一個**值得做的簡化**，但要先有實機驗證再動。

**B2 `.env` 當 asset 打包進 APK。** `pubspec.yaml:82` 把 `.env` 列為 asset，這正是金鑰 bug 的機制之一，
而且「把密鑰檔打包進 APK」本身就不該做。**建議移除 asset 宣告**，`.env` 只給開發機用，
金鑰一律走設定頁 → `SettingsProvider.applyToGeminiService()`（PR #77 已讓它成為唯一出口）。

**B3 金鑰明文存 `SharedPreferences`。** 改用 `flutter_secure_storage`（Android Keystore／iOS Keychain）。
小改動，試點前必做。

**B4 後端 `judge-readings` 與裝置端 Tier 0 引擎讀同一份標準。** 兩邊結果相同（有同步守門測試），
後端那條只在裝置端引擎失敗（asset 缺失）時有用。**建議把後端判定降為診斷用途或移除**，
讓「判定」這件事只有一個實作——少一條契約就少一種「接了但傳錯」。

**B5 標準資料沒有來源欄位。** `inspection_standards.py` 56 條標準只有法規名稱與條號，沒有 `source_url`／
`verified_on`。這次抓到 4 筆錯，其餘 52 筆**沒有人核過**。建議：①先修已知 4 筆；②每條加 `source_url` +
`verified_on`；③加守門測試「沒有來源不准新增標準」；④逐條核對是一個明確可分派的工作（一個下午）。

**B6 兩條產品線同一個 repo、同一個 App。** 共用的只有 `GeminiService`、`DatabaseService`（同一個 SQLite，
不同表）、`pdf_report_service`、`share_queue_service`。**不建議現在拆 repo**——拆了要維護兩份 CI、兩份共用服務，
而現在連一次實機驗證都沒有。建議做的是**把邊界寫在目錄上**：`lib/blade/`（screens+services+models）與
`lib/inspection/`，共用的留在 `lib/shared/`；`import` 跨界就由 analyzer 的 `import_lint` 或死角查核擋。
等其中一條真的有使用者了，再決定要不要拆。

**B7 RAG 子系統。** 後端 `rag.py` + `services/rag.py`（573 行）+ App 的 `RagManagementScreen`（209 行）
從設定頁可到達，但**核心流程完全沒用到**（`form_inspection_screen.dart` 零引用）。它是「以後 AI 判讀可以查參考資料」
的準備。**建議：移出主 App，留在後端當獨立的實驗端點**，或整個歸檔——現在的 AI 判讀路徑（裝置直連 Gemini）
根本到不了後端的 RAG。

### 3.C 文件

| 文件 | 問題 | 建議 |
|---|---|---|
| `ROADMAP.md` | 80% 是五階段十個功能的願望清單，沒有一項有排程，與「核心只有兩個」矛盾 | **砍到現況 + 下一步 + 刻意不做 + 移除計畫**；願望清單歸檔到 `docs/archive/` 留作決策紀錄 |
| `AUTO_FILL_SYSTEM.md` | 標「最後更新 2026-03-05」，但描述的四條端點是活的、是後端的核心 | 保留，更新日期與 `/map-fields` 契約修正；A6 刪端點時同步 |
| `LAUNCH_PLAN.md` | §0 進度表停在 09-13；§2 現況數字是 08-31 的 | §0 加 09-16 的三個修正與本文連結；其餘標明是快照 |
| `README.md` | 「目前隱藏的功能」一句話把死碼說成功能 | 改成「現況與定位」，連到本文 |
| `docs/USER_GUIDE.md` §6 | 同上 | 同上 |
| 葉片 8 份文件 2,411 行 | 沒有問題——它們各自是一次實測的紀錄，不重複 | 不動；`BLADE_TEST_REPORT.md` 是入口 |

### 3.D 保留而且是資產的

免得「全面討論」變成「全面否定」，這些**不要動**：

- **Tier 0 離線判定引擎**（`standards_engine.dart`）＋單位換算——產品的差異化核心。修來源、不改架構。
- **死角查核**（`audit_dead_ends.py`）——保守設計是對的；要補的是「契約一致性」那一類，見 §4。
- **純 Dart PDF**、**離線分享佇列**、**拍照品質閘門**、**連線可達性探測**——現場條件的正確回應。
- **葉片 Python 原型 + Dart 移植 + 夾具交叉驗證**——整套方法值得保留，即使 Mode A 最後沒人用。
- **Mode B 的評估協定、切分群組、複核工具、第一遍標記**——這是可投稿的部分。
- **CLAUDE.md 的「已知問題追蹤」**——它是這個專案最有價值的單一文件；長是必要的。

---

## 4. 下一步建議（依可行性排序）

### 現在、不需要人、不需要實機（1–2 週）

1. **法規引用**：修已知 4 筆；`inspection_standards.py` 每條加 `source_url`／`verified_on`；守門測試「沒來源不准新增」；
   重新匯出 JSON。→ 這是**申報文件會印出來的字**，優先級最高。
2. **金鑰安全儲存**（B3）+ **移除 `.env` asset**（B2）+ **`allowBackup=false`**。半天。
3. **死碼移除批次 A1–A5**（App 端 ≈ 5,400 行），每批次三軌全綠再進下一批。兩天。
4. **後端端點清理 A6**（≈ 2,500 行）+ `AUTO_FILL_SYSTEM.md` 同步。一天。
5. **release APK 建置設定進版控**：盤點時在本容器建出 100 MB APK，但要改 `proguard-rules.pro`（ML Kit 四條 `-dontwarn`）、
   `jvmargs`、Gradle／AGP 版本——現在 committed 的樹建不起來。半天。
6. **契約一致性測試**：對 App 端每一條 `/api/*` 呼叫，寫一條「送出去的 payload 用後端 pydantic model 解得回來、
   而且沒有欄位被丟掉」的測試。這是死角查核抓不到的那一類，四例都會被它抓到。一天。

### 需要一個人、一個下午

7. **Mode B 複核**：1,842 格已排好順序（788 格 `b` 排最前），工具是離線 HTML。這是健康記憶庫**唯一的閘門**。
8. **56 條標準逐條核對**：每條開 `law.moj.gov.tw` 對一次。B5 的欄位做好之後就能分派。

### 需要一台 Android 手機、一趟

9. **Issue #43 端到端**：完整流程 + 斷網 + `getFrameAtTime` 在目標機型回不回得出幀。
   **這是所有「已完成」變成「可用」的唯一途徑。**

### 學術產出（可以與上面平行）

10. dataset-audit 短文（§2.2 的第一篇）——數字全在、腳本可重現、不需要新模型。
11. IEA Task 46 兩軌分級表：先修 `closeup_taxonomy.json`（測試守著「不可憑印象填」，要一起改）、再寫。

### 刻意不做

- **不做 `ROADMAP.md` 那十個功能**（設備管理、團隊協作、智能提醒…）——沒有一個使用者之前，多一個功能就多一條沒人測的接縫。
- **不拆 repo**（B6 的理由）。
- **不做 Mode B 的模型（B3）**直到健康照與人工簽核有了——合成資料不能替代，這在規格裡寫了三次。
- **不為紅色 CI 除錯**——GitHub Actions 是帳號預算問題，本機三軌是現行驗證方式。

---

## 5. 附錄：沒有入口的程式清單

方法：對每個 `*Screen` 類別數 `lib/` 內被建構的次數（word boundary，扣掉自己）；service／model 數被 `import` 的檔數。
**這只是候選清單**——真的刪之前每一批次要跑三軌 + 死角查核。

```
畫面（0 入口或只被 0 入口的畫面引用）
  141  home_screen.dart                    0 入口
  208  history_screen.dart                 0 入口（UnifiedHistoryScreen 才是活的）
  225  inspection_records_screen.dart      0 入口
  496  step1_upload_checklist.dart         只被 home_screen 引用
  330  step2_capture_photos.dart           只被 home_screen 引用
  281  step3_review_results.dart           只被 home_screen 引用
  259  step4_records_report.dart           只被 home_screen 引用
  336  quick_analysis_screen.dart          只被 home_screen 引用
  975  template_selection_screen.dart      0 入口
  474  template_filling_screen.dart        只被 template_selection 引用
  685  auto_fill_screen.dart               0 入口
  760  one_stop_inspection_screen.dart     0 入口
─────
 5,170

服務／provider／model（呼叫端全在上面）
  600  providers/inspection_provider.dart  活呼叫端只剩 dashboard 的 initialize()
  239  services/cloud_run_api_service.dart 只被 inspection_provider 引用
  303  services/photo_sync_service.dart    呼叫端：main（initialize）、inspection_provider、step1/2、photo_field_input
  163  models/measurement.dart             0 引用
  103  models/photo_sync_task.dart
   77  models/pending_upload_task.dart
   32  models/auth_tokens.dart
   47  models/inspection_job.dart
  165  models/template_inspection_record.dart

widgets（只被上面的畫面引用）
  355  widgets/template/section_card.dart
  296  widgets/field_inputs/photo_field_input.dart
  ≈300 widgets/field_inputs/ 其餘 8 檔
  118  widgets/stepper_widget.dart

可到達但核心流程不用（B7，另議）
  209  screens/rag_management_screen.dart   從 settings 可到
```

後端 24 個端點中 App 端引用到的 12 條：`/api/auto-fill/{analyze-structure, execute, judge-readings, map-fields, preview}`、
`/api/rag/{add, items, items/{id}, query, stats, upload}`、`/api/templates/create-from-file`、`/health`。
其餘 12 條沒有任何客戶端。
