# Session Handover — InduSpect Weekly Routine

> Weekly routine agent 與劉老師之間的接力筆記。每次執行末段更新此檔。
> 最新的在最上方。`[NEEDS HUMAN]` 區塊是必須劉老師裁決的事項。

---

## 2026-09-13 — 文件整理與 Mode B B0（接棒重點）

**如果你是下一個 session，只讀這一段就夠開工。**

### 現在在哪裡

| 產品線 | 狀態 |
|---|---|
| 定檢表 pipeline | 程式面完成。**唯一擋路石是實機端到端測試**（Issue #43） |
| 葉片 Mode A（地面整機） | App 端完整實作（表面／幾何／聲音層）。影片抽幀的 Kotlin **從未被編譯過** |
| 葉片 Mode B（近身影像） | 規格 + 分類表 + 語料實測完成，**演算法一行都還沒寫** |

三軌全綠：Flutter 506 / 後端 191 / 葉片原型 184（2026-09-14 本機實測；GitHub Actions 已因用量預算暫停），另有死角查核擋 PR。

### 這一輪做了什麼

1. **[PR #69](https://github.com/dofliu/InduSpect/pull/69)（draft，CI 全綠，等合併）** — Mode B 的 B0：
   - `BLADE_CLOSEUP_TAXONOMY.md`（由 `blade_prototype/data/closeup_taxonomy.json` 渲染，15 條守門測試）
   - `blade_prototype/CLOSEUP_BASELINE_REPORT.md`（語料實測）
2. **文件整理**（本次 commit）：根目錄 markdown 由 22 份降到 8 份。詳見下方「文件在哪裡」。

### 文件在哪裡（整理後）

| 要找什麼 | 去哪裡 |
|---|---|
| 系統做什麼、為什麼 | `README.md` |
| 怎麼操作 | `docs/USER_GUIDE.md`（**新檔**，操作步驟從 README 搬過來） |
| 開發規則、關鍵檔案、已知問題 | `CLAUDE.md` |
| App 架構、DB schema、變更紀錄 | `flutter_app/DEVELOPMENT.md` |
| 功能規劃 / 上線計畫 | `ROADMAP.md` / `LAUNCH_PLAN.md`（§0 有進度更新） |
| 已完成或已被取代的文件 | `docs/archive/`（**不要照著做**，該目錄的 README 說明每一份為什麼被歸檔） |

**刪掉的 7 份**（`arch.md`、`database.md`、`ui.md`、`prj.md`、`todo.md`、
`feature_enhancements.md`、`COMPILE_CHECK_REPORT.md`）描述的是**專案沒有採用的架構**
（Supabase / GCP 無伺服器 / 登入流程），留著會誤導。內容仍在 git 歷史。

### 2026-09-13 追加：健康照與正常結構第一版已做

`blade_prototype/CLOSEUP_HEALTHY_SET.md`。全語料取像判定（839 合格／`crack` 0/177）、192 張正常結構普查
（避雷接點／VG 板／排水孔 **0 張**；標註痕跡 **35%**）、約 1,200 格健康候選（`unreviewed`）、8 張概略框。
**全部單一標註者未複核。** 下一步是人工複核，不是再寫程式。

### 2026-09-14 追加：葉片檢測整體測試報告

`blade_prototype/BLADE_TEST_REPORT.md`——把葉片模組**現在能測的全部跑一遍**：自動化測試（Python 131／Flutter 497 CI）、
75 張真實照片**逐張與 2026-09-07 比對 0 差異**（23/30、閘門 8 放行全對、0 誤放行）、四層合成端到端（正視 300 cm 偏移量到
24.8/25.0 px、2 cm 侵蝕 rms 比 3.09、+4 dB 侵蝕 z=4.6、哨音 13.9 dB、風噪 0.5 正確判不可用、影片 rpm 11.999/12）、
圖文報告三份（兩張真實照 + 一份合成全層）、運動分割輪轂 6 段重跑。數字由 `scripts/blade_test_report.py` 算，不手抄。

**三個新發現**（已寫進 `BLADE_INSPECTION_SPEC.md` §13 第 11、12 項）：①放行的 8 張真實照片裡三片互比標記了 **5 張**，
量級是透視差不是缺陷（ed894e7a 葉尖偏移 226 cm）；②**側視全機照會被閘門拒收**（規格 §5.1 側視模式與「葉片數 ≠ 3」規則衝突，
App 端同樣）；③`synth-still` 給的尺度塞不下轉子時會靜靜產出葉尖出框的圖，閘門拒收的文字說的是「葉片貼塔架」，會誤導。

### 2026-09-14 追加：側視閘門（§13-12）已修，且 CI 改成本機跑

- **GitHub Actions 因用量預算暫停**（劉老師決定本月不充值）。PR 上的 CI 一律秒紅（runner 未指派），不是程式問題。本容器可以裝 Flutter（指令在 `CLAUDE.md` 已知問題「本機 Flutter 取代 CI」），`flutter test` 506 條約 40 秒；合併前驗證改成本機三軌。
- **§13-12 側視閘門**：`quality.detect_side_view`／`BladeStructureGate.detectSideView`（恰好兩片、一上一下、垂直 ±12°、有塔架）→ 側視不套三片規則，改警告「互比不適用、只量垂掛葉片彎曲」；幾何層 `side_view_summary`／`sideViewSummary`；報告與 App 備註同步。75 張真實照片閘門結果逐張 0 改變。Python 144／Flutter 506 本機全綠。新夾具 `scripts/make_side_fixture.py`。
- **§8 第 3 項也修了**：拒收訊息依葉片數分開（`n = 0`／`1-2`／`>3`）。原本想加的「遮罩貼到邊界 → 轉子沒入鏡」規則**量過之後否決**——正確放行的真實照片葉尖到邊界只有 0.02–0.03 R、設計內的 12 MP 合成照 0.007 R，不可分；所以只改訊息、放行與拒收完全不變（逐張 0 差異）。75 張裡 18 張是 `n = 0`，在此之前全被告知去「等轉子轉開」。
- 未動：§13-11（透視假訊號）要外業資料才能校準雜訊底。

### 2026-09-14 追加：Mode B 人工複核工具

- **`blade_prototype/scripts/closeup_review_tool.py`**（+ `closeup_review_tool.html` 樣板）：把第一版標記
  變成可簽核的東西。三個佇列一個工作區——健康候選格 1,842、`x` 陰影反光全解析度複核 6、概略框 18。
  `build` 產離線工作區（切圖 + 單檔 HTML，鍵盤 y／n／u／s，可中斷續做，約 32 MB）、
  `ingest` 併進版控的決策檔、`status` 報還差多少。
- **四條規則在 `ingest` 執行，不是在畫面上**（畫面可以被繞過，匯入不行）：升格要人名（`claude-first-pass`
  這類模型名整批拒收）、跳過 ≠ 乾淨（不寫就維持 `unreviewed`）、顯示倍率 < 1 的升格不收（654 的教訓）、
  決策綁座標（候選重產後對不上的列為失效不沿用）。每條都有反向測試，共 13 條。
- **決策檔 `data/closeup_review_decisions.json` 目前 0 筆**——工具讓複核可以被執行，不代表已經被執行。
  §0 的「約 1,200 格可用」仍是目視抽樣推估。**這件事需要人坐下來看**，不需要實機也不需要外業。
- 說明在 `blade_prototype/CLOSEUP_HEALTHY_SET.md` §6。

### 2026-09-14 追加：Mode B 切分群組（§6 第 1 條終於有執行依據）

- **`blade_prototype/scripts/closeup_blade_groups.py` + `CLOSEUP_SPLIT_GROUPS.md`**：語料沒有
  `blade_id`／`flight_id`，改用影像重疊連出 **524 個 `split_group`**（全域描述子取候選 → ORB+RANSAC
  內點數 ≥ 12 → 連通分量）。702/1,065 張落在多張群裡。
- **最重要的數字：語料自己附的 `train_val_test_split.txt` 洩漏 63.4%**——它是 `random.shuffle`
  按照片切（作者的 `generate_split.py` 就在語料裡），102/161 張 test 影像在 train 有已驗證的近重複。
  **任何在那個切分上得到的準確率都是虛高的，包括語料論文自己的數字。**
- **門檻 12 是量出來的不是挑的**：12–40 之間最大群只從 25 變到 19（平台），低於 12 假邊串連失控
  （門檻 8 時 889 張黏成一群）。取平台低端——漏合併會無聲洩漏，多合併只是少一點可切的資料。
- **單一切分撐不起 §6 第 3 條**（test 只剩 9 張 thunderstrike），所以另產**群感知 5 折**：
  每折 208–218 張、逐類跨折差 ≤ 1、逐折當 test 實測洩漏 0，加總後每類測試張數 89–264 全部 ≥ 30。
  **B1 直接用 `folds`，不要自己重切。**
- 群是**下界**（畫面完全不重疊的同葉片照片連不起來），欄位刻意叫 `split_group` 不叫 `blade_id`；
  有測試守這句話不被改掉。健康候選的每一格現在也帶著來源影像的群號。

### 2026-09-14 追加：B1 評估協定（§6 四條變成會拒跑的程式）

- **`blade_prototype/scripts/closeup_eval.py` + `CLOSEUP_EVAL_PROTOCOL.md`**：`truth`／`subsets`
  產真值與子集旗標（**已進版控，所以評估不需要語料本體**）、`eval` 出逐類報告、
  `nn-baseline`／`leakage-demo` 量洩漏。
- **洩漏值量出來了：0.204。** 同一組 test（官方 161 張）、同一個 1-NN、只差訓練池裡有沒有同群照片，
  平均逐類 recall 0.605 → 0.401。`craze` 掉最多（0.618 → 0.235）。這是配對實驗不是推論。
- **1-NN 是地板不是基線**：群感知 5 折下逐類 recall 0.25–0.64。B2 的三條基線若沒明顯高過這一排，
  等於沒學到「這張長得像那張」以外的東西。
- **四條規則的執行方式**：切分宣告與 `--split` 不符／未知類別／未知影像**一律拒跑**（exit 2）；
  < 30 張的類別數字位置印「不報」（測試檢查那一列連小數點都不能有）；
  誤報分三格且**未普查自成一格**；健康照 0 張時印「量不到」不印 0。
- **新發現**：正常結構只普查 192/1065，所以 656 張有誤報的影像裡 **523 張落在「未普查」**——
  §6 第 4 條的誤報歸因目前沒有鑑別力，要把普查做完。帶標註痕跡的子集只有 68 張，每類都不足 30。
- 順手修掉分類表 `gaps` 裡「沒有葉片編號…執行不了」那條過時敘述（已解），重新渲染分類表。

### 2026-09-14 追加：正常結構普查補滿 839 張（B1 的兩個缺口補掉一個半）

- **為什麼補**：評估協定的誤報歸因把「未普查」自成一格，而第一版只普查 192/1065，
  656 張有誤報的影像裡 **523 張落在那一格**——§6 第 4 條形同虛設。
- **怎麼補**：`scripts/closeup_survey_sheets.py` 把第一版臨時做的印樣版面固定下來（4×4、每格 460 px），
  對剩下的 647 張逐張標，兩批同版面同代碼。取像合格的 **839 張現在逐張都有**。
- **結果**：誤報歸因「未普查」**523 → 0**（130 在有正常結構的影像上、423 在普查過沒有的）；
  痕跡子集從「每類不足 30 全部不報」變成 231 vs 608 報得出數字，而且差距是真的
  （1-NN 的 `corrosion` recall 帶痕跡 0.118、無痕跡 0.336）。
- **順帶**：評估域預設改成**取像合格的 839 張**（`--domain intake_P`）——Mode B 的輸入定義是 §1.2 合格的
  近身照。在這個域裡 `crack` 真值 0 張（分類表早就這樣寫），但 1-NN 仍誤報 117 張，因為它從整機照鄰居抄。
- **兩個誠實的邊界**：①`L`（避雷接點）與 `v`（VG）在 839 張仍是 0——結論從抽樣升級成全普查，
  但那是「460 px 印樣上沒看到」；②**`s`（接縫）兩批判準不一致**（192 張標 5、647 張標 0），
  數字不可用，寫進標記檔 `consistency_caveat` 並有測試守。這本身是個量測：
  同一標註者隔一段時間就會漂，要當真值必須第二個人複核。
- **還沒補的**：健康照 0 張。§6 第 4 條要的「誤報在乾淨表面上」仍然量不到，那要另外拍。

### 下一步建議（依可行性排序）

1. ~~**合併 PR #69**~~ → 已合併（2026-09-13）；PR #70（健康照第一版）也已合併（2026-09-14）
2. **Mode B 健康候選的人工複核** — 候選與**複核工具都已就位**（見上），差的是人去看。全部仍未複核。B0 量到現有可商用語料 1065 張**一張健康照都沒有**，
   §6 第 4 條的誤報分項統計執行不了。`BLADE_CLOSEUP_TAXONOMY.md` §2 的 12 項正常結構
   就是拍攝清單。這件事**不需要實機也不需要外業**，是目前唯一能純線上推進的葉片工作
3. ~~**B1 評估協定實作**~~ → 已完成（見上）。接下來純線上能做的是 **B2 的三條基線**（§8.1–8.3），
   但那要跑模型（VLM API 或本地訓練），先確認預算與環境
4. 其餘葉片工作與定檢主線都**卡在實體世界**，見下方 NEEDS HUMAN

### [NEEDS HUMAN] 卡住的四件事

1. **實機端到端測試**（Issue #43）——需要一台 Android 實機。同一趟請確認
   `android/.../BladeVideoFrames.kt` build 得起來、`getFrameAtTime` 在目標機型回得出幀
2. **葉片外業**——一次現場拍攝（停機 + 怠速各一台）即可定葉片拍攝閘門與聲學門檻，
   同一趟收 Phase 4 的語料。目前**真實手機拍的葉片照片是 0 張**
3. **後端 Cloud Run 部署**——需要 GCP 帳號操作
4. **Play 內部測試軌上架**——需要 keystore 與開發者帳號

### 踩過的坑（省下一次重複）

- **Wikimedia Commons 從本環境會 429**（API 與 upload 都會），語料抓取一律走 Openverse
- **Openverse 對查詢字做 AND 比對**：長查詢字結果歸零，短查詢字相關性崩掉，中間沒有地帶
- **`aimodel.md` 已歸檔**，模型 ID 與路由邏輯已汰換；後端一律走 `gemini_client.py`
- `blade_prototype` 全套測試約 130 秒，超過 Bash 工具預設 120 秒逾時，要加 `timeout`

---

## 2026-05-16 — Session #6（測試門檻收緊 + 文件對齊 housekeeping）

**本週做了**：在 Sessions #2-#5 的 3 個 PR（#32 #34 #35）全部 merge 後做收尾整理。

**改動**：
- `backend/tests/test_sprint3_standards.py`：拉高 `test_database_coverage` 門檻反映現況
  - 總數 ≥35 → **≥50**（main 為 56）
  - 消防 ≥10 → **≥13**（main 為 15）
  - 機械 ≥10 → **≥13**（main 為 15）
  - 壓力 ≥3 → **≥10**（main 為 11）
  - 電氣維持 ≥15（無變化）
- `backend/app/data/inspection_standards.py`：修正過時的章節 comment（消防 10→15、機械 10→15、壓力 5→11）
- `STATUS.yaml`：progress 87→89、`key_metrics` 重整為「2 core features, 46 Flutter tests, 65 backend pytest in CI, 56 regulation standards」
- `docs/handover/session-handover.md`：本檔本次更新（含 Session #3/#4/#5 rollup）

**測試**：CI 應全綠（threshold buffer 設計上留 2-6 條餘裕避免邊界 flaky）。

---

## 2026-05-16 — Sessions #3 / #4 / #5（標準資料庫四大類擴充 rollup）

**為什麼合併紀錄**：3 輪 routine 均為「純資料 append + 自動驗證」的同一模式，個別 commit 訊息已足，handover 用 rollup 表保留總覽即可。

| 輪 | PR | 動作 | 改動 |
|---|---|---|---|
| #3 | [#33](https://github.com/dofliu/InduSpect/pull/33) | 壓力/管線 +6 條 | 5 → 11 |
| #4 | [#34](https://github.com/dofliu/InduSpect/pull/34) | 機械類 +5 條 | 10 → 15 |
| #5 | [#35](https://github.com/dofliu/InduSpect/pull/35) | 消防類 +5 條 | 10 → 15 |

**累積結果**：資料庫從 40 條增至 **56 條（+40%）**，四大類別均衡覆蓋（electrical/fire/mechanical 各 15，pressure 11）。所有新增條目皆引用台灣現行法規或 IEEE/NEMA/CNS/API 國際標準。

**下一步建議**（給後續 routine）：
1. **馴化 `test_e2e_inspection.py`** → 改造為 pytest function-style 加進 CI（單檔但測試本體複雜）
2. **修復 `TestResults.check` 模式的隱形 bug**：目前 sprint test 用 `results.check(condition, ...)` 而非 `assert`，當條件不成立 pytest 仍視為 PASS（只有 stdout 出現 ❌）。需要把 sprint test 系列改為 `assert ...` 才能讓 CI 真正阻擋退化
3. **新增 `judgment_service.batch_process` 的單元測試**：目前只有 e2e 透過 FormFillService 測試該路徑
4. **`flutter analyze` 收緊**：CI 已穩定，可將 `continue-on-error: true` 移除

---

## 2026-05-16 — Session #2（CI baseline + judgment_service 直接測試覆蓋）

**本週做了**：依 Session #1 的「下一步建議 #2」，新增 `backend/tests/test_judgment_service.py`（14 個 pytest function-style 測試，含 async）並加進 CI workflow 的 pytest 清單。覆蓋 JudgmentService 的 `auto_judge` 與 `batch_auto_judge` 直接 API（之前只有透過 FormFillService 間接測試）。

**改動檔案**：
- `backend/tests/test_judgment_service.py`（新建，14 tests）
- `.github/workflows/ci.yml`（新增 test_judgment_service.py 進 pytest 指令）
- `STATUS.yaml`（progress 86→87、key_metrics 補上 judgment_service 14 tests）
- `docs/handover/session-handover.md`（本檔追加 Session #2 區塊）

**測試覆蓋面**：
- `auto_judge` 各 pass_condition：gte（絕緣電阻）/ lte（接地電阻、馬達溫度）/ range（滅火器壓力上下限）
- 多類別：electrical / fire / mechanical
- 邊界：unknown field、unit fallback、batch 空清單、batch 順序保留、回傳 dict contract（必含欄位）
- 全部 async 透過 CI `--asyncio-mode=auto` 跑

**未推送/未合併**：
- 分支：`claude/weekly-2026-05-16-judgment-tests`
- PR：將於本次 session 開出（連結待補）

**下一步建議**（下次 routine 可挑）：
1. **若本 PR CI 過** → 把 sprint test 系列（`test_e2e_inspection.py` / `test_real_form_validation.py` / `test_sprint1_photo_tasks.py` 等）逐步從 `__main__` script 改造為 pytest function-style，再加進 CI（一次處理一兩個檔，避免改動爆量）
2. **擴充** `inspection_standards.py`：新增壓力容器/管線 5-10 條（純資料、零風險、會自動被 test_sprint3_standards.py 的 `test_database_coverage` 驗證）
3. **flutter analyze 收緊**：CI 已穩定數輪後，將 `continue-on-error: true` 移除，讓 lint 議題真正阻擋 PR
4. **整理** `flutter_app/lib/screens/` step1-step4 vs `form_inspection_screen.dart` 的重複（先寫 [NEEDS HUMAN] note 不動程式碼）

**[NEEDS HUMAN]**：
- （上輪 Session #1 留下的 3 項仍待裁示：未追蹤檔案位置、Gemini API key 整合測試的 secret 設定）

---

## 2026-05-16 — Session #1（首次執行）

**本週做了**：建立 weekly routine SOP（`docs/routines/weekly-progress.md`）、新增 GitHub Actions CI workflow（Backend pytest + Flutter analyze/test）作為工業可用化的工程紀律基礎建設。

**改動檔案**：
- `docs/routines/weekly-progress.md`（新建）
- `docs/handover/session-handover.md`（新建）
- `.github/workflows/ci.yml`（新建）
- `STATUS.yaml`（更新 progress / last_updated / key_metrics）

**測試狀態**：
- Backend：未在本地執行 pytest（routine agent 環境無 Python 虛擬環境）
- Flutter：未在本地執行（同上）
- CI workflow 第 1 次：50 過 / 1 fail（async test 需 pytest-asyncio auto mode）→ 已加 `--asyncio-mode=auto`
- CI workflow 第 2 次：backend ✅ pass (32s)；flutter ❌ fail（pubspec 宣告 .env 為 asset 但 CI 無此檔）→ 已加 `touch .env` step

**未推送/未合併**：
- 分支：`claude/weekly-2026-05-16-ci-workflow`
- PR：將於本次 session 開出（連結待補）

**下一步建議**（下次 routine 可挑）：
1. **若 CI 失敗** → 先修 CI（這是 routine agent 可做的小範圍）
2. **若 CI 通過** → 為 `backend/app/services/judgment_service.py` 補單元測試（覆蓋率明顯不足，且是規則類邏輯，無外部相依）
3. **擴充** `backend/app/data/inspection_standards.py`：新增壓力容器/管線檢查的 5-10 條標準（純資料新增，零風險）
4. **整理** `flutter_app/lib/screens/` 的 step1-step4 是否仍被使用 vs `form_inspection_screen.dart`，若已被取代則文件化或標記 deprecated（須先確認，可能觸發 §6 架構決策 → 建議只先寫 [NEEDS HUMAN] note 而不動）

**[NEEDS HUMAN]**（Session #7 已收結，保留紀錄以利追溯）：
1. ~~**本地 main 與 origin/main 不同步**~~ — Session #1 當下已 `git restore` + `git pull --ff-only` 處理完畢。劉老師後續未提出此暫存改動有特殊意圖，視同已解決。
2. ~~**未追蹤檔案**~~ — Session #7 解決：5 個 PNG/PDF 全部移到 `_local_archive/`（已加進 .gitignore），檔案保留在工作目錄但不入版控。
3. **CI workflow 中 Gemini API key 處理** — Session #7 確認劉老師立場：產品本身用使用者個人 API key（透過 .env），CI 目前的測試集為純邏輯測試不需打 Gemini API，繼續用假值 `ci-fake-key` 即可。**現況不需要 GitHub Secret，未來如需啟用整合測試再評估。**

---

*本檔為活文件。下次 routine 從此檔最上方接續。*
