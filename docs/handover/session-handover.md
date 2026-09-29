# Session Handover — InduSpect Weekly Routine

> Weekly routine agent 與劉老師之間的接力筆記。每次執行末段更新此檔。
> 最新的在最上方。`[NEEDS HUMAN]` 區塊是必須劉老師裁決的事項。

---

## 2026-09-19 — 三條外部語料驗證（接棒重點）

**如果你是下一個 session，先讀這一段，再讀 2026-09-13 那一段的「現在在哪裡」。**

### 這一輪做了什麼（全部桌面、零實機、Flutter 端零改動）

| 條 | 做了什麼 | 結論 | 去哪裡看 |
|---|---|---|---|
| 1 | Commons 帶 EXIF 焦距 + 已知機型的真實整機照 → 姿態估計與補償第一次跑真實輸入 | 86 張放行 3 張正視、姿態可用 3；原始標記 1 → 補償後 1。**正視放行仍只有個位數，補償在真實照片上的成績還撐不起結論** | `blade_prototype/REAL_POSE_VALIDATION.md`、SPEC §13-15 |
| 2 | Mode B 探針不重訓丟到 WTBs2025（CC0）與 HF sees-innovation | **取像探針不能當閘門**（廂型車 59/62 判 P）；**缺陷探針跨語料 ≈ 亂猜**（lift ≈ 1，只有雷擊 7.7）；硬規則誤觸 3/7,544 | `blade_prototype/CROSS_CORPUS_VALIDATION.md`、`BLADE_CLOSEUP_SPEC.md` §13 |
| 3 | HF 整機照當 Mode A 閘門壓力測試 | 無人機在輪轂高度拍的 104 張放行 1；六點鐘那片落在地平線以下被截短；非整機 307 張放行 0 | `CROSS_CORPUS_VALIDATION.md` §2、SPEC §13-14 |

### 2026-09-28 追加：Commons 第二批（鏡像原圖 66 張）跑完了

本機 IP 仍被 `upload.wikimedia.org` 擋著，只抓得到鏡像（`ftpmirror.your.org`，媒體凍結在 2013-03）上有的
**66 張**——而且是**原圖**不是縮圖。逐張結果 `blade_prototype/data/commons_pose_results_mirror.json`、
報告 `blade_prototype/REAL_POSE_VALIDATION_MIRROR.md`（由結果檔渲染，數字不手抄）。
（抓的當下以為第一批 86 張已隨 scratchpad 消失、要重抓 313 張；**2026-09-28 盤點發現它們還在**，
所以磁碟上已有 136 張、實際還缺 **177 張**——見本節末與下一節。）

| | 第一批（86 張，縮圖端點） | 第二批（66 張，鏡像原圖） |
|---|---|---|
| 閘門放行 | 5（正視 3、側視 2） | 5（正視 3、側視 2） |
| 姿態可用 | 3/3 | **2/3**（1 張沒有塔架軸，估不出 yaw） |
| 葉尖偏移 原始 → 補償後 | 1 → 1（消 0、留 1、新增 0） | 1 → 1（消 0、留 1、新增 0） |
| 半徑 原始 → 補償後 | 1 → 1 | 0 → 0 |
| 預彎擬合落在 0–8 m | 1/3（中位 5.2 m） | **0/2**（實際 9.02、17.55 m） |
| 輪轂高 ±20% 翻掉補償結論 | 0/3 | 0/2 |

**這一批最值錢的一行是「補償拒絕出手」**：兩張姿態可用的正視照，預彎擬合都跑到 9.02 與 17.55 m
（風機預彎是 0–8 m 量級），於是 `deflection_compensated = false`、葉尖偏移一個都沒被動——
SPEC §13-11「沒有可信姿態就不補」這條不可退化的約定，**第一次在真實照片上被行使到**。

**放行的正視照根本不是補償的工作點**：距離 **526–1149 m**、cm/px **24–45**（一個像素半公尺級）、
|yaw| 中位 **34.7°**（補償半徑只在 ≤15° 適用）、仰角中位 9.2°。那是路人從馬路對面拍的，
不是站位規範要的 3–4× 輪轂高。61 張拒收的理由分布（同一張可能多條）：只定位到 N 片 32、三片葉尖半徑差超標 25、一片都沒定位到 17、幾乎分不出風機 2。

**兩批併起來看要按不重複算**：136 張不重複（86+66，**重疊 16**）、閘門放行 **9 張不重複**（正視 5、側視 4）、
姿態可用 4/5、**補償實際算過 4 張、預彎擬合合理的只有 1 張**。
（`e29ab87` 的 commit message 寫「合計 152 張、補償 5 次」是把重疊那 16 張算了兩次，以這一節為準。）
結論與 2026-09-19 相同且更硬：**補償在真實照片上的成績撐不起結論，缺的是站位合規的近距離照片，不是更多遠景照。**

**順帶量到一件方法學上的事——但它比我一開始寫的弱得多**（2026-09-28 逐張量磁碟上的影像後修正）：
重疊的 16 張裡，**真的是「縮圖 vs 原圖」的只有 7 張**（第一批長邊 1920 px、第二批 3648–4256 px 原圖）；
另外 9 張兩批拿到的是**同一個檔案、逐位元相同**（Commons 縮圖端點在要求寬度 ≥ 原圖寬度時直接回原圖），
**其中就包含唯一重疊又放行的 c5682409**——所以那 9 張「連補償數字都一樣」是恆等式，不是證據。
收／不收在 16 張上都相同，但有證據的 7 張**全部是拒收**，放行側一張都沒有；
那 7 張的內部量也全都有變動（遮罩比、離散度小幅移動，c6326631 葉片數 3 → 1、拒收理由整個換掉）。
成立的只有「**在拒收側**，換解析度沒有改變收／不收」。測試已改成釘住這個實際結構
（`test_source_resolution_does_not_change_the_gate`：16 張收／不收相同、有差的恰好是那 7 張、那 7 張全是拒收）。

**兩個結果檔不可互相覆寫**（有測試守）：第一批 86 張裡有 **70 張鏡像上拿不到**，要重抓得換一個沒被擋的網路。
（更正一個我先前寫錯的判斷：那 86 張**沒有消失**，2026-09-28 盤點時還在 scratchpad 的 `commons_turbines/`，
日期就是 2026-09-19 那次抓的。先前以為沒了，是因為可攜抓取器指向的是一個新的空目錄。
**但它們只活在容器裡**，回收就真的沒了，所以「結果檔不可覆寫」這條不變。）

### 下一個 session 該做什麼（按順序，2026-09-28 依現況重排）

**先看這個容器還剩什麼**：影像語料全都只活在 scratchpad，容器回收就沒了。2026-09-28 盤點時**都還在**——
Commons **136 張**（`commons_turbines/` 86 + `mirror_live/` 66）、`wtb/` 2,132、`wtbs2025/` 7,544、`hf_turbines/` 1,855。
**任何需要影像的事，在影像還在的 session 裡做最便宜**；回收之後 wtb／WTBs2025／HF 重抓得到（figshare／HF 可達），
**Commons 那 136 張重抓不回來**（upload.wikimedia.org 仍擋著，鏡像只有 66 張）。可寫磁碟只剩約 4 GB，抓新語料前要先清。

1. ~~補上「放行側」的解析度等價性~~ **已做（2026-09-28），而且結果是否定的**——
   見 `blade_prototype/RESOLUTION_SENSITIVITY.md`、SPEC §13-16。9 張放行照縮到寬 1280 重跑：
   **收／不收翻掉 3 張、取景分類翻掉 3 張，翻的全是側視**（4 張側視每張都至少在一個 JPEG 品質下翻掉；
   c49384455 在品質 85 翻、80 不翻，c19637139 反過來——**像素尺寸相同、只差再壓縮**）。
   正視 5 張閘門沒翻，但**預彎擬合的「合理／不合理」會翻**（5.22 → −11.13 m、9.02 → 7.19 m），
   也就是「補不補償」這個開關被來源決定。三個後果已經落地：①續抓的縮圖寬度預設 1280 → **1920**
   （`commons_portable_fetch.py`，有測試不准掉回去）；②跨批次**只能併正視的收／不收**；
   ③SPEC §13 新增第 16 項「側視判定會被 JPEG 再壓縮翻掉」，**App 端未改、待決策**。
2. ~~側視判定要補強~~ **已做（2026-09-28），但結論和原本想的相反**——見 SPEC §13-16。
   追下去發現兩件事：①不穩定的不是 ±12° 那條門檻，而是**輪轂定位**（側視剪影是粗細均勻的直桿，
   距離變換的最大值是平頂的，遮罩動一點點 argmax 就跳幾百 px，輪轂一跳葉片上下就翻）；
   ②**那 4 張根本不是側視照**——逐張看過是塔基的門特寫、施工中的吊車與光塔（描述寫 im Bau）、
   風場遠景、夕陽下的兩台風機。量過臂長／輪轂到軸線垂距／細長比／塔軸偏移，
   **合成夾具（真側視）與「兩台風機同框」落在同一區**：二值剪影裡沒有「這是一個轉子」的證據。
   所以不是調參，改成**宣告制**：只有呼叫端說「這張要拍側視」才走側視規則，沒宣告一律走正視規則
   （Python `assess_capture(expected_view=)`、Dart `judge(expectedView:)`，App 從 `WtMedia.view` 接上）。
   實測：Commons 兩批放行 5 → **3**（只掉那 2 張誤放行）、75 張真實照片**逐張 0 個欄位改變**、
   合成側視夾具宣告後照樣放行。代價是「從相簿挑側視照」與語料批次跑會被正視規則擋掉，有測試釘住。
3. ~~§1.2 閘門要換掉外觀探針~~ **已做（2026-09-28），結論是做不到**——`blade_prototype/CLOSEUP_INTAKE_PHYSICAL.md`。
   四種互相獨立的物理操作化（邊框背景厚度／Hough 前後緣間距／天空地面占比／形態學細結構）在 1,065 張上：
   單一特徵最佳門檻（**in-sample、刻意樂觀**）**0.625**、全部 13 維合起來群感知 5 折 **0.526 ± 0.027**
   （亂猜 0.5、探針 0.910）——**合起來比樂觀上界還低，沒有可泛化訊號**。
   原因量得到而且是語意的：**過曝的白葉面與陰天的天空在像素上一樣**（標成合格的極近表面特寫被判成 99% 背景，
   而灰雲天空的整機照被判成 0% 背景）。能分辨整機照的是「畫面裡有沒有一台風機的形狀」。
   **所以探針維持建議性**（不得單獨拒收或放行），§1.2 要自動化只剩兩條路：
   ①把取像條件變成**宣告＋感測器**（無人機知道自己的距離與角度——與側視改宣告制同一個道理）；
   ②訓練葉片／背景分割模型，而那要先有分割標註。兩條都不是「再調一次參數」。
4. ~~Mode A 硬規則加「定位到的轉子占畫面多少」~~ **已做（2026-09-29），但改的不是那個量**——CLOSEUP_SPEC §13 第 2 項。
   ①**「轉子占畫面多少」分不開**：誤觸 0.44／0.63／0.45 夾在真整機照的 0.20–1.08 之間，圓盤內背景比也一樣。
   ②**誤觸是 4 張不是 3 張**：`Blade/0407` 上一輪記成「輪轂 + 機艙的仰拍、硬拒收對」，
   全解析度看是無人機俯拍、葉片填滿畫面、沒有輪轂也沒有機艙——依 §1.2 是 P。
   ③有鑑別力的是**轉子上方的背景是不是天空**（Mode A 的設計範圍就是地面仰拍對乾淨天空）：
   植被占比誤觸 0.65／0.61／0.34／0.27、正確的 0.00、真整機照 ≤ 0.08 → 門檻 **0.15**。
   四張誤觸全部不再硬拒收、11 張真整機照全部仍硬拒收；規則只移除不新增，所以重跑只跑原本命中的那幾張
   （`data/closeup_hard_reject_review.json`）。**Mode A 端與 App 未改。**
5. **WTBs2025 當外部測試集**：先按原始編號去重（`oil leakage` 520 張只有 29 個原始編號），再逐張重標成本表子類。
6. **Commons 還缺 177 張**（313 入選 − 已抓到 136，**不是 247**）——**這個容器裡做不了**，要一台沒被
   `upload.wikimedia.org` 擋住的機器。分類頁盤點已做完（2026-09-19 晚）：Commons 沒有任何「從下方看／正面／仰拍」
   的取景類分類，能拿到機型已知照片的只有機型分類頁的子分類（`search --recursive-depth 2`）與地區分類頁的 `search-view`。
   帶著 **`scripts/commons_portable_fetch.py`** 去跑（純標準函式庫、零相依、可續傳）：
   - 沒被擋的網路：`python3 scripts/commons_portable_fetch.py --manifest data/commons_turbines_manifest.json --dir <dir> --pace 15`
     （鏡像先試、404 才回退 Wikimedia；**寬度用預設的 1920，不要用 1280**——見第 1 項）。**`--dir` 要指向已經有那 136 張的目錄**，待抓清單是看磁碟不是看 manifest 的 `file` 欄位
     （那個欄位只有第一批的 86 筆有值，指向新目錄會把 136 張全部重抓一遍）。
   - 被擋的機器上只剩鏡像可跑（`--mirror-only`），而鏡像凍結在 2013-03，**那 66 張已經抓完了，再跑沒有新的**。
   三道**不可退化**的保護（各有回歸測試）：①`--pace` 地板 7.2 s（500 次/小時換算），低於就拒跑；
   ②全域 429 預算 5 次且**跨趟有效**——上一趟因限流中止過就直接 `rc=2` 拒跑，只有 `--new-network` 解得開；
   ③被擋時 429 實證會寫進 `fetch_log.json`，那是寄給 bot-traffic@ 的材料。
   抓完 `real_pose_validation.py run` + `report` 要**另存第三個結果檔**（既有兩個都不可覆寫），再跑一次文件重填。
   子分類裡最大的一組（E-126 Hamburg-Altenwerder，38 張）是**空拍系列**，閘門會全部拒收——別指望它。

### 環境備註

- 外部語料的影像與特徵都在 scratchpad（重開 session 就沒了）：WTBs2025 要從 figshare 28876406 重抓（479 MB zip），
  HF 那份用 `datasets` parquet（294 MB）。凍結特徵抽取用 `closeup_features_cnn.extract_paths`（唯一 import torch 的檔案）。
- **Wikimedia 的封鎖按服務分開，而且 upload 那個不會自己退**（2026-09-26 實測）：
  `upload.wikimedia.org` 靜默 **6 天**後單發試探仍是 429、Retry-After 仍是 600（09-19 被擋時是 300，09-20 升到 600），
  **沒有任何衰減**；同一時間 `commons.wikimedia.org/w/api.php` 只回 Retry-After **32 s**（每分鐘滾動窗，等一下就能用）。
  所以「Commons 從本環境會 429」要分開講：**API 可用、圖片 CDN 不可用**。
  不要再從這個 IP 試探——每試一次都可能墊高懲罰。**換 UA／換 IP／代理池是 API Usage Guidelines 明文禁止的規避行為**，不要做。
- **病根有一半在我們自己**：`fetch_commons_turbines.py` 舊的 `BACKOFF_429_MAX_S = 300` 會把伺服器說的 `Retry-After: 600`
  夾成 300、**提早一半重試**，正是 Robot policy 說會被延長封鎖的行為，極可能就是懲罰從 300 被墊到 600 的原因。
  2026-09-26 已修為 3600（伺服器明確給的秒數一律全額等，有測試守）。
- 要談量級請寄 **bot-traffic@wikimedia.org**——Wikimedia APIs/Rate limits 與其 FAQ 都指名這個窗口
  （原文：「Bot operators who are unsure how to get the access they need can contact the Wikimedia Foundation at bot-traffic@wikimedia.org」）。
  **舊文件寫的 `noc@wikimedia.org` 是錯的**，那是泛用維運信箱，查無任何文件把它列為此用途的窗口。
- 官方**沒有**任何能拿到 Commons 圖片本體的批次途徑（已逐條查證）：Enterprise 只給 metadata／HTML，媒體欄位是指回 upload 的 URL 且 Commons 不在支援清單；
  Commons 媒體檔**從 2013 年起就沒有 dump**（T298394 開票五年仍在 backlog，卡在近 500 TB）；官方 mirror 清單七家裡**只有 `ftpmirror.your.org` 帶 raw images**，
  而它凍結在 2013-03。313 張這個量級在 Wikimedia 眼中是「正常使用」不是批次取用，那些管道本來就不是為這個規模設計的。

---

## 2026-09-13 — 文件整理與 Mode B B0（接棒重點）

**如果你是下一個 session，只讀這一段就夠開工。**

### 現在在哪裡

| 產品線 | 狀態 |
|---|---|
| 定檢表 pipeline | 程式面完成。**唯一擋路石是實機端到端測試**（Issue #43） |
| 葉片 Mode A（地面整機） | App 端完整實作（表面／幾何／聲音層）。影片抽幀的 Kotlin **從未被編譯過** |
| 葉片 Mode B（近身影像） | 規格 + 分類表 + 語料實測完成，**演算法一行都還沒寫** |

三軌全綠：Flutter 599 / 後端 197 / 葉片原型 249（2026-09-16 本機實測；GitHub Actions 已因用量預算暫停），另有死角查核擋 PR。

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
（避雷接點／VG 板／排水孔 **0 張**；標註痕跡 **35%**）、1,842 格健康候選（第一遍逐格標記後**788 格是純表面**，全部仍 `unreviewed`）、8 張概略框。
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

- **GitHub Actions 停用期已結束（2026-09-28 實測）**：PR #84 上四個檢查全綠、runner 有被指派（Flutter 1m54s／Blade prototype 2m23s／Backend 26s／GitGuardian）。在此之前（2026-09-14 起）因用量預算暫停，PR 上的 CI 一律秒紅（`runner_id: 0`），那是環境不是程式問題——看到舊 PR 的紅不用查。本容器仍可裝 Flutter（指令在 `CLAUDE.md` 已知問題「本機 Flutter 取代 CI」），`flutter test` 506 條約 40 秒；本機三軌先跑仍然划算，但**合併前要看 PR 上的 CI**。
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
  第一遍逐格標記已把「約 1,200 格可用」修正成 **788 格純表面**，但標的是模型。**這件事需要人坐下來看**，不需要實機也不需要外業。
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

### 2026-09-14 追加：健康候選第一遍逐格標記 + B2 離線基線

兩件事，都在「讓下一步變得可能」而不是「宣稱做完了」。

**① 1,842 格健康候選逐格看過一遍**（`scripts/closeup_candidate_sheets.py` 出印樣、
`scripts/closeup_candidate_firstpass.py` 收成版控檔 `data/closeup_healthy_firstpass_wtb.json`）：

| 碼 | 意思 | 格數 | 占比 |
|---|---|---|---|
| `b` | 葉片表面 | **788** | 42.8% |
| `e` | 葉片與背景的邊界 | 648 | 35.2% |
| `n` | 不是葉片 | 274 | 14.9% |
| `u` | 判不了 | 132 | 7.2% |

- **它改掉一個數字**：可用候選從「約 1,200 格」降到 **788 格純表面**。原本的 64% 是 64 格抽樣，
  **抽樣把邊界格算成了葉片表面**——邊界格的對比來自天空不是漆面，混進健康記憶庫會讓模型把「有邊」學成正常。
- **這一遍不是簽核**，三條不可退化（`tests/test_closeup_firstpass.py` 16 條）：
  ①`annotator` 一律 `claude-first-pass`、狀態一律 `unreviewed`，這個名字正好落在複核工具的模型名黑名單裡，
  **進不了決策檔**（`pack` 還會自我對帳：黑名單放寬到擋不住它就拒絕產出）；
  ②它只改**複核的順序與先驗**（`build` 把 `b` 排最前、`n` 排最後，每格標「第一遍 b（…，未複核）」），
  不寫任何決策；③`item_id` 與 `healthy` 佇列同一套雜湊，候選重新產生後對不上的由 `verify` 點名。
- **複核的隊現在看得到進度**：`status` 會印「healthy 依第一遍先驗，未複核：b 788、e 648、n 274、u 132」。
  決策檔仍然 **0 筆**——先驗不是簽核。

**② B2 離線基線**（`scripts/closeup_baseline.py`，寫進 `CLOSEUP_EVAL_PROTOCOL.md` §3.6）：
123 維手工特徵 + 純 numpy 一對多邏輯迴歸（零初始化、無隨機種子，重跑逐位元相同），群感知 5 折。

- **平均逐類 recall 0.308，1-NN 是 0.344；平均 F1 0.374 vs 0.369——打平。**
  一組經過設計的表面紋理特徵贏不了「抄最像的那張鄰居」，這是這份語料訊號量的一個實測。
- 它把 `crack` 的 117 個誤報清成 **0**（1-NN 會從整機照鄰居抄一個過來）；
  `craze` 反贏 0.340 vs 0.262、`hide_craze` 反輸 0.380 vs 0.506——正是標註者一致率最低的那一對，
  這個順序差異多半在量標註噪音。
- **域外崩塌**：同一模型丟進 226 張取像不合格（多為整機照）的影像，預測 26/56/39/23/14、命中 2/2/8/5/0。
  §1.2 的取像閘門不是形式要求。
- **規格 §8 的三條基線仍然沒跑**：§8.1／8.2 要 Gemini API key（本容器 `GEMINI_API_KEY`／`GOOGLE_API_KEY` 皆未設定）、
  §8.3 要 PyTorch（未安裝）。這是**環境的事實不是取捨**，B2 只是地板的第二個點。

### 2026-09-16 追加：定檢主線三個接反的地方

盤點 workflow（41 個 agent）指出的最高價值項目，三個缺口疊在同一個出口——
**使用者拿到的回填定檢表與申報 PDF**。全部已修並有測試守。

1. **核心流程的 Gemini 是死的**：`form_inspection_screen.dart` 呼叫無參數 `init()`，
   只讀得到被 gitignore 的 `.env`（`pubspec.yaml` 列為 asset，打包進 APK 的是空檔）。
   設定頁的金鑰欄位對**隱藏的舊流程**有效、對**核心功能**無效。
   修法：`SettingsProvider.applyToGeminiService()` 成為使用者金鑰唯一的出口，
   核心流程每次用之前重新解析，`MissingGeminiKeyException` 讓葉片線分得出「沒金鑰」與「離線」。
2. **讀數跨量別假陽性**：關鍵字比對寫成交叉乘積，「軸承溫度」會拿到「A 相電流 12.4 A」
   並被判成「≤70 °C 合格／ISO 10816」。用 `StandardsEngine.convertValue` 的 `ok` 當量綱閘門。
3. **`/map-fields` 契約斷裂**：App 送的 `{field_label, value, ai_result}` 一個都沒宣告，
   pydantic 靜默丟掉整包，AI 憑欄位名臆造值還回報成功。已宣告 + `extra='forbid'` + 全空拒跑。

**這是同一個失敗模式的第三、四例**（前兩例：`capture_points` 有人讀沒人寫、
`blade_report_export` 的 `pendingShare` 兩個呼叫端都沒決定）。死角查核抓不到這一類——
它查的是「有沒有人叫」，而這些是**叫了但傳錯東西**。

**環境備註**：查證過程中 agent 在容器裡裝了 `torch 2.14.0+cpu` 與 `/opt/android-sdk`
（`/opt/flutter` 是更早裝的）。所以規格 §8.3「重訓模型」不再是「環境做不到」，
是「要花約 1.2 GB 磁碟裝回來」——容器是 ephemeral 的，下個 session 不在。
剩餘磁碟 7.2 GB。

### 2026-09-16 追加：專案評估文件

回答「做到哪裡、值不值得推廣、該砍什麼」三個問題，獨立成 [`docs/PROJECT_ASSESSMENT.md`](../PROJECT_ASSESSMENT.md)。
三個結論：①工程面接近完成、驗證面幾乎為零（實機 0 次、真實葉片照 0 張、人工簽核 0 筆、法規引用至少 4 筆錯）；
②最有價值的是**方法學與文件**（教學範本 + 一篇 dataset-audit 短文），不是 App；
③**約 7,900 行 Dart 沒有入口**（23%）、後端 12 個端點沒有客戶端——所謂「隱藏功能」其實沒有旗標，就是死碼。
`ROADMAP.md` 80% 的功能願望清單已歸檔到 `docs/archive/ROADMAP_FEATURE_IDEAS_2026-04.md`。
下一步順序以 `ROADMAP.md`「下一步」一節為準。

### 2026-09-16 追加：SPEC §13-11 決策——站位規範、報告措辭、姿態估計補償

- 站位 1.5–2× → **3–4× 輪轂高、站在軸線上**（舊站位閘門一律拒收）。
- 正視發現沒補償寫「含透視分量」，補了寫仰角／偏軸／預彎擬合。
- `pose.py`／`blade_pose_service.dart`：仰角由輪轂高 + EXIF 焦距、yaw 由塔軸偏移（overhang 先驗 5 m，**粗估**）；留一法擬合預彎補償。
  合成上原始標記 5/8 → 補償後 5/8 不再標、注入 400 cm 缺陷留得住。**只在合成上驗過**：真實照片沒有輪轂高與焦距。
- 下一步要有人接：①資產加 `nacelleOverhangM`（DB v6）讓 yaw 不靠先驗；②實機拍一張帶 EXIF 的正視照驗整條鏈；③近塔架葉片的合併是另一個問題。

### 2026-09-16 追加：葉片 Mode A 桌面三件（A4／A5／A6）

- **A4 幾何層 cm/px**：Dart 補上 `rotorRadiusM` → 由三片葉長中位數反推尺度；報告的 `tip_deflection_cm` 終於有產生端。只換單位不改判定。
- **A5 偏軸透視夾具**（`blade_prototype/OFFAXIS_SENSITIVITY.md`）：真實照片的 226 cm 假葉尖偏移在合成上**重現**（預彎被投影成彎曲，z 14–30）；
  閘門只擋仰角 ≥ 25°。**待決策**（SPEC §13-11）：雜訊底校準否決、兩個指標不夠，可行的是站位規範 + 報告措辭 + 姿態估計。App 判定未改。
- **A6 葉片線接 `AiBackend`**：與定檢線同一個 `AiRouter`；端側判讀標離線初判、留在補跑佇列、覆核下限是演算法等級。**實機未跑。**
- 三軌：Flutter 588／後端 197／葉片原型 234（§13-11 決策那批後 599／197／249）。

### 2026-09-16 追加：葉片 Mode B 桌面三件（A1／A2／A3）

- **A1 IEA Task 46 分級表**：對原文 §4.3.1 核對，改成 LEP／No-LEP 兩軌，`min_cm_per_px` 由 √面積/15 px 算出；舊版三級共用 0.46 無依據。SPEC §2.2 同步改寫。
- **A2 線性探針落地**：`closeup_features_cnn.py` 是唯一 import torch 的檔案，512 維特徵已進版控；`closeup_probe.py` 不需 torch 也不需語料。平均逐類 recall 0.632（B2 0.308）。
- **A3 §1.2 取像閘門程式化**（`blade_prototype/CLOSEUP_INTAKE_GATE.md`）：前景占比判不出來；改成「Mode A 正視放行 = 硬拒收」+ 探針判 P／W／T，平衡準確率 0.910。
  兩個順帶發現要有人接：①**Mode A 側視規則在 8 張近身照上誤放行**（SPEC §13-13 待決策，Mode A 端未改）；
  ②`closeup_intake_wtb.json` 的 **T 碼混了兩種東西**，30 張 `false_accept` 是複核佇列，不要用模型改標記。
- 環境：本容器現在**有** torch 2.14 CPU 與 Flutter 3.47（前一段「本容器沒有」已過時）；`closeup_intake_gate.py run --dataset` 幾何那層約 30 分鐘。

### 下一步建議（依可行性排序）

1. ~~**合併 PR #69**~~ → 已合併（2026-09-13）；PR #70（健康照第一版）也已合併（2026-09-14）
2. **Mode B 健康候選的人工複核** — 候選與**複核工具都已就位**（見上），差的是人去看。全部仍未複核。B0 量到現有可商用語料 1065 張**一張健康照都沒有**，
   §6 第 4 條的誤報分項統計執行不了。`BLADE_CLOSEUP_TAXONOMY.md` §2 的 12 項正常結構
   就是拍攝清單。這件事**不需要實機也不需要外業**，是目前唯一能純線上推進的葉片工作
3. ~~**B1 評估協定實作**~~ → 已完成（見上）。**B2 的離線基線也做完了**（§3.6，與 1-NN 打平）；
   規格 §8.1／8.2 要 Gemini API key、§8.3 要 PyTorch，**本容器兩樣都沒有**——
   要跑那三條得先給金鑰或給一台裝得了 torch 的機器
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
