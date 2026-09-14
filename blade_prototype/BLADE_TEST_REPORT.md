# 風力機葉片檢測模組 — 現況測試報告（2026-09-14）

> 把葉片模組**現在能測的全部跑一遍**，回答「今天這個模組做到哪、哪裡沒被測到」。
> 不是新的研究：真實影像的數字若與 `REAL_IMAGE_VALIDATION.md` 一致就是沒有退化，不一致就是要查的事。
> 真實影像那一節的每個數字由 `scripts/blade_test_report.py` 從 `results.json` 算出，不手抄；合成端到端的
> 數字取自各指令寫出的 JSON。**重現步驟在 §10。**

| 項目 | 值 |
|---|---|
| 受測版本 | `main` @ `d598da3`（PR #70 合併後） |
| 執行環境 | Linux 容器，4 vCPU / 15 GB；Python 3.11.15、OpenCV 5.0.0、NumPy 2.4.6、SciPy 1.17.1 |
| 環境沒有的 | Flutter SDK（App 端測試引用 CI 結果）、ffmpeg（影片音軌抽取不可用，音軌用 WAV）、Playwright（PDF 改用 chromium headless 直接列印） |
| 語料 | 75 張公開 CC 授權真實風機照片（`data/real_image_labels.json` 標註；影像不進版控）、6 段 Commons CC 授權地面影片、`synth.py` 合成場景 |

---

## 0. 結論（先講）

1. **沒有退化。** 葉片原型 pytest **131/131**、Flutter **497/497**（CI）、死角查核 0 個新的；75 張真實照片**逐張**與 2026-09-07 的結果比對，
   `hub_ok`／葉片數／閘門結論／輪轂誤差 **0 個欄位有差**。設計範圍內輪轂命中 **23/30**（晴空 12/14、有雲 10/13、逆光 1/3），
   閘門放行 **8 張且全部輪轂正確**，範圍外 45 張**誤放行 0**。
2. **四層演算法在合成場景上端到端可用，數字對得上 `SENSITIVITY.md`。** 正視注入 300 cm 葉尖偏移量到 24.8 px（真值 25.0）、z = 16.5；
   12 MP 場景注入 100 cm 量到 20.7 px（真值 20.8）；2 cm 前緣侵蝕的前／後緣 rms 比 **3.09**（健康 0.92）；
   音軌 +4 dB 侵蝕量到 +3.6 dB、z = 4.6 並指對葉片；1800 Hz 哨音突出 13.9 dB 且判為獨有；**風噪 0.5 時正確判「不可用」而且不給任何數字**；
   影片轉速 **11.999 rpm**（真值 12）、六點鐘幀三片都取到。
3. **新發現①：三片互比在真實照片上的假訊號。** 閘門放行的 8 張裡有 **5 張**被三片互比標記離群片，量級大到不可能是缺陷
   （ed894e7a：葉尖偏移 19 px ≈ **226 cm**、z = 12.8）。這 8 張都是別人拍的公開照片，沒有一張站在轉子軸線上——
   是 README 早就寫的「偏軸透視差」，但這是第一次量出它在真實照片上的**發生率**。葉尖方位角間距偏離 120° 這個指標鑑別力不夠
   （有標記者中位 6°、無標記者 2°，但 b78792bf 只偏 3° 也被標）。已列入 `BLADE_INSPECTION_SPEC.md` §13 第 11 項待決。
4. **新發現②：側視全機照會被閘門拒收。** 合成側視照（3000×4000、3.0 cm/px）被 `quality.py` 以「只定位到 2 片」「半徑差 66%」拒收，
   App 端 `blade_capture_gate.dart` 同一組規則。規格 §5.1 的側視模式與閘門互相矛盾；`SENSITIVITY.md` §2 的側視數字是繞過閘門直接算的。
   側視**影片**沒有這個問題（轉速 11.54 rpm、六點鐘幀三片都取到）。§13 第 12 項待決。
5. **圖文報告能出、能列印。** 兩張真實照片各一份、一份合成全層（幾何＋表面＋動態＋聲音）報告，HTML 179–285 KB，
   chromium headless 列印成 PDF 0.8–1.7 MB；報告上「需人工確認」「不輸出合格」的安全語意都在。
6. **沒被測到的還是那幾件**（§9）：真實手機 5x 分區段照（表面層門檻至今只有合成背書）、真實音軌、實機上的 App（Kotlin 抽幀從未編譯）、
   AI 解讀層（這次沒有任何 Gemini 呼叫）、Mode B 的偵測演算法（不存在）。這些不是「測了沒過」，是**沒有輸入可測**。

---

## 1. 測了什麼、怎麼測

| 層 | 測法 | 輸入 | 對照 |
|---|---|---|---|
| 自動化測試 | `pytest`（原型）、CI 工作（Flutter） | 合成夾具、交叉驗證參考值 | 全綠 |
| 分割 + 結構定位 + 閘門 | `scripts/validate_real_images.py` 全語料重跑 | 75 張真實照片 | 逐張比對 2026-09-07 的 `results.json`；`REAL_IMAGE_VALIDATION.md` §5.5 |
| 三片互比（幾何層） | 放行影像的 `comparison_flagged`；合成注入偏移 | 8 張放行真實照；合成正視／側視 | 真值；`SENSITIVITY.md` §1–2 |
| 表面層 | `analyze-edge` | 合成分區段照，健康 vs 2 cm 侵蝕 | `SENSITIVITY.md` §3 |
| 聲音層 | `analyze-audio` | 合成音軌：健康／+4 dB／哨音／強風 | 真值；三重守門 |
| 動態層 | `analyze-video` 正視與側視 | 合成 6 秒影片 | 真值 12 rpm |
| 圖文報告 | `case` | 真實照 ×2、合成全層 ×1 | 目視 + 列印 |
| 運動分割輪轂定位 | `scripts/motion_hub_experiment.py` | 6 段真實影片（設計範圍內或邊緣） | `INNOVATION_REVIEW.md` §3.1 |
| Mode B | 只有分類表與標記檔的守門測試 | — | `CLOSEUP_BASELINE_REPORT.md`、`CLOSEUP_HEALTHY_SET.md` |

---

## 2. 自動化測試

### 2.1 葉片原型（Python）— 144 passed

報告初版量到 131；同日修掉 §8 的第 2、3 項（側視閘門、拒收訊息）各加了測試，現為 144。

| 檔案 | 條數 | 守什麼 |
|---|---|---|
| `test_quality.py` | 27 | 拍攝閘門：地平線、拒收條件、第二個轉子只警告不拒收、**側視另一組規則**、**拒收訊息依葉片數分開** |
| `test_acoustics.py` | 17 | 週期估計、逐片互比、`tonal_exclusive`、三重守門 |
| `test_closeup_taxonomy.py` | 15 | Mode B 分類表單一來源與渲染同步、Mode A 閘門對非 Mode A 照片零放行 |
| `test_segmentation.py` | 12 | 局部天空模型、結構定位 |
| `test_report.py` | 12 | 圖文報告：不出現「合格」、待確認欄、**側視段不出現三片判定** |
| `test_closeup_healthy_set.py` | 11 | Mode B 標記檔：839/185 釘死、沒有人簽核不得 confirmed |
| `test_sunpos.py` | 11 | 太陽方位對 NREL SPA／pvlib |
| `test_geometry.py` | 8 | 三片互比、**側視只報垂掛葉片彎曲** |
| `test_motion_hub.py` | 8 | 運動分割：奇偶幀一致、靜態場景不報轉子 |
| `test_validation_report.py` | 6 | 真實影像驗證報告產生器 |
| `test_surface.py` / `test_blade_test_report.py` | 5 / 5 | 前緣粗糙度；**本報告的聚合腳本**（拒收原因收桶、誤放行要算得出來、逐張比對） |
| `test_dynamics.py` / `test_synth.py` | 4 / 3 | 影片轉速與六點鐘幀、合成場景 |

最慢的是合成影片類：`test_side_view_six_oclock_by_projected_length` 19.0 s、`test_rpm_tracking_and_six_oclock_with_shake` 15.1 s、
`test_motion_hub` 各 6–11 s。整套約 2–3 分鐘。

### 2.2 App 端（Flutter）— 506 passed（本機）

> **報告初版是引用 CI 的 497**（run 34771101372，head `ed31970`）。同日 GitHub Actions 因用量預算暫停，
> 改成在本容器裝 Flutter 3.47.4（與 CI 同版；步驟見 `CLAUDE.md`）本機跑：`flutter test` **506 passed**（約 40 秒）、
> `flutter analyze` 6 條既有 info。多出來的 9 條是側視閘門（7）與拒收訊息（2）。下表的分佈是初版量到的。

其中 `test/blade_*_test.dart` 18 個檔約 **270 條**是葉片模組的
（分析編排 31、語料標記 23、聲學 20、DSP 19、動態 18、幾何互比 17、錄音 17、WAV 解碼 17、抽幀 channel 16、趨勢 15、幾何分割 15、
報告 13、AI 補跑 11、影像運算 10、表面 9、閘門 9、AI prompt 8、報告匯出 4）。表面／幾何／聲音三層與 Python 原型的交叉驗證夾具
（`test/assets/blade_*_reference.json`）是 Dart 端唯一的「對照真值」。

死角查核 `flutter_app/scripts/audit_dead_ends.py`：callers 43 個已列名單、columns 3 個已列名單、**0 個新的**。

---

## 3. 真實影像回歸（75 張）

跑 `validate_real_images.py` 於 set A（45 張，開發集）與 set B（30 張，holdout），再用 `blade_test_report.py` 對 2026-09-07 的輸出逐張比對。
兩組合計 24 秒（1024 px 工作尺度，每張中位 0.3 s）。

### 3.1 數字（`blade_test_report.py` 輸出）

### 全語料摘要

| 項目 | 數值 |
|---|---|
| 影像數（設計範圍內 single ／ 範圍外 multi+none） | 75（30 ／ 45） |
| 輪轂命中（誤差 ≤ 對角線 5%） | 23/30 |
| 三片找齊 | 16/30 |
| 設計範圍內遮罩全空 | 0/30 |
| 閘門放行 | 8（其中輪轂正確 8） |
| 閘門誤放行（範圍外卻放行） | 0 / 45 |
| 範圍外明確失敗（例外或不足三片） | 40/45 |
| 第二個轉子警告 | 23 |
| 每張耗時（中位／合計，1024 px 工作尺度） | 0.3 s ／ 24.1 s |

### 依天空條件（設計範圍內）

| 天空 | 張數 | 輪轂命中 | 三片找齊 | 閘門放行 |
|---|---|---|---|---|
| clear | 14 | 12/14 | 10/14 | 4/14 |
| cloud | 13 | 10/13 | 6/13 | 4/13 |
| backlit | 3 | 1/3 | 0/3 | 0/3 |

### 依集合

| 集合 | 張數 | single | 輪轂命中 | 三片找齊 | 放行 | 誤放行 |
|---|---|---|---|---|---|---|
| A | 45 | 19 | 15/19 | 12/19 | 6 | 0 |
| B | 30 | 11 | 8/11 | 4/11 | 2 | 0 |

### 閘門拒收原因（每張可有多條）

| 原因 | 次數 |
|---|---|
| 只定位到 N 片葉片（應為 N） | 34 |
| 三片葉尖半徑差 N%（上限 N%） | 24 |
| 一片葉片都沒有定位到 | 18 |
| 畫面上幾乎分不出風機（前景僅 N%） | 3 |
| 結構定位失敗（遮罩為空，無法定位結構） | 2 |

（2026-09-14 更新：原本 52 次「只定位到 N 片」裡有 **18 次是 n = 0**，訊息卻與 n = 1/2 共用一句
「可能有葉片貼在塔架上，請等轉子轉開」。訊息已依葉片數分開，見 §8 第 3 項；**拒收與否完全不變**。）

### 與 baseline 逐張比對

baseline 75 張、本次 75 張；有差異的欄位 **0** 個。

### 3.2 解讀

- 23/30、12/14、10/13、1/3、holdout 8/11、遮罩全空 0——與 `REAL_IMAGE_VALIDATION.md` §5.5 完全相同。`segmentation.py` 自 2026-09-07 之後沒有行為改變。
- 範圍外 45 張裡 40 張「明確失敗」，另 5 張安靜給出三葉結構但**全被半徑離散規則擋下**（誤放行 0）。閘門的工作模式與 §4 描述一致：
  半徑離散是唯一有鑑別力的拒收條件。
- 2 張遮罩全空都在範圍外（`fd7d67d4` 嚴重曝光失敗、`8e6a9af9` 山脊遠景多台），範圍內 0 張。
- 逆光 1/3 仍是硬限制，與文件一致；閘門對逆光照片放行 0 張，所以它是「拍不到」不是「量錯」。

### 3.3 三片互比在放行影像上的表現（新量測）

validate 本來就會對三片齊全的影像跑 `compare_blades`（預設雜訊底 1.5 px）並記下哪些指標被標記。這次第一次把它們拿出來看：

| 影像 | 集合 | 天空 | 現場條件 | 葉尖半徑離散 | 間距偏離 120° | 互比標記 |
|---|---|---|---|---|---|---|
| 06a2eac4 | A | clear | 塔架被樹林遮蔽、遠處他機 | 0.061 | 4° | （無） |
| 2c9237a4 | A | cloud | 卷雲、地平線風場列 | 0.135 | 6° | radius_px |
| 309348db | A | clear | 岩石地面 | 0.128 | 16° | radius_px、tip_deflection_px |
| b1632b63 | B | cloud | 陰天、多台同框、前景護欄 | 0.024 | 2° | （無） |
| b78792bf | A | clear | 他機同框、荒原地面 | 0.018 | 3° | tip_deflection_px |
| d526cb66 | A | cloud | 濃積雲、前景欄杆、他機同框 | 0.084 | 17° | radius_px、tip_deflection_px |
| dbc90d73 | B | cloud | 積雲、玉米田 | 0.061 | 2° | （無） |
| ed894e7a | A | clear | 他機同框、荒原地面 | 0.077 | 4° | radius_px、tip_deflection_px |

放行 8 張中互比有標記 **5 張**。這些是公開照片，沒有任何已知缺陷，而標記的量級（下表 ed894e7a：葉尖偏移 226 cm、葉片長度差 −275 cm）
在物理上不可能——同型三片差 2.75 m 長度的風機不會在轉。**這是透視差**：8 張沒有一張站在轉子軸線上（多為仰拍、偏側），
README「已知限制」寫的「偏軸會引入透視差，塔架轉正只能修 roll」在此第一次有了發生率。

葉尖方位角間距偏離 120° 本來想拿來當偏軸指標，結果**鑑別力不夠**：有標記者中位 6°、無標記者 2°，但 b78792bf 只偏 3° 也被標、
309348db 偏 16° 只有兩個指標被標。這一項不能直接進閘門。決策項寫在 `BLADE_INSPECTION_SPEC.md` §13 第 11 項。

### 3.4 兩張真實照片的完整報告（`case`）

| | 06a2eac4（乾淨） | ed894e7a（有標記） |
|---|---|---|
| 尺度 | 反推 31.2 cm/px（轉子半徑假設 40 m） | 反推 11.8 cm/px（假設 41 m） |
| 閘門 | 放行，1 個警告（第二個轉子，半徑 75%） | 放行，0 警告 |
| 互比 | **0/4** 指標標記；葉尖偏移最大 3.9 px（z = 2.6，未過門檻） | **2/4**：葉尖偏移 B 19.2 px ≈ 226 cm z = 12.8；葉片長度 A −23.4 px z = 7.8 |
| 受污染分箱 | 1 | 5（葉片 C） |
| 報告 | 219 KB HTML → 0.8 MB PDF；第二個轉子警告有出現在幾何層段落 | 179 KB HTML → 0.8 MB PDF；檢出項目 3 條、每條有「☐ 待確認」 |

兩份報告的「轉子半徑」都是**示意假設**（寫在現場備註裡），只是為了讓 cm 值能算；公開照片查不到真值。

---

## 4. 合成端到端（四層）

每一層都從 CLI 走完整條路（合成 → 分析 → JSON），不是呼叫函式。這裡驗的是「整條管線接得起來、量到的值對得上注入的真值」，
可偵測門檻本身見 `SENSITIVITY.md`。

### 4.1 幾何層（正視）

| 場景 | 閘門 | 葉片數 | 輪轂誤差 | 注入葉尖偏移 (px) | 量到 (px) | 互比標記 | 耗時 |
|---|---|---|---|---|---|---|---|
| 1200×1600 @ 12 cm/px，健康 | 放行 | 3 | 0.1 px | 0 / 0 / 0 | 0.0 / 0.4 / 0.0 | 無 | 1.6 s |
| 同上，B 注入 300 cm（= 25.0 px） | 放行 | 3 | 1.7 px | 0 / 25.0 / 0 | 0.2 / **24.8** / −0.2 | tip_deflection B，z = **16.5** | 1.5 s |
| 4000×3000 @ 4.8 cm/px（12 MP 橫幅），健康 | 放行 | 3 | 0.1 px | 0 / 0 / 0 | −0.6 / −1.3 / 0.7 | 無 | 7.1 s |
| 同上，B 注入 100 cm（= 20.8 px） | 放行 | 3 | 1.4 px | 0 / 20.8 / 0 | −0.5 / **20.7** / 0.8 | tip_deflection B，z = 13.7 | 7.0 s |

量測誤差 ≤ 0.2 px（1200 px 場景）／≤ 1.3 px（12 MP 場景），與 `SENSITIVITY.md` §1 的雜訊底一致。

### 4.2 幾何層（側視）— **被閘門拒收**

| 場景 | 閘門 | 原因 |
|---|---|---|
| 3000×4000 @ 3.0 cm/px，健康 | **拒收** | 只定位到 2 片葉片；三片葉尖半徑差 66% |
| 同上，C 注入 50 cm | **拒收** | 同上 |

側視時另兩片本來就投影成短段，「葉片數 ≠ 3」與「半徑離散 > 15%」這兩條是為正視寫的規則。結構定位本身有處理側視
（提示「葉片軸線共線（側視），輪轂投影到主葉片軸線」、輪轂誤差 7.9 px），但閘門在互比之前就擋掉了。
`SENSITIVITY.md` §2 側視的 0.5–0.7 px 雜訊底是直接呼叫幾何函式量的，沒經過閘門。App 端 `blade_capture_gate.dart` 是同一組規則，
所以**現在的 App 拍側視全機照一定被拒**。決策項：`BLADE_INSPECTION_SPEC.md` §13 第 12 項。

> **同日已修**（§13-12 決策：側視走另一組閘門規則，判定條件恰好兩片、一上一下、垂直 ±12°、有塔架）。修後同一張合成側視照放行、標成側視、不做三片互比；75 張真實照片的閘門結果逐張 0 個欄位改變（≤12° 沒有一張命中）。

### 4.3 表面層（長焦分區段照，0.4 cm/px）

| 場景 | 上緣（前緣）rms | 下緣 rms | 前／後緣 rms 比 |
|---|---|---|---|
| 健康 | 0.23 px（0.09 cm） | 0.25 px | 0.92 |
| 前緣注入 2 cm 侵蝕 | **0.78 px（0.31 cm）** | 0.25 px | **3.09** |

比值 3.09 落在 App 門檻表（5.0 / 2.0 / 1.5）的 severity 2 區間；後緣不受影響（0.25 → 0.25）。

### 4.4 聲音層（14 s @ 24 kHz，12 rpm，9 次葉片通過）

| 場景 | 可用 | 週期信賴度 | 包絡 SNR | 結果 |
|---|---|---|---|---|
| 健康 | 是 | 0.87 | 5.8 dB | 三片寬頻位準 0 / 0 / 0 dB，無標記 |
| 第 2 片 +4 dB 侵蝕 | 是 | 0.67 | 8.5 dB | 第 2 片 **+3.62 dB**、z = **4.57**，`band_level_db` 與 `high_band_ratio` 都指向第 2 片 |
| 第 3 片 1800 Hz 哨音（振幅 0.02） | 是 | 0.87 | 6.0 dB | 第 3 片 tonal 1804.7 Hz、突出 **13.9 dB**、`tonal_exclusive = true`；另兩片突出量 1.2–1.5 dB |
| 第 2 片 +4 dB，**風噪 0.5** | **否** | 0.20 | 0.9 dB | `blades` 與 `comparisons` **皆為空**，不給數字 |

第四行是三重守門的規格行為（CLAUDE.md：不可用時是空的，不是「全部正常」），這次在 CLI 全路徑上確認。

### 4.5 動態層（合成影片 960×1280、30 fps、6 s、`--step 2` → 90 幀）

| 視角 | 轉速真值 | 量到 | 六點鐘幀 | 三片葉尖半徑 (px) | 耗時 |
|---|---|---|---|---|---|
| 正視 | 12 rpm | **11.999** | A: 35；B: 10, 85；C: 60（4 張 PNG 皆輸出） | 300.36 / 300.16 / 300.23（離群偏差 0.13 px） | 分析 17 s |
| 側視 | 12 rpm | 11.54（−3.8%，由通過間隔推） | A: 10, 86；B: 36；C: 60 | 297.8 / 301.7 / 294.9（偏差 3.9 px） | 分析 18 s |

側視備註如規格所寫：「葉片標籤為通過六點鐘的先後順序，非實際葉片編號」；3 幀輪轂離群以鄰近幀中位數重算。

---

## 5. 圖文報告產生

| 報告 | 內容 | HTML | PDF（chromium headless） |
|---|---|---|---|
| `case_real_clean`（06a2eac4） | 幾何層 | 219 KB | 0.8 MB |
| `case_real_flagged`（ed894e7a） | 幾何層，2 個離群標記 | 179 KB | 0.8 MB |
| `case_synth`（合成全層） | 幾何 + 表面 + 動態（含六點鐘幀）+ 聲音，4 個檢出項目 | 285 KB | 1.7 MB |
| `real_image_validation_2026-09-14`（`make_validation_report.py`） | 75 張驗證的圖文版 | 479 KB | 2.9 MB |

合成全層 `case` 從分析到報告 16.5 s。報告固定聲明「演算法初判，需人工確認」、檢出項目各有「☐ 待確認」、沒有「合格」字樣——
`test_report.py` 守的那幾條在真實輸出上目視確認。

**環境備註**：`make_validation_report.py --pdf` 需要 Python `playwright`，本環境沒有；改用 `/opt/pw-browsers` 的 chromium headless
`--print-to-pdf` 直接列印，同一個 HTML 3 秒出 PDF。這不是程式缺口，寫下來省下一次找。

---

## 6. 運動分割輪轂定位重跑（6 段真實影片，120 幀）

`motion_hub.py` 是 2026-09-12 才改過的（候選選擇改用有效半徑），`INNOVATION_REVIEW.md` §3.1 的表是最後一版程式跑的。重跑對照：

| 片段 | 2026-09-12（§3.1） | 本次 | 一致 |
|---|---|---|---|
| Aerogenerador abla | (677, 185) r=120，主峰比 4.6，奇偶幀差 0 px | (677, 185) r=120，主峰比 4.6，0 px | ✅ |
| Brooklyn Wind Turbine（塔基仰拍，範圍外） | (291, 171) r=180，主峰比 0.9，奇偶幀差 37 px | (291, 171) r=180，0.9，37 px | ✅ |
| Lawrence Weston（480p、快雲） | (142, 168) r=136，主峰比 1.3，11 px | (142, 168) r=136，1.3，11 px | ✅ |
| Masenberg 20240428（斜視） | (540, 145) r=64，主峰比 1.7，0 px | (540, 145) r=64，1.7，0 px | ✅ |
| Parc éolien de Montrigaud（兩台同框） | (276, 210) r=124，主峰比 1.3，0 px | (276, 210) r=124，1.3，0 px | ✅ |
| Windturbines Maasvlakte 2-4（四台同框、3 s） | (540, 204) r=120，主峰比 1.9，0 px | (540, 204) r=120，1.9，0 px | ✅ |

**6/6 逐段一致**：輪轂座標、半徑、主峰比、奇偶幀差全部與 `INNOVATION_REVIEW.md` §3.1 相同（`motion_hub.py` 2026-09-12 之後沒有改動，這是它第一次被重跑確認）。設計範圍內五段（abla、Masenberg、Lawrence Weston、Montrigaud、Maasvlakte 2-4）都定位到主風機輪轂；Brooklyn 是塔基仰拍、相機平移，落在輪轂罩上但奇偶幀差 37 px，與文件寫的「不穩」一致。六段合計 **15 分 45 秒**（每段 120 幀 ORB+RANSAC 穩像 + 時間中位數背景，Masenberg 16 MB 4K 最慢），這個成本是 §13 第 9 項「幾何層要不要改吃影片」要一起考慮的——手機上只會更慢。

---

## 7. Mode B 現況（近身影像）

沒有可跑的偵測管線——**這一節沒有任何準確率數字，因為還沒有東西可以量**。能測的只有語料與分類表的守門（26 條測試，全綠）：

| 項目 | 現況 | 來源 |
|---|---|---|
| 分類表 | 4 機制類 / 17 子類 / 12 正常結構 / 6 品質旗標 / 8 條判定順序；JSON 單一來源，渲染同步有測試 | `BLADE_CLOSEUP_TAXONOMY.md` |
| 可商用語料 | 3 份主力語料只有 figshare Multiclass WTB（CC BY 4.0，1065 張）可商用；DTU v2 是 NC、Blade30 無授權 | `CLOSEUP_BASELINE_REPORT.md` §1 |
| 取像判定 | 839/1065 通過 §1.2；`crack` 類 **0/177** | `CLOSEUP_HEALTHY_SET.md` §2 |
| 尺度 | EXIF 0/200（開放網路）、3/1065（語料）；cm/px 結構性量不到 | `CLOSEUP_BASELINE_REPORT.md` §1 |
| 健康照 | 語料原本 0 張；第一版挖出約 1,200 格候選，**全部 unreviewed** | `CLOSEUP_HEALTHY_SET.md` §4 |
| 正常結構 | 避雷接點／VG／排水孔 0/192；標註痕跡 35% | 同上 §3 |
| 標註一致度 | 兩位標註者類別一致 94.0%（κ 0.897）——任何模型在這份語料上的可量測上限 | `CLOSEUP_BASELINE_REPORT.md` |
| Mode A 閘門對非 Mode A 照片 | 179 張放行 0 張，釘在 `test_mode_a_gate_rejects_everything_out_of_domain` | `test_closeup_taxonomy.py` |

---

## 8. 發現與待決策

| # | 發現 | 證據 | 去哪裡決策 |
|---|---|---|---|
| 1 | 三片互比在真實照片上的假訊號率高（5/8），來源是偏軸透視；間距偏離 120° 不足以當閘門指標 | §3.3 | `BLADE_INSPECTION_SPEC.md` §13-11 |
| 2 | 側視全機照被閘門拒收，規格與實作矛盾；App 端相同 | §4.2 | §13-12 → **同日已修**（側視另走一組閘門規則） |
| 3 | `synth-still` 給的尺度塞不下轉子時（本次 1200×1600 @ 4.8 cm/px，轉子半徑 1250 px）會**靜靜**產出葉尖出框的圖；閘門拒收沒錯，但理由文字是「可能有葉片貼在塔架上」，會把人帶去錯的方向 | 本次測試第一輪 | **同日已修**（訊息依葉片數分開；詳見下方） |

第 3 項是測試設計的錯（`SceneSpec.for_scale()` 才會拒絕塞不下的場景，直接給 `--cm-per-px` 不會），但它暴露的是閘門訊息的問題，所以留下來。

**修法與一個被量測否決的想法**（2026-09-14）。原本想加的規則是「遮罩貼到畫面兩側以上的邊 → 轉子沒有完整入鏡」，
量過之後**不能用**：

| 量的東西 | 塞不下的合成照 | 正確放行的真實照片 | 結論 |
|---|---|---|---|
| 地平線以上左／右邊界的前景占比 | 0.041 / 0.041 | b1632b63 **0.081**（同框他機與雲）、d526cb66 0.025 | 不可分 |
| 葉尖到最近畫面邊界 ÷ 轉子半徑 | — （這張其實是 **0 片葉片**，不是 2 片） | ed894e7a **0.020**、b78792bf 0.034、12 MP 合成照 **0.007** | 不可分 |

真實照片本來就常有一片葉尖切在邊上而量測仍然成立（幾何層沿可見 span 取中心線，三片互比才是判據），
所以任何「靠近邊界就拒收」的規則都會誤攔設計範圍內的案例。

改的是**訊息**：拒收理由依葉片數分開——`n = 0`「一片葉片都沒有定位到：多半是轉子沒有完整入鏡…或風機根本沒被
分割出來」、`n = 1/2` 保留原本的「貼在塔架上／沒入雲層，等轉子轉開」、`n > 3`「畫面裡可能不只一台風機，
或雲塊、電線被當成葉片」。75 張真實照片裡 **18 張是 n = 0**（見 §3.1 表），在此之前全部被告知去等一件不會發生的事。
Python／Dart 同步、各加 2 條測試（釘住 n = 0 的訊息裡**不得**出現「等轉子轉到」）；閘門的**放行與拒收完全不變**
（逐張比對 0 個欄位有差）。

---

## 9. 沒測到的（不是沒過，是沒有輸入）

| 沒測到 | 為什麼 | 需要什麼 |
|---|---|---|
| 表面層在真實照片上 | 75 張公開照沒有一張是手機 5x 的葉片分區段照；門檻 5.0/2.0/1.5 至今只有合成背書 | 一次外業 |
| 聲音層在真實音軌上 | 沒有任何真實風機錄音；三重守門的門檻值沒有現場資料 | 同一次外業（下風處、防風罩） |
| 影片抽幀（Android 原生） | `BladeVideoFrames.kt` 從未被編譯；CI 不建 APK | 一台 Android 實機 |
| App 端整條流程 | 本環境沒有 Flutter SDK，也沒有裝置；Dart 端只有交叉驗證夾具與 497 條單元測試 | 同上 |
| AI 解讀層 | 這次零 Gemini 呼叫；`blade_ai_service.dart` 的 prompt 與值域夾回只有單元測試 | 帶 key 的實機或後端 |
| 跨次趨勢 | 沒有同一台風機的第二個場次 | 兩次外業 |
| Mode B 偵測 | 演算法不存在 | B1 起 |
| 手機上的執行時間 | Python 12 MP 場景 7 s；Dart 端網格中值的實機耗時未量 | 實機 |

---

## 10. 重現

```bash
cd blade_prototype
pytest -q                                                             # 131 passed

# 真實影像（影像不進版控，先抓）
python scripts/fetch_real_images.py --out real_images   --limit 45
python scripts/fetch_real_images.py --out real_images_b --limit 30    # holdout；查詢詞見 REAL_IMAGE_VALIDATION.md §2
python scripts/validate_real_images.py --dir real_images   --out out/A
python scripts/validate_real_images.py --dir real_images_b --out out/B
python scripts/blade_test_report.py --after out/A --after out/B --baseline <上次的 A> --baseline <上次的 B>
python scripts/make_validation_report.py --corpus real_images --corpus real_images_b --after out/A --after out/B --out validation.html

# 合成端到端（§4）
python -m blade_proto synth-still --out s.png --truth s.json --seed 1 --deflection-cm 0,300,0
python -m blade_proto analyze-still s.png --cm-per-px 12 --out s_res.json --overlay s_ov.png
python -m blade_proto synth-segment --out e.png --erosion-cm 2 --seed 2 && python -m blade_proto analyze-edge e.png --cm-per-px 0.4 --le top --out e_res.json
python -m blade_proto synth-audio --out a.wav --erosion-blade 1 --erosion-db 4 --seed 3 && python -m blade_proto analyze-audio a.wav --out a_res.json
python -m blade_proto synth-video --out v.mp4 --seconds 6 --seed 4 && python -m blade_proto analyze-video v.mp4 --step 2 --out v_res.json --frames-dir six/

# 圖文報告（§5）
python -m blade_proto case --asset SYNTH-01 --cm-per-px 12 --edge-cm-per-px 0.4 --le top \
  --still s.png --edge e.png --video v.mp4 --step 2 --audio a.wav --out-dir case_synth/
# 沒有 playwright 時：
/opt/pw-browsers/chromium_headless_shell-*/chrome-linux/headless_shell --headless --no-sandbox --disable-gpu \
  --no-pdf-header-footer --print-to-pdf=report.pdf file://$PWD/case_synth/report.html

# 運動分割（§6；影片來源與授權見 INNOVATION_REVIEW.md §4）
python scripts/motion_hub_experiment.py vids/ out_motion/ --frames 120
```
