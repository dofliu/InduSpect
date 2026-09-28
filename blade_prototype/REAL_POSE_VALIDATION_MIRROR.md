# 真實整機照上的姿態估計與透視補償（Commons）

> 版本 `commons-pose-2026-09-19`。由 `scripts/real_pose_validation.py report` 從 `data/commons_pose_results_mirror.json` 產生，**數字不手抄**；照片本體不進版控（CC BY／BY-SA，來源列在 §6），重跑用 `fetch_commons_turbines.py download` 抓同一份 manifest。

## 0. 一句話

66 張帶 EXIF 焦距、分類在機型頁下的 Commons 整機照：閘門放行 **3**（正視 3、側視 0），姿態可用 **2/3**。正視放行照片的三片互比原始標記葉尖偏移 **1** 張，補償後剩 **1**（消掉 0、留下 1、新增 0）；半徑原始 0 → 補償後 0。預彎擬合落在合理範圍 0/2（中位 — m）。輪轂高度 ±20% 會翻掉補償結論的有 0/2 張。

這些是營運中的風機被路人拍下，先驅上沒有一台葉尖偏了兩公尺——所以原始標記幾乎都是假警報，「補償後剩幾個」是補償的成績、「新增幾個」是代價。**這裡量不到缺陷召回率**，那要有已知缺陷的照片。

## 1. 輸入

| 項目 | 值 |
|---|---|
| 照片來源 | Wikimedia Commons 機型分類頁（`fetch_commons_turbines.py search`），篩 CC／PD 授權 + EXIF `FocalLengthIn35mmFilm` + 寬 ≥ 1600 |
| 分析尺度 | 長邊 1024 px（與 App 相同）；焦距換 px 用縮放後的長邊，所以縮圖不影響 |
| 轉子半徑 | 機型型錄直徑 ÷ 2（manifest `specs`） |
| 輪轂高度 | typical 66（`typical` = 機型常見值，不是那一台的） |
| 相機高度 | 1.6 m（假設手持站立；Commons 照片有些從高處或無人機拍，這時仰角會高估） |
| 機艙 overhang | 5.0 m 預設（yaw 粗估） |
| 雜訊底 | 1.5 px（與 `SENSITIVITY.md` 相同） |
| 每張耗時中位 | 0.29 s |

## 2. 閘門

| 結果 | 張數 |
|---|---|
| 放行（正視） | 3 |
| 放行（側視） | 0 |
| 拒收 | 63 |
| 結構定位丟例外 | 0 |
| 放行但警告畫面裡有第二個轉子 | 2 |

拒收原因（同一張可能多條）：

| 原因 | 次數 |
|---|---|
| 只定位到 N 片葉片（…） | 34 |
| 三片葉尖半徑差 N%（…） | 26 |
| 一片葉片都沒有定位到 | 17 |
| 畫面上幾乎分不出風機（…） | 2 |

## 3. 姿態估計

| 量 | 中位 | 範圍 |
|---|---|---|
| 仰角（°） | 9.2 | [4.81, 13.63] |
| |yaw|（°） | 34.7 | [5.9, 63.57] |
| 距離（m） | 857.4 | [565.96, 1148.88] |

姿態不可用的原因：

| 原因 | 次數 |
|---|---|
| 沒有塔架軸，無法估 yaw | 1 |

## 4. 補償前後

| 指標 | 原始標記 | 補償後標記 | 消掉 | 留下 | 新增 |
|---|---|---|---|---|---|
| 葉尖偏移 | 1 | 1 | 0 | 1 | 0 |
| 半徑 | 0 | 0 | 0 | 0 | 0 |

- 葉尖偏移離群量中位：原始 122 cm → 補償後 376 cm。
- 預彎擬合在 0–8 m 內：0/2，全部範圍 [9.02, 17.55] m。
- 半徑有補償（|yaw| ≤ 15°）：1/2。
- 有葉片落在六點鐘 ±35° 而被點名：1/2。
- 輪轂高度 ×0.8／×1.2：補償標記集合改變 0/2 張，仰角變動中位 1.9°。

### 4.1 逐張（正視放行）

| 照片 | 機型 | 來源 | f35 | 輪轂高 m | 仰角° | yaw° | 距離 m | 葉尖偏移 原始 | 補償後 | 預彎 m | 半徑 原始 | 補償後 | 近塔 | ±20% |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| [c19465951](https://commons.wikimedia.org/?curid=19465951) | Enercon E-126 | model-subcat | 82 | 135.0* | 13.6 | 63.6 | 566 | **+673 cm ⚑** | **+673 cm ⚑** | 9.0 ✗ | -568 cm | -568 cm | — | 穩 |
| [c19156797](https://commons.wikimedia.org/?curid=19156797) | Enercon E-40 | model | 75 | 65.0* | 6.9 | — | 527 | +122 cm | — | — | -93 cm | — | — | — |
| [c5682409](https://commons.wikimedia.org/?curid=5682409) | Enercon E-66 | model | 89 | 98.0* | 4.8 | 5.9 | 1149 | -78 cm | -78 cm | 17.6 ✗ | -303 cm | +112 cm | C | 穩 |

`*` 輪轂高度是機型典型值。⚑ = 三片互比標記（z ≥ 3 且另兩片一致）。「翻」= 輪轂高度 ±20% 時補償後的標記集合會變。

## 5. 每機型

| 機型 | 張數 | 放行 | 正視互比 | 姿態可用 | 葉尖偏移原始標記 | 補償後 |
|---|---|---|---|---|---|---|
| Enercon E-101 | 3 | 0 | 0 | 0 | 0 | 0 |
| Enercon E-126 | 8 | 1 | 1 | 1 | 1 | 1 |
| Enercon E-40 | 16 | 1 | 1 | 0 | 0 | 0 |
| Enercon E-66 | 3 | 1 | 1 | 1 | 0 | 0 |
| Enercon E-70 | 4 | 0 | 0 | 0 | 0 | 0 |
| Enercon E-82 | 25 | 0 | 0 | 0 | 0 | 0 |
| Nordex N117 | 1 | 0 | 0 | 0 | 0 | 0 |
| Nordex N90 | 4 | 0 | 0 | 0 | 0 | 0 |
| Vestas V90 | 2 | 0 | 0 | 0 | 0 | 0 |

### 5.1 每種來源

`model` = 機型分類頁本身；`model-subcat` = 機型分類頁往下的子分類（檔案繼承機型）；`view` = 地區／取景分類頁，機型由檔案自己的分類或描述推斷（`search-view`）。

| 來源 | 張數 | 放行 | 正視互比 | 姿態可用 | 葉尖偏移原始標記 | 補償後 |
|---|---|---|---|---|---|---|
| model | 45 | 2 | 2 | 1 | 0 | 0 |
| model-subcat | 21 | 1 | 1 | 1 | 1 | 1 |

## 6. 來源與授權

照片不進版控。逐張：

| 檔案 | 作者 | 授權 | 相機 | 寬×高（原檔） |
|---|---|---|---|---|
| [c10370423](https://commons.wikimedia.org/?curid=10370423) File:Windkraftanlage Ammerfeld.jpg | Chaddy | CC BY-SA 3.0 | DMC-FX12 | 3072×2304 |
| [c10370483](https://commons.wikimedia.org/?curid=10370483) File:Windkraftanlage Ammerfeld 2.jpg | Chaddy | CC BY-SA 3.0 | DMC-FX12 | 2500×1807 |
| [c12316615](https://commons.wikimedia.org/?curid=12316615) File:Windkraftanlage Grüner Heiner.jpg | Harke | CC BY-SA 3.0 | NIKON D60 | 2431×3633 |
| [c12853508](https://commons.wikimedia.org/?curid=12853508) File:Hau Nui Wind Farm stage 1 from Range Road.JPG | Lcmortensen | CC BY-SA 3.0 | <KENOX S860  / Samsung S860> | 3264×2448 |
| [c12869944](https://commons.wikimedia.org/?curid=12869944) File:Mellerhoefe windkraft 09.jpg | Achim Raschka  (  talk  ) | CC BY-SA 4.0 | NIKON D40 | 3008×2000 |
| [c12869957](https://commons.wikimedia.org/?curid=12869957) File:Mellerhoefe windkraft 10.jpg | Achim Raschka  (  talk  ) | CC BY-SA 4.0 | NIKON D40 | 3008×2000 |
| [c16043004](https://commons.wikimedia.org/?curid=16043004) File:Windpark Vetschau 1.jpg | Peter Tritthart | CC BY 3.0 | DMC-TZ3 | 1872×3328 |
| [c16282953](https://commons.wikimedia.org/?curid=16282953) File:The Sprogø Vindmølle Park.jpg | Fxp42 | CC BY-SA 3.0 | DMC-FZ7 | 2744×1791 |
| [c16365752](https://commons.wikimedia.org/?curid=16365752) File:Luftaufnahmen Nordseekueste 2011-09-04 by-RaBoe-103.jpg | ©  Ra Boe / Wikipedia         Create the | CC BY-SA 3.0 de | NIKON D50 | 3008×2000 |
| [c16853637](https://commons.wikimedia.org/?curid=16853637) File:WKAIngersheimFundament 2011-10-03.jpg | Mussklprozz | CC BY-SA 3.0 | NIKON D90 | 3958×2530 |
| [c16966823](https://commons.wikimedia.org/?curid=16966823) File:WKAIngersheimSockel 2010-10-09.jpg | Mussklprozz | CC BY-SA 3.0 | NIKON D90 | 4288×2650 |
| [c17175040](https://commons.wikimedia.org/?curid=17175040) File:WKAIngersheimSockel 2011-10-30.jpg | Mussklprozz | CC BY-SA 3.0 | NIKON D90 | 4288×2650 |
| [c17176533](https://commons.wikimedia.org/?curid=17176533) File:Nordex N-90 Windkraftanlage.jpg | Joseph-Evan-Capelli | CC BY-SA 3.0 | NIKON D90 | 4288×2848 |
| [c18133307](https://commons.wikimedia.org/?curid=18133307) File:Enercon E66.jpg | Joseph-Evan-Capelli | CC BY-SA 3.0 | NIKON D90 | 2848×4288 |
| [c18167022](https://commons.wikimedia.org/?curid=18167022) File:WKAIngersheimKraene 2012-01-25.jpg | Mussklprozz | CC BY-SA 3.0 | NIKON D90 | 3680×2868 |
| [c18175573](https://commons.wikimedia.org/?curid=18175573) File:WKAIngersheimGrosserMontagekran 2012-01-26.jpg | Mussklprozz | CC BY-SA 3.0 | NIKON D90 | 2868×4310 |
| [c18210923](https://commons.wikimedia.org/?curid=18210923) File:Size comparison child in wind turbine rotor hub without | Erik Streb | CC BY-SA 3.0 | NIKON D80 | 1936×1296 |
| [c18211537](https://commons.wikimedia.org/?curid=18211537) File:Size comparison child and wind turbine tower parts (ene | Erik Streb | CC BY-SA 3.0 | NIKON D80 | 1936×1296 |
| [c18539718](https://commons.wikimedia.org/?curid=18539718) File:WKAIngersheimSchaft 2012-02.jpg | Mussklprozz | CC BY-SA 3.0 | NIKON D90 | 2824×3976 |
| [c18597486](https://commons.wikimedia.org/?curid=18597486) File:Średnica Jakubowięta - turbina wiatrowa.JPG | Adam-dalekie-pole | CC BY-SA 3.0 | KODAK Z885 ZOOM DIGITAL CAMERA | 2448×3264 |
| [c18633412](https://commons.wikimedia.org/?curid=18633412) File:WKAIngersheimSchaft 2012-03-08.jpg | Mussklprozz | CC BY-SA 3.0 | NIKON D90 | 2534×4100 |
| [c18703446](https://commons.wikimedia.org/?curid=18703446) File:WKAIngersheimMontageGeneratorgondel.jpg | Mussklprozz | CC BY-SA 3.0 | NIKON D90 | 2853×4288 |
| [c18712576](https://commons.wikimedia.org/?curid=18712576) File:WKAIngersheimMontageFluegel.jpg | Mussklprozz | CC BY-SA 3.0 | NIKON D90 | 2650×4310 |
| [c19002876](https://commons.wikimedia.org/?curid=19002876) File:Wind turbine with observation deck bruck an der leitha. | KoeppiK | CC BY-SA 3.0 | NIKON D80 | 2592×3872 |
| [c19156793](https://commons.wikimedia.org/?curid=19156793) File:Friedrichsgabekoog schafe haus windraeder 01.04.2012 15 | Dirk Ingo Franke | CC BY 3.0 | PENTAX K20D | 2050×1367 |
| [c19156797](https://commons.wikimedia.org/?curid=19156797) File:Friedrichsgabekoog schafe vor windrädern 01.04.2012 15- | Dirk Ingo Franke | CC BY 3.0 | PENTAX K20D | 2475×1650 |
| [c19326536](https://commons.wikimedia.org/?curid=19326536) File:Göslow Enercon E-101.JPG | Erell | CC BY-SA 3.0 | DMC-FZ150 | 3000×4000 |
| [c19465951](https://commons.wikimedia.org/?curid=19465951) File:Windraeder suedlich von Hamburg 09.05.2012 17-46-026.jp | Dirk Ingo Franke | CC BY 3.0 | PENTAX K20D | 4672×3104 |
| [c19637139](https://commons.wikimedia.org/?curid=19637139) File:Nordex N90.JPG | Joseph-Evan-Capelli | CC BY-SA 3.0 | NIKON D90 | 2848×4288 |
| [c19637258](https://commons.wikimedia.org/?curid=19637258) File:Sonnenuntergang am Pfingstmontag.JPG | Joseph-Evan-Capelli | CC BY-SA 3.0 | NIKON D90 | 4288×2848 |
| [c19669637](https://commons.wikimedia.org/?curid=19669637) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9347.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 4256×2848 |
| [c19673740](https://commons.wikimedia.org/?curid=19673740) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9514.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 2848×4256 |
| [c19673765](https://commons.wikimedia.org/?curid=19673765) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9517.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 2848×4256 |
| [c19673776](https://commons.wikimedia.org/?curid=19673776) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9518.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 2848×4256 |
| [c19673781](https://commons.wikimedia.org/?curid=19673781) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9519.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 2848×4256 |
| [c19673819](https://commons.wikimedia.org/?curid=19673819) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9527.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 2848×4256 |
| [c19673825](https://commons.wikimedia.org/?curid=19673825) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9530.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 2848×4256 |
| [c19673832](https://commons.wikimedia.org/?curid=19673832) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9531.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 2848×4256 |
| [c19673837](https://commons.wikimedia.org/?curid=19673837) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9532.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 2848×4256 |
| [c19673844](https://commons.wikimedia.org/?curid=19673844) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9533.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 2848×4256 |
| [c19674205](https://commons.wikimedia.org/?curid=19674205) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9604.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 4256×2848 |
| [c19674208](https://commons.wikimedia.org/?curid=19674208) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9605.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 4256×2848 |
| [c19674213](https://commons.wikimedia.org/?curid=19674213) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9606.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 4256×2848 |
| [c19932839](https://commons.wikimedia.org/?curid=19932839) File:Windpark-Neuerkirch00.jpg | Prankster | CC0 | NIKON D40 | 3008×2000 |
| [c20562709](https://commons.wikimedia.org/?curid=20562709) File:Windpark-06-04-2012-3.jpg | Wblecker | CC BY-SA 3.0 | DMC-FZ45 | 2880×4320 |
| [c20885155](https://commons.wikimedia.org/?curid=20885155) File:Pala eolica Mele 01.jpg | Alessio Sbarbaro  User_talk:Yoggysot | CC BY-SA 3.0 | PENTACON Dpix 1100Z | 2448×3264 |
| [c21367677](https://commons.wikimedia.org/?curid=21367677) File:Pala eolica Mele 12.jpg | Alessio Sbarbaro  User_talk:Yoggysot | CC BY-SA 3.0 | PENTACON Dpix 1100Z | 2448×3264 |
| [c21685144](https://commons.wikimedia.org/?curid=21685144) File:WKA Ingersheim 2012-09.jpg | Mussklprozz | CC BY-SA 3.0 | NIKON D90 | 2650×4288 |
| [c21695566](https://commons.wikimedia.org/?curid=21695566) File:Umspannwerk Präbichl-4.jpg | Brezocnik Michael | CC BY-SA 3.0 at | NIKON D80 | 3801×2557 |
| [c21695568](https://commons.wikimedia.org/?curid=21695568) File:Umspannwerk Präbichl-2.jpg | Brezocnik Michael | CC BY-SA 3.0 at | NIKON D80 | 2592×3872 |
| [c21695570](https://commons.wikimedia.org/?curid=21695570) File:Umspannwerk Präbichl-3.jpg | Brezocnik Michael | CC BY-SA 3.0 at | NIKON D80 | 3872×2592 |
| [c22433382](https://commons.wikimedia.org/?curid=22433382) File:Windpark-Külz02.jpg | Prankster | CC0 | NIKON D40 | 3008×2000 |
| [c22433410](https://commons.wikimedia.org/?curid=22433410) File:Windpark-Külz03.jpg | Prankster | CC0 | NIKON D40 | 3008×2000 |
| [c3962001](https://commons.wikimedia.org/?curid=3962001) File:Palmas 01.jpg | Herr stahlhoefer | Public domain | COOLPIX L4 | 1704×2272 |
| [c3962018](https://commons.wikimedia.org/?curid=3962018) File:Palmas 03.jpg | Herr stahlhoefer | Public domain | COOLPIX L4 | 2272×1704 |
| [c3962063](https://commons.wikimedia.org/?curid=3962063) File:Palmas 06.jpg | Herr stahlhoefer | Public domain | COOLPIX L4 | 1704×2272 |
| [c5682409](https://commons.wikimedia.org/?curid=5682409) File:Hoheward-DSCI0492.jpg | Rainer Halama | CC BY 3.0 | DigitalCAM | 3072×2304 |
| [c6326631](https://commons.wikimedia.org/?curid=6326631) File:Enercon-P1130626.JPG | Gunnar Ries  Amphibol | CC BY-SA 3.0 | DMC-FZ50 | 3648×2736 |
| [c6326636](https://commons.wikimedia.org/?curid=6326636) File:Enercon-P1130627.JPG | Gunnar Ries  Amphibol | CC BY-SA 3.0 | DMC-FZ50 | 3648×2736 |
| [c6560678](https://commons.wikimedia.org/?curid=6560678) File:Wuppertal Wilhelmring 0004.jpg | Atamari | CC BY-SA 3.0 | KODAK DX4330 DIGITAL CAMERA | 2160×1440 |
| [c6566190](https://commons.wikimedia.org/?curid=6566190) File:WindTurbine Rotor Winglet unmounted.JPG | TraceyR | CC BY-SA 3.0 | EX-Z1080    | 3648×2432 |
| [c6566413](https://commons.wikimedia.org/?curid=6566413) File:WindTurbine Rotor Winglet unmounted 2.JPG | TraceyR | CC BY-SA 3.0 | EX-Z1080    | 3648×2432 |
| [c6566536](https://commons.wikimedia.org/?curid=6566536) File:WindTurbine Rotor Winglets unmounted.jpg | TraceyR | CC BY-SA 3.0 | EX-Z1080    | 3648×2432 |
| [c6914141](https://commons.wikimedia.org/?curid=6914141) File:Enercon E-126 Aurich-Georgsfeld02.jpg | Prankster | Public domain | NIKON D40 | 3008×2000 |
| [c8384905](https://commons.wikimedia.org/?curid=8384905) File:DE 049 010 20091109004806 001 Enercon.jpg | E4L EnergyMap | CC BY-SA 3.0 | DiMAGE X50 | 1920×2560 |
| [c8836086](https://commons.wikimedia.org/?curid=8836086) File:Aerials Bavaria 16.06.2006 12-22-43.jpg | Hansueli Krapf | CC BY-SA 3.0 | E8800 | 2048×1536 |
