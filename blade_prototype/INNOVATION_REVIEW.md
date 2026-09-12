# 葉片檢測模組：改進方向的文獻對照與離線驗證（2026-09-12）

> 目的：回答「葉片檢測還有什麼要改、哪些創新方法值得做」。每個方向都做三件事：
> ①指出它要解的是現況哪個量到的弱點；②找文獻或業界先例證明這條路有人走通過；
> ③能在桌面驗的就先驗（本輪驗了兩項：太陽方位、運動分割）。沒驗的明寫沒驗。
> 結論在 §0，證據在 §2–§4，數字附錄在 §5，來源在 §6。

---

## 0. 結論與建議順序

| 順位 | 方向 | 解的弱點 | 先例 | 本輪驗證 | 工程量 |
|---|---|---|---|---|---|
| 1 | **點一下定錨 + 型錄尺度** | 輪轂命中 23/30；px 值跨次不可比 | 攝影測量以已知尺寸定標是常規；IEA Task 46 的侵蝕分級以 cm² 為門檻，沒有絕對尺度就套不上 | 只算了誤差：點擊 ±5 px → 尺度誤差 0.2–0.5% | 1–2 天 |
| 2 | **太陽方位站位建議** | 逆光是閘門擋不了的硬限制 | NOAA/NREL 太陽位置算法 | ✅ 對 NREL SPA 範例差 0.003°，對 pvlib 全天差 ≤ 0.02°（`sunpos.py`，11 條測試） | 1 天 |
| 3 | **運動分割定位輪轂** | 天空模型是唯一真正的瓶頸（有雲 10/13） | 幀差分是機器視覺量葉片的標準前處理（Zhang & Wei 2024）；影片測速計（Sensors 2020）同一假設 | ✅ 真實地面影片：設計範圍內 5/5 定位到主風機輪轂、奇偶幀差 ≤ 11 px；同樣五段既有天空模型只有 1/5 全對（§3）。合成測試 8 條 | 3–5 天 App 端（Android 抽幀已接） |
| 4 | **沿方位角的剪影互比（相對 pitch）** | 目前只在六點鐘一幀比三片 | Siemens 專利用地面相機從剪影量 pitch 到 ±0.1°；Bertelè 2018 用 1P 諧波抓 ±2° 偏差；Laborelec：>25% 風機至少一片顯著偏差 | 只算了可見度：2.4 cm/px 下每 1° 相對 pitch 約 2 px 投影寬差（§5.2） | 依賴第 3 項；1–2 週 |
| 5 | **留一片的 PatchCore** | Phase 4 卡在健康 patch 為零 | PatchCore（CVPR 2022）在極少樣本下仍穩；三片互比本來就是這個想法的手工版 | 未驗（需要裝置端特徵抽取器） | 2–3 週 + 相依 |
| 6 | **葉片指紋（跨次身分）** | 標籤是通過順序不是實際葉片 | DTU 2024 用 Siamese CNN 以表面特徵認出同一片，「接近人的精度」 | 未驗（需要同一台的第二次場次） | 等資料 |
| 7 | **rpm 當運轉點標準化器** | 跨次聲音趨勢沒有風速沒意義 | 尾緣噪音 ∝ 速度⁵；轉速 ±10% 對應整段頻譜 2–6 dBA；IEC 61400-11 以標準化風速報噪音 | 未驗（轉速已由音軌取得，只差分箱） | 1 天 |
| 8 | **停機模式 + 多幀超解析** | 停機狀態收了沒用；影片幀有運動模糊 | Cornis Panoblade 地面長焦拍停機葉片達 sub-mm，一台 1 小時；Google 手持多幀超解析上限 2× | 只算了模糊量（§5.1） | 1 週 |

**刻意不建議**：地面熱像（US9652839 是 GE 的專利路線，但要專用長焦紅外機，手機熱像百米外解析度不夠）、多手機陣列 beamforming（同步問題）、沿切線的運動模糊反卷積（脆弱）。

---

## 1. 現況真正的弱點（對回數字與程式碼）

| 弱點 | 證據 |
|---|---|
| 輪轂定位仍是瓶頸 | `REAL_IMAGE_VALIDATION.md`：設計範圍內 23/30、有雲 10/13、holdout 8/11；逆光在 SPEC §12 列為「未解，硬限制」 |
| 尺度沒有校正 | `WtAsset.rotorDiameterM` 存了但只在 `blade_inspection_screen.dart` 顯示，沒有任何地方換算 cm/px；表面層 px 值跨次不可比，`blade_trend_service.dart` 只比無因次比值 |
| 葉片沒有身分 | `blade_dynamics_service.dart`／`blade_acoustic_service.dart`：標籤依通過六點鐘的先後循環，並明寫「非實際葉片編號」 |
| 影片只能給剪影 | 葉尖 80 m/s，1/60 s 快門位移 133 cm（§5.1）；六點鐘幀對表面細節無用，現在只用在幾何層是對的 |
| 停機狀態收了沒用 | `WtCaptureSession.turbineState` 寫進 DB，分析層零引用（grep 三個 service 都沒有） |
| 門檻沒有現場資料 | 5.0/2.0/1.5 來自 `SENSITIVITY.md` 合成靈敏度；Phase 4 卡在健康 patch 為零 |

---

## 2. 各方向：主張、先例、邊界

### 2.1 點一下定錨 + 型錄尺度

**主張**：巡檢員在整機照上點輪轂與一個葉尖。輪轂座標成為真值、演算法降為建議；葉尖到輪轂的
px 距離除以 `rotorDiameterM / 2` 就是這張照片的 cm/px。前緣粗糙度從此有絕對 mm 尺度，
px 值跨次可比；同一個尺度也讓 IEA Task 46 的分級套得上（見下）。

**為什麼絕對尺度重要**：IEA Wind Task 46 的前緣侵蝕分級（2023）門檻全是面積：Level 1
「單一實例 ≥ 1 cm² 且 ≤ 10 cm²」、Level 2「≥ 10 cm² 且 ≤ 1 m²」、Level 3「LEP 毀損 ≥ 1 m²」、
Level 4「塗層侵蝕 ≥ 10 cm²；積層侵蝕 ≤ 1 cm²」。報告也直言「損傷**深度**特別難從檢測影像判定」，
而**面積**是影像量得到的——前提是有尺度。同一份報告把地面相機列為與繩索、無人機並列的常規方法。

**誤差**（§5.3）：D=130 m 的轉子在照片上半徑 1500–2600 px，點擊誤差 ±5 px → 尺度誤差 0.2–0.3%；
D=90 m、1100 px → 0.5%。相較之下 5x 長焦 100 m 的 0.75 cm/px 本身就是量測下限，尺度誤差可忽略。

**邊界**：需要資產有 `rotorDiameterM`（型錄值，現場人員建資產時填）；分區段長焦照沒有整個轉子，
尺度要從整機照傳遞（同一場次、同一站位，焦段比已知）。

### 2.2 太陽方位站位建議

**主張**：GPS + 時間 → 太陽方位角與高度角 → 「太陽在你右後方，前緣受光」或「逆光，換到另一個拍攝點」。
規格 §3.2 已經寫「背對太陽拍」，但 App 裡沒有任何東西告訴巡檢員太陽在哪。

**先例**：NOAA 的簡化太陽位置算法（Meeus）與 NREL 的 SPA（Reda & Andreas，±0.0003°）。

**本輪驗證**：`blade_proto/sunpos.py`（純 sin/cos，Dart 移植藍本）
- NREL/TP-560-34302 附錄 A.5 範例（2003-10-17 12:30:30 LST，Golden CO）：天頂角 50.11162° / 方位角
  194.34024°；本實作 50.1086° / 194.3426°，差 **0.003°**。
- 對 pvlib 的 SPA 實作在彰化海岸（24.05°N, 120.42°E）2026-09-12 全天 72 個白天樣本：
  方位角最大差 **0.011°**、高度角最大差 **0.021°**。
- 站位建議只需要幾度的精度，餘裕三個數量級。11 條 pytest。

**邊界**：手機羅盤誤差（± 10–20°）遠大於算法誤差，所以建議的粒度是「左後／右後／換點」而非度數。

### 2.3 運動分割定位輪轂

**主張**：既有分割問「哪些像素不像天空」，雲、光暈、建物都不像天空。影片多一個維度：**時間**。
逐像素時間中位數 = 靜態背景（雲、塔架、機艙、地面都在裡面）；每幀減背景剩下的是在動的東西；
在動的**細長**段的主軸直線只會在輪轂一處共點。

**先例**：
- Zhang & Wei 2024（Sensors）：機艙相機量葉尖淨空，**幀差分**分出葉片、逐列 FFT 追軌跡，對雷射位移
  參考誤差 −0.7 ～ +0.4 m。方法核心與本方向相同（動的才是葉片），只是相機位置不同。
- 影片測速計（Sensors 2020, 20(24):7314）：地面相機比較幀間差異量轉速——同一個「轉子是畫面裡唯一週期運動」的假設。
- Pérez-Gonzalo 等 2023（ICIP）用 U-Net 做野外 RGB 葉片分割達 97.39%——深度學習路線可行但要標註資料，
  本方向零標註。

**本輪驗證**：見 §3（真實地面影片）與 `tests/test_motion_hub.py`（合成影片 8 條：無晃動／手持晃動下輪轂
落在真值 1% 對角線內、穩像估的平移對真值中位差 < 1 px、半徑差 < 8%、奇偶幀一致、靜態場景要說不行）。

**過程中修掉的六個錯**（都記在程式註解，順序就是遇到的順序）：①整張相位相關穩像會被轉子與雲拉走——某幀估出
171 px 假位移，對齊後整張變前景；改 ORB+RANSAC 並對相似變換做「無縮放、轉動 ≤ 3°、平移 ≤ 20%」的合理性檢查，
備援的下半幅相位相關只信回應 ≥ 0.2 且位移 ≤ 5%。②「聯集遮罩最大元件的外輪廓擬合圓」會被相連的雲／地面影子拉歪，
換成細長段共點投票。③**靜態邊緣在殘餘晃動下的閃爍**：塔架垂直線 × 地平線水平線的交點拿到 100 票、真輪轂 104 票；
用背景梯度（元件大半坐在靜態邊緣上就丟）與跨幀同 (θ, ρ) 抑制。④對齊正確時三片葉根在輪轂附近黏成一個 Y 形元件
（細長度 1.7），一條線都取不到——之前會過是因為對不齊的幀「剛好」把它拆開；改成逐幀用距離變換最厚點挖掉再拆臂。
⑤「票數相近取掃過半徑最大」在滿天快雲下選到雲團假中心（佔有率半徑 220 但支持段只到 37 px）；改用有效半徑
= min(佔有率半徑, 1.3 × 支持段最遠點中位數)。⑥第二回合挖掉輪轂圓盤後，候選半徑是在挖過的遮罩上量的，第一回合的
輪轂從第一個環就落空、量成十幾個像素，近台反而輸給遠台；半徑一律在原始遮罩上量。

**邊界**：需要影片（Android 抽幀已接、iOS 未接）；相機要大致對準（穩像處理的是手持晃動不是甩鏡）；
轉子要佔畫面一定比例（§3 遠景風場失敗）；轉子要在轉（停機另走停機模式）。

### 2.4 沿方位角的剪影互比（相對 pitch 偏差、剛度差異）

**主張**：有了逐幀輪轂，就能追每片在整圈的剪影而非只在六點鐘：剪影投影寬度隨方位角的曲線反映
三片的**相對 pitch**；葉尖在十二點與六點的偏折差反映剛度差異。pitch 偏差是轉子不平衡最常見的原因，
地面人員目前完全看不到。

**先例**：
- Siemens 專利 US20110206511A1（2010）：**地面相機**放在塔前 1–3 m、正下方，從葉片肩部剖面的
  三個切點算 pitch，精度 **±0.1°**，轉動中要 ≥ 60 fps 在方位角 270°±3° 取幀。證明 pitch 可從剪影光學量得。
- Bertelè, Bottasso & Cacciola 2018（WES 3:791）：以固定座的 1P 諧波幅值量偏差、相位定位哪一片，
  ±2° 內線性（r > 0.999），3–4 次迭代收斂；認證要求驗 ±0.3°。
- ENGIE Laborelec：500+ 台的 SCADA 分析，**超過 25% 的風機至少一片顯著偏差**。
- Lehnhoff, Gómez González & Seume 2020（WES 5:1411）：地面 DIC 立體相機（25 MP、30 fps）量 SWT-4.0-130
  的葉尖 out-of-plane 偏折與扭轉；要解 0.1° 扭轉需 1.2 mm 的位移解析度——研究級設備。

**可見度估算**（§5.2）：弦 2.5–3.5 m、2.4 cm/px（48 MP 整轉子）下每 1° 相對 pitch 約 1.8–2.5 px 投影寬差。
**能看到 1° 級的相對偏差、看不到 0.3° 的認證級**。Siemens 用塔下近拍換精度，我們用遠拍換整圈覆蓋。

**邊界**：依賴 2.3；要子像素邊緣與多圈平均；未驗。

### 2.5 留一片的 PatchCore

**主張**：Phase 4 卡在「需要 N 次健康場次」。換構造：記憶庫是**同一張照片裡另外兩片**的 patch，
異常分數是到最近 patch 的距離。同一支手機、同一天、同一光線是構造上保證的，零歷史場次也能跑。
rms 比值互比其實已是這個想法的手工特徵版。標記來源照舊是人（`blade_dataset_service.dart` 的三條規則不變）。

**先例**：PatchCore（Roth 等，CVPR 2022）：預訓練 CNN 的 patch 特徵記憶庫 + 最近鄰距離 + coreset 子採樣；
MVTec AD 影像級 AUROC 99.6%，**在極少樣本下仍優於對手**。

**邊界**：要一個裝置端特徵抽取器（TFLite/ONNX，數十 MB）；三片本來就有正常差異（製造公差、汙漬），
門檻要現場校。未驗。

### 2.6 葉片指紋

**主張**：避雷接閃器位置、LEP 帶邊緣、補漆塊、汙漬紋、VG 排列在同一片上跨次不變。對中段裁切做
特徵比對就能給每片穩定身分。

**先例**：Sheiati, Jia, McGugan, Branner & Chen 2024（Eng. Appl. AI 137:109234，DTU）：把「哪一片」從分類
改成相似度學習（Siamese CNN），以表面特徵跨次認出同一片，「接近人類水準的精度」；無人機影像。
配套資料集 2024-DTU Risø（29 段，CC BY 4.0）。

**邊界**：需要 5x 分區段照的紋理（整機照 2.4 cm/px 下沒有可用紋理）；需要同一台的第二次場次才驗得了。

### 2.7 rpm 當運轉點標準化器

**主張**：聲音量跨次比對沒有風速沒意義，但 rpm 已由音軌包絡自相關取得（夾具上差 0.1%），額定功率以下
它是風速的代理。場次依 rpm 分箱後，跨次聲音趨勢不用風速計。

**先例**：尾緣噪音強度 ∝ 流速⁵；轉速 ±10% 對整段頻譜是 2–6 dBA 的差；IEC 61400-11 的噪音量測本來就以
標準化風速報值。額定以下葉尖速比近似常數，轉速與風速線性。業界 Ping Monitor（eologix-ping）以塔基
麥克風長期監測前緣侵蝕、雷擊、裂縫，證明聲學趨勢路線有商業先例。

**邊界**：額定以上 rpm 飽和、pitch 控制介入，分箱失效；只在低於額定的場次間比。

### 2.8 停機模式 + 多幀超解析

**主張**：`turbineState == stopped` 時垂掛那片離地最近、沒有運動模糊；分區段 5x 照可以多幀疊加做超解析。
三片標籤改成物理位置（下／左上／右上）而非通過順序。

**先例**：Cornis Panoblade——地面高解析相機 + 電動雲台，聲稱可追 **sub-mm** 缺陷，onshore 一台 1 小時
（含移動），offshore 2.5 小時。Wronski 等 2019（SIGGRAPH）：手持多幀超解析上限 **2×**，
12 MP 一幀 100 ms 就能在手機上跑。

**邊界**：手機長焦不是專業相機，2× 是上限不是保證；停機要與運維排程配合。

---

## 3. 真實影片實測：運動分割 vs 天空模型

14 段 Wikimedia Commons 影片（1 段 AV1 本機解不了、1 段是動畫只當旁證），每段等距 120 幀、長邊 1024。
「運動法」= `motion_hub.locate_hub`；「顏色法」= 既有 `segment_turbine` + `find_structure` 在同樣的幀裡取 8 幀各跑一次。
沒有人工標註：**奇偶幀差**是兩個獨立子集算出的中心差幾 px（自我一致性），**判讀**欄是對疊圖的肉眼核對。
疊圖（左 = 時間中位數背景，轉子應該消失；右 = 中間幀 + 運動遮罩聯集（黃）+ 運動法輪轂與半徑（綠）+ 顏色法每幀輪轂（洋紅 ×））
與完整 `summary.json` 在 `innovation_review_assets/`：
[abla](innovation_review_assets/abla_overlay.jpg)、[Masenberg](innovation_review_assets/masenberg_overlay.jpg)、
[Lawrence Weston](innovation_review_assets/lawrence_weston_overlay.jpg)、[Montrigaud](innovation_review_assets/montrigaud_overlay.jpg)、
[Maasvlakte 2-4](innovation_review_assets/maasvlakte_4_overlay.jpg)、[Brooklyn](innovation_review_assets/brooklyn_overlay.jpg)。

### 3.1 設計範圍內或邊緣（單台主風機、整個轉子在框內、相機大致不動）

| 片段 | 授權 | 條件 | 穩像 中位/最大位移 | 運動法輪轂 (x, y) r | 奇偶幀差 | 顏色法 8 幀 | 判讀 |
|---|---|---|---|---|---|---|---|
| Aerogenerador abla | CC0 | 有雲、手持微晃、遠處一排風機 | 4/15 px | (677, 185) r=120，主峰比 4.6 | **0 px** | 8/8 一致（離散 8 px），與運動法差 6 px | **兩法皆對**，差 6 px |
| Masenberg 20240428 | CC BY-SA 4.0 | 有雲、**斜視**、樹在風中動、後方兩台 | 2/7 px | (540, 145) r=64，主峰比 1.7 | **0 px** | 8/8 一致（離散 6 px），落在右側**樹梢** | **運動法對、顏色法穩定地錯**（242 px）。斜視時掃過區是橢圓，運動法半徑量到短軸（偏小） |
| Lawrence Weston（480p 轉檔） | CC BY-SA 4.0 | **滿天快雲**、畫面小（270×480） | 8/24 px | (142, 168) r=136，主峰比 1.3 | 11 px | 7/8 落在機艙**下方 70–105 px 的塔身**，1/8 對 | **運動法對、顏色法錯**。這段曾讓「取半徑最大」的規則選到雲團假中心（§2.3 錯誤⑤） |
| Parc éolien de Montrigaud | CC BY 3.0 | 晴空、**兩台同框**（近大遠小） | 4/13 px | (276, 210) r=124，主峰比 1.3 | **0 px** | 2/8 在近台輪轂（對），6/8 跑到遠台且找不到葉片 | **運動法對（選到近台）、顏色法 2/8**。這段是「票數相近取有效半徑最大」規則的來源 |
| Windturbines Maasvlakte 2-4（480p 轉檔，3 s） | CC BY-SA 4.0 | 海邊、**四台同框**、只有 3 秒 | 3/11 px | (540, 204) r=120，主峰比 1.9 | **0 px** | 2/8 在最近那台輪轂（對），6/8 落在沙丘上 | **運動法對、顏色法 2/8**；3 秒就夠 |
| Brooklyn Wind Turbine | CC0 | **塔基仰拍**、葉尖出框、相機平移（76/119 幀對不齊）、快雲 | 55/161 px | (291, 171) r=180，主峰比 0.9 | 37 px | 2/8 在輪轂罩附近，其餘散在塔身（離散 96 px） | 運動法落在輪轂罩上但**不穩**（奇偶幀 37 px）、顏色法 2/8。取景在範圍外，列在這裡是因為它是「手機站塔下拍」最可能出現的樣子 |

**小結**：範圍內五段（abla、Masenberg、Lawrence、Montrigaud、Maasvlakte-4）運動法 **5/5** 定位到主風機輪轂且奇偶幀差 ≤ 11 px；
顏色法完全對的只有 abla **1/5**，另四段是「8 幀彼此一致但一致地錯」或「2/8 對」。
這正是 `REAL_IMAGE_VALIDATION.md` 量到的瓶頸的另一面：天空模型在雲天、樹林、多台同框下不是隨機失敗，是**穩定地把輪轂放在某個不像天空的東西上**，
而單張照片沒有任何東西能告訴它錯了；運動法的奇偶幀一致性本身就是一個可用的信賴度。

### 3.2 設計範圍外（兩法皆不應期待成功，列出來是為了知道邊界在哪）

| 片段 | 授權 | 條件 | 穩像 | 運動法 | 奇偶幀差 | 顏色法 | 判讀 |
|---|---|---|---|---|---|---|---|
| Krnovo Wind farm 08 | CC BY-SA 4.0 | 整個風場遠景、轉子幾十 px、相機平移 | 124/191 px，103/119 幀失敗 | 主峰比 0.9 | 64 px | 離散 197 px | 兩法皆不可用 |
| Wind farm video | CC0 | **無人機**，相機一直在動 | ORB 對齊「成功」但 69% 畫面在動 | 主峰比 0.9 | 175 px | 離散 6 px 但在天上 | 兩法皆不可用；穩像對到了地面卻消不掉視差 |
| Windrad Liftup | CC BY-SA 4.0 | 格構塔、相機沿塔上升 | 21/65 px，52/120 幀失敗 | 主峰比 1.1 | 15 px | 離散 95 px | 兩法皆不可用 |
| Windturbine Maasvlakte 2-3（3 s） | CC BY-SA 4.0 | 近距離直拍，89% 畫面在動 | 5/8 px | 主峰比 1.1 | 122 px | 離散 3 px | 兩法皆不可用 |
| Side of Lawrence Weston（480p） | CC BY-SA 4.0 | **側視**、相機移動（48/120 幀失敗） | 16/52 px | 落在塔基 | 140 px | 兩簇都在機艙附近 | **顏色法較好**；側視不是運動法的幾何（三片近乎共線） |
| Rotating small wind turbine | CC BY 4.0 | 小型風機（桿上） | 2/7 px | 無細長段 | — | 8 幀同一點（離散 0） | 兩法皆無效；不是目標機型 |
| Counter rotating wind turbine | CC BY-SA 4.0 | **動畫**（青色背景） | — | (309, 240) r=248，主峰比 4.3 | 4 px | 一致，差 7 px | 只當旁證：兩法皆對 |

### 3.3 從實測學到的（都已寫進程式）

- **靜態邊緣的閃爍是最大的雜訊源**：穩像殘餘 1–4 px 讓塔架邊緣、地平線、遠處那排風機在每幀閃成細長段，
  各段抑制了 16–7,747 段（abla 2,009、Masenberg 4,429、Montrigaud 4,206）。沒有這一步，塔架 × 地平線的交點與真輪轂票數相當。
- **半徑要對支持它的線段負責**：滿天快雲會把「每個方向都有東西動過」撐到 220 px，但支持雲團假中心的細長段只伸到 37 px。
  有效半徑 = min(佔有率半徑, 1.3 × 支持段最遠點中位數) 之後 Lawrence 回到機艙、Montrigaud 仍選近台。
- **多台同框要靠尺寸不靠票數**：遠處那台線多但短，票數可以跟主風機一樣多；取像規格保證主風機是畫面裡最大的轉子。
- **奇偶幀一致性是免費的信賴度**：範圍內五段 ≤ 11 px，範圍外全部 ≥ 15 px（除 Liftup 的 15）。App 端可以直接用它決定「要不要請人點一下」（§2.1）。
- **斜視的半徑會偏小**（Masenberg 64 px vs 目測約 110）：掃過區是橢圓，角度覆蓋率的判準停在短軸。半徑要拿來當尺度時得先確認是正視，或改擬合橢圓。
- **3 秒就夠**（Maasvlakte-4），但要 ≥ 1 圈：120 幀等距抽樣在 3 秒片段上是 40 fps 的密度，不是問題。

## 4. 驗證方法與語料

- 影片來自 Wikimedia Commons（API 搜尋 + `Category:Videos of wind turbines`），授權 CC0／CC BY 3.0／CC BY 4.0／CC BY-SA 4.0，
  逐段列在 §3 表內。挑選標準只有「畫面裡有在轉的風機」，沒有依結果篩選；無人機、塔架升降、遠景這些一看就在範圍外的
  片段照跑，是為了量邊界。
- 抽幀：等距 120 幀、長邊 1024（與 App 幾何層 `workSide` 一致）。對照組：同樣的幀取 8 幀跑 `segment_turbine` + `find_structure`。
- 沒有人工標註。證據強度＝「奇偶幀兩個獨立子集算出同一個中心」＋「疊圖肉眼可核」（§3 的判讀欄）。
- 四段 AV1 編碼的片段本機 OpenCV 解不了，三段改抓 480p VP9 轉檔（一段沒有轉檔）。
- 這些不是本專案取像規格拍的影片（沒有 48 MP、沒有固定站位、多數不是手機）。它們回答的是「假設成不成立」，
  不是「App 上會有多準」；後者要現場實機。

重跑：
```bash
cd blade_prototype
python scripts/motion_hub_experiment.py <影片目錄> <輸出目錄>   # 疊圖 + summary.json
pytest tests/test_motion_hub.py tests/test_sunpos.py             # 19 條（含 pvlib 比對，沒裝會 skip）
```

---

## 5. 數字附錄

### 5.1 運動模糊：葉尖速度 × 快門 ÷ 尺度

葉尖 80 m/s（onshore 受噪音限制多在 70–80，offshore 80–90+，天花板約 90）。

| 尺度 | 1/60（影片常見） | 1/500 | 1/1000 | 1/4000 |
|---|---|---|---|---|
| 1x 48 MP 整轉子（2.4 cm/px） | 56 px | 7 px | 3 px | 1 px |
| 5x 100 m（0.75 cm/px） | 178 px | 21 px | 11 px | 3 px |
| 5x 六點鐘 50 m（0.37 cm/px） | 360 px | 43 px | 22 px | 5 px |

手機自動曝光在日光下多落在 1/500–1/1000，所以**白天影片幀的模糊是幾個到幾十個像素**，剪影夠、表面不夠；
陰天或傍晚快門變慢，模糊上百像素。這決定了影片只餵幾何層。

### 5.2 相對 pitch 偏差在正視剪影上的可見度

投影寬 ≈ c·sin(局部角)，每 1° 的變化 ≈ c·cos(局部角)·(π/180)：

| 弦長 | 尺度 | 每 1° 投影寬變化 |
|---|---|---|
| 2.5 m | 2.4 cm/px | 1.8 px |
| 3.5 m | 2.4 cm/px | 2.5 px |
| 2.5 m | 4.8 cm/px | 0.9 px |

### 5.3 型錄尺度的誤差

| 轉子直徑 | 照片上半徑 | cm/px | 點擊 ±5 px 的尺度誤差 |
|---|---|---|---|
| 130 m | 1500 px | 4.33 | 0.3% |
| 130 m | 2600 px | 2.50 | 0.2% |
| 90 m | 1100 px | 4.09 | 0.5% |

### 5.4 六點鐘取幀的時間對準

| rpm | 1 s 轉角 | 1/30 s 一幀 | 關鍵幀差 1–2 s |
|---|---|---|---|
| 8 | 48° | 1.6° | 48–96° |
| 12 | 72° | 2.4° | 72–144° |
| 16 | 96° | 3.2° | 96–192° |

（這就是 `BladeVideoFrames.kt` 用 `OPTION_CLOSEST` 不用 `CLOSEST_SYNC` 的理由。）

---

## 6. 來源

**分級與標準**
- IEA Wind TCP Task 46, *Leading Edge Erosion Classification System*, Technical Report, 2023. https://iea-wind.org/wp-content/uploads/2023/02/IEA-Wind-Task-46-Erosion-Classification-System-report.pdf （OSTI: https://www.osti.gov/biblio/2432094）
- DNV-RP-0573, *Evaluation of erosion and delamination for leading edge protection systems of rotor blades*. https://www.dnv.com/energy/standards-guidelines/dnv-rp-0573-evaluation-of-erosion-and-delamination-for-leading-edge-protection-systems-of-rotor-blades/
- IEC 61400-11, *Wind turbines — Acoustic noise measurement techniques*（NREL 摘要：https://docs.nrel.gov/docs/fy06osti/39978.pdf）

**太陽位置**
- Reda, I. & Andreas, A., *Solar Position Algorithm for Solar Radiation Applications*, NREL/TP-560-34302 (rev. 2008). https://docs.nlr.gov/docs/fy08osti/34302.pdf ；線上計算器 https://midcdmz.nrel.gov/spa/

**運動分割／影片量測**
- Zhang, L. & Wei, J., *A Machine Vision Method for Identifying Blade Tip Clearance in Wind Turbines*, Sensors 2024. https://pmc.ncbi.nlm.nih.gov/articles/PMC11435556/
- *Video-Tachometer Methodology for Wind Turbine Rotor Speed Measurement*, Sensors 2020, 20(24):7314. https://doi.org/10.3390/s20247314
- Pérez-Gonzalo, R., Espersen, A. & Agudo, A., *Robust Wind Turbine Blade Segmentation from RGB Images in the Wild*, ICIP 2023. https://arxiv.org/abs/2306.14810
- *Advances in computer vision-based structural health monitoring techniques for wind turbine blades*（綜述，2025）. https://www.sciencedirect.com/science/article/pii/S1364032125007518

**Pitch 偏差／葉片變形**
- Siemens AG, *Wind turbine and method for measuring the pitch angle of a wind turbine rotor blade*, US20110206511A1. https://patents.google.com/patent/US20110206511A1/en
- Bertelè, M., Bottasso, C. L. & Cacciola, S., *Automatic detection and correction of pitch misalignment in wind turbine rotors*, Wind Energ. Sci. 3, 791–803, 2018. https://wes.copernicus.org/articles/3/791/2018/
- ENGIE Laborelec, *Easy detection of wind turbine blade pitch misalignment*. https://www.laborelec.com/services/wind-turbine-blade-pitch-misalignment/
- Lehnhoff, S., Gómez González, A. & Seume, J. R., *Full-scale deformation measurements of a wind turbine rotor in comparison with aeroelastic simulations*, Wind Energ. Sci. 5, 1411–1423, 2020. https://wes.copernicus.org/articles/5/1411/2020/
- *Camera-based portable system for wind turbine blade tip clearance measurement*, IEEE 2013. https://ieeexplore.ieee.org/document/6729740/
- *Assessing the rotor blade deformation and tower–blade tip clearance of a 3.4 MW wind turbine with terrestrial laser scanning*, Wind Energ. Sci. 8, 2023. https://wes.copernicus.org/articles/8/421/2023/

**異常偵測／身分**
- Roth, K. 等, *Towards Total Recall in Industrial Anomaly Detection*（PatchCore）, CVPR 2022. https://arxiv.org/abs/2106.08265
- Sheiati, S., Jia, X., McGugan, M., Branner, K. & Chen, X., *Artificial intelligence-based blade identification in operational wind turbines through similarity analysis aided drone inspection*, Eng. Appl. Artif. Intell. 137:109234, 2024. https://orbit.dtu.dk/en/publications/artificial-intelligence-based-blade-identification-in-operational/ ；資料集 https://data.mendeley.com/datasets/6nzbdvjn87/1

**聲學**
- eologix-ping, *Avoid costly surface damage on wind turbine blades*（Ping Monitor 用例）. https://eologix-ping.com/en/use-case/surface-damage
- *Influence of rotor solidity on trailing edge noise from wind turbine blades*, Adv. Aerodyn. 2020（速度⁵ 尺度律）. https://link.springer.com/article/10.1186/s42774-020-00036-9
- NLR, *Location and quantification of noise sources on a wind turbine*（轉速 ±10% → 2–6 dBA）. https://reports.nlr.nl/server/api/core/bitstreams/bf58b595-a352-49f8-84e6-5b6bfac44839/content

**地面攝影檢測／超解析**
- Cornis, *Panoblade — External Blade Inspection*. https://home.cornis.fr/panoblade/ ；POWER Magazine 報導 https://www.powermag.com/innovative-wind-turbine-blade-inspection-and-maintenance-tools/
- Digital Wind Systems / GE Vernova, *System and method for ground based inspection of wind turbine blades*, US9652839B2（地面長焦熱像，轉動中）. https://patents.google.com/patent/US9652839B2/en
- Wronski, B. 等, *Handheld Multi-Frame Super-Resolution*, ACM TOG 38(4), SIGGRAPH 2019. https://arxiv.org/abs/1905.03277
- Wind Energy — The Facts, *Tip speed trends*. https://www.wind-energy-the-facts.org/tip-speed-trends.html
