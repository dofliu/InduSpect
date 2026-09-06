# blade_prototype — 風力機葉片地面目視檢測演算法原型

`BLADE_INSPECTION_SPEC.md` §5.1–5.4 的 Python / OpenCV 參考實作，用途：

1. **外業前**：用合成影像量化「在什麼尺度能分辨多大的異常」（`sensitivity`），決定拍攝協定。
2. **外業後**：直接跑真實照片與影片，回答 Phase 0 的「能做到哪」。
3. **Phase 1+**：Dart 移植的對照實作（演算法全部是 numpy / OpenCV 基本運算，無深度學習）。

## 安裝

```bash
cd blade_prototype
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
pytest            # 46 tests，約 3 分鐘（聲學測試較慢）
```

## 三種輸入、三個指令

| 拍什麼 | 指令 | 回答什麼 |
|---|---|---|
| 全機靜態照（正視或側視，轉子完整入鏡） | `analyze-still` | 輪轂/塔架/三片葉片定位、每片彎曲係數、**三片互比**是否有離群片 |
| 長焦分區段照（一段葉片橫越畫面） | `analyze-edge` | 上下兩條邊緣的粗糙度：rms、往內凹 p95、凹坑數、分 zone；前緣/後緣比 |
| 轉動影片（20–30 秒，正視或側視） | `analyze-video` | 轉速、三片葉尖半徑一致性、每片**六點鐘幀**索引（可輸出 PNG 進 `analyze-still`） |
| 影片音軌（或另錄 WAV） | `analyze-audio` | **哪一片在叫**：逐片寬頻噪音位準（前緣侵蝕）、窄頻哨音（後緣裂縫）、風噪可用性判斷 |
| 以上任意組合 | `case` | 一次跑完並產生**圖文報告**（單一 HTML，含疊圖照片、圖表、數值表、待確認欄） |

```bash
python -m blade_proto analyze-still  IMG_1234.JPG --rotor-radius-m 60 --out r.json --overlay o.png
python -m blade_proto analyze-edge   IMG_1240.JPG --cm-per-px 0.4 --le top --out e.json
python -m blade_proto analyze-video  VID_0001.MP4 --step 2 --out v.json --frames-dir six/
python -m blade_proto analyze-audio  VID_0001.MP4 --rpm 12 --out a.json     # 影片音軌需 ffmpeg
```

## 圖文報告

一個指令跑完一次拍攝作業並產出可交付的報告：

```bash
python -m blade_proto case --asset WTG-07 --site "彰濱風場" --state stopped \
  --captured-at "2026-09-20 09:40" --inspector "王大明" --weather "北風 5 m/s，晴" \
  --still IMG_1234.JPG --cm-per-px 4.8 --rotor-radius-m 60 --noise-floor-px 1.2 \
  --edge IMG_1240.JPG --edge-cm-per-px 0.4 --le top \
  --video VID_0001.MP4 --view side --step 2 \
  --out-dir cases/WTG-07-0920/
# → cases/WTG-07-0920/report.html（含 still/edge/video.json、疊圖、六點鐘幀）
```

不想重跑分析、只要重排報告時用 `report`（吃既有 JSON）：

```bash
python -m blade_proto report --asset WTG-07 --still still.json --still-overlay still_overlay.png \
  --edge edge.json --edge-overlay seg.png --video video.json --six-dir six/ --out report.html
```

報告特性：

- **單一自帶內容 HTML**：照片內嵌成 base64、圖表是內嵌 SVG、CSS 內嵌、**零 JavaScript**。
  可離線開啟、可直接 email，瀏覽器列印即成 PDF（實測 A4 約 8 頁、1.2 MB）。
- **圖表**：三片中心線側向偏移（折線）、各片葉尖偏移（直條，附 3σ 門檻線）、
  前緣粗糙度分段（直條）、三片葉尖半徑（直條）、各片寬頻噪音位準（直條）、
  各片通過時的平均頻譜（折線，侵蝕看整體平移、哨音看單片細峰）。滑過任一記號有原生 tooltip；
  每張圖旁都有對應的數值表（圖表的資料檢視）。
- **安全語意**：固定聲明「演算法初判，需人工確認」，異常列有「☐ 待確認」欄，
  **報告不會出現「合格」字樣**——沒偵測到異常不等於沒有異常。
- 淺色/深色主題自動切換；列印強制淺底黑字。

`case` 的 `--asset/--site/--state/--inspector/...` 對應規格 §7 的 `wt_capture_sessions` 欄位，
日後 App 化時同一組 metadata 直接進 SQLite。

`--cm-per-px` 不知道時給 `--rotor-radius-m`，程式以量到的葉片像素長度反推尺度。
分割失敗時可用 `--hub x,y` 手動指定輪轂（座標用任何看圖軟體讀）、`--dist-thresh` 調天空門檻。

## 演算法摘要

| 模組 | 方法 | 對應規格 |
|---|---|---|
| `segmentation.py` | 天空模型：畫面兩側窄帶每列中位數 → 對列位置做 robust 多項式（處理天空漸層）；Lab 空間距離 > 5.5σ 為前景（距離圖先 σ0.8 平滑，保住 1–2 px 的葉尖）。結構：**塔架優先**——從遮罩下方 30% 找最垂直的連續段軌跡得塔軸，沿軸往上走到「臂數 ≥ 3 的連續區段最上端」即輪轂/機艙（臂數 = 與該點連通的遮罩與取樣圓的交叉次數；輪轂 3–4、塔架 2）；找不到塔架時退回距離變換局部極大值 + 臂數。之後移除輪轂圓盤、沿塔軸帶切出塔架（雲塊橋接葉片與塔架時仍分得開）、其餘連通元件用對輪轂的角度直方圖拆臂 → 葉片內段軸線最小平方交點精修輪轂（側視共線時改投影到主葉片軸） | §5.1 |
| `geometry.py` | 每片：以輪轂為原點、塔架轉正、PCA 主軸、沿 span 分 48 箱取兩側邊緣中點 = 中心線；弦寬對 span 做 robust 擬合找出被雲塊/附著物污染的分箱，以擬合值修補偏離較大的那側邊緣（`n_contaminated_bins`）；二次擬合係數 a2 = 彎曲係數（軸吸收一次項，對軸傾斜不敏感）；`tip_deflection_px = a2·R`。三片互比：離中位數最遠者為離群，z = 偏差 / 雜訊底，並要求偏差 ≥ 2× 另兩片彼此差 | §5.3 |
| `surface.py` | 葉片轉水平 → 每欄上下邊緣 → 灰階半高交叉 sub-pixel → robust 三次多項式基線 → 殘差：rms、往內凹 p95、凹坑（連續 ≥2 欄 > 2.5σ）、高頻能量比、三 zone；邊內帶狀區局部灰階 std = 紋理 | §5.2 |
| `dynamics.py` | 正視：每幀分割 + 結構 → 葉尖 (角度, 半徑) → 角度連續性配到三條軌跡（缺測用角速度預測補）→ 展開角度回歸得轉速 → \|角度−270°\| 局部極小 = 六點鐘幀（葉片被塔架遮住，為內插值）→ 三片半徑中位數互比。側視（`--view side`）：三葉尖共線、角度無意義，改追蹤向下葉片的投影長度，局部極大 + 拋物線精修 = 六點鐘幀，相鄰通過間隔 = 1/3 圈得轉速。兩者皆有線上輪轂中位數濾波處理離群幀 | §5.4 |
| `acoustics.py` | 音軌 → STFT → 分析頻帶包絡；包絡自相關求轉子/葉片通過週期（含諧波歧義判別）、定相位切成三片；逐片平均頻譜 → 寬頻位準（方向性互比）與窄頻峰突出量（僅單片出現才算哨音）；風噪與訊噪比可用性守門 | §5.4 音軌 |
| `report.py` / `charts.py` | 圖文報告：把數值排成 HTML（區段、統計磚、數值表、待確認欄）＋內嵌 SVG 圖表。無外部相依、無 JS；照片以 base64 內嵌 | 交付物 |
| `synth.py` | 參數化風機（60 m 葉片、4 m 根弦、塔架、機艙、預彎），正視/側視/分區段/影片；`SceneSpec.for_scale()` 依感光元件像素數與 cm/px 建場景，轉子塞不進畫面會拒絕 | 測試夾具 |

原則：**數字由演算法算，AI 只解讀**。這裡沒有任何 AI 呼叫；候選裁切送 Gemini 的那一段在 App 端（規格 §6）。

## 靈敏度分析

```bash
python -m blade_proto sensitivity --quick --out SENSITIVITY.md   # ~3 分鐘
python -m blade_proto sensitivity --out SENSITIVITY.md           # ~10 分鐘，含 48 MP
```

結果見 `SENSITIVITY.md`。重點結論：

- **整轉子幾何靠主鏡頭高像素模式，不靠長焦**。12 MP 橫幅要 ≥ 4.8 cm/px（1x 約 130 m）轉子才塞得進畫面；此時 50 cm 葉尖偏移 ≈ 10 px，雜訊底約 1 px，可分辨。48 MP 全解析再好一倍。這修正了規格 §3.1 表格「3.7 cm/px 看整轉子」的假設——3.7 cm/px 下 120 m 轉子是 3243 px，塞不進 3000 px 高的橫幅。
- **側視垂掛葉片**用直幅，12 MP 在 2.5–3.5 cm/px 可用，單幀彎曲量測雜訊約 1 px：50 cm 可分辨、25 cm 邊緣。
- **前緣侵蝕**：5x 長焦在 50 m（0.37 cm/px）1 cm 深凹坑可分辨；1x 在 100 m 要 10 cm 級。
- **音軌**：+3 dB 的逐片寬頻差異可標記並指對葉片（+2 dB 抓不到）；哨音振幅 0.01 可抓。
  風噪是主要限制：包絡訊噪比掉到約 2 dB 時同樣的缺陷被雜訊底抑制而漏判（不是誤判）。

## 外業流程（對應規格 §10）

1. 到定點，先拍一張 1x 全機橫幅 + 一張 1x 直幅（含塔基），再切 5x 光學拍分區段。**用原生相機 App、關數位變焦、存最高畫質**。
2. 轉動中拍 30 秒 4K 影片，手持可以，盡量以塔架為畫面中心。**錄影時站下風處、麥克風加防風罩**
   （聲音層對風噪極敏感），並記下當時風速；至少涵蓋 3 圈（12 rpm 約 15 秒）。
3. 回來先跑 `analyze-video --frames-dir six/` 取六點鐘幀，再對這些幀跑 `analyze-still`，把三片的 `tip_deflection_px` 放進 `compare_blades`。
4. 對同一片同一區段的連拍 5 張跑 `analyze-edge`，量測值的 std 就是**現場雜訊底**，拿來取代 `--noise-floor-px` 的預設 1.5。
5. 音軌先跑 `analyze-audio --rpm <影片得到的轉速>`；若回報不可用，記下當時風速，
   這就是「現場能不能用聲音層」的第一手答案。

## 已知限制（外業要驗的就是這些）

- **天空模型只用畫面邊緣**：塔基背景是地面/樹時，塔架下段會分割失敗，「塔架優先」的輪轂初估會退回臂數法。白雲背景下的白葉片（低對比）是最弱環節，必要時 `--dist-thresh 4`。
- **雲塊黏在葉片邊緣**：色彩分割分不開白雲與白葉片，黏上去會讓該片弦寬暴增、中心線拉歪。幾何層會修補離群分箱並回報 `n_contaminated_bins`，> 0 的幀應降權或重拍；這是外業最該量化的失效模式。
- **正視時葉片在六點鐘 ±20° 會與塔架合併**：拍攝協定應避免（Y 字型停機），影片模式已用預測補缺測。
- 三片互比假設相機在轉子軸線上；偏軸會引入透視差，用塔架轉正只能修 roll。側視、影片六點鐘取幀不受此限。
- 影片每幀約 0.1–0.2 秒（960 px），30 秒 4K 建議 `--step 2`。
- **側視葉尖長度只採真實偵測**：偵測有缺口的通過（向下葉片被遮住或分割失敗）會回報
  「不可用」而非內插值——早期版本用平滑後的內插值當量測，會憑空生出 25% 的假差異。
  報告中該片顯示「—」，並在演算法備註說明。
- **聲音層的葉片標籤是「通過順序」，不是實際葉片編號**：單靠音軌只能說「三片中的某一片」。
  要對上實際編號需搭配影片的六點鐘時刻（`analyze-samples(pass_times_hint=...)`，
  `case` 尚未自動串接——影片與音軌的時間基準對齊要在外業確認錄影是同一段）。
- **1P/3P 不對稱只是描述量**：健康與單片缺陷的值域重疊（見 SENSITIVITY.md §4），
  不能當判定門檻；可靠的判別是逐片位準互比。
- 尚未實作：健康樣本異常偵測（Phase 2）、跨次基線比對（需資料模型）。
