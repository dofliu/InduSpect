# 真實整機照上的姿態估計與透視補償（Commons）

> 版本 `commons-pose-2026-09-19`。由 `scripts/real_pose_validation.py report` 從 `data/commons_pose_results.json` 產生，**數字不手抄**；照片本體不進版控（CC BY／BY-SA，來源列在 §6），重跑用 `fetch_commons_turbines.py download` 抓同一份 manifest。

## 0. 一句話

45 張帶 EXIF 焦距、分類在機型頁下的 Commons 整機照：閘門放行 **5**（正視 3、側視 2），姿態可用 **3/3**。正視放行照片的三片互比原始標記葉尖偏移 **1** 張，補償後剩 **1**（消掉 0、留下 1、新增 0）；半徑原始 1 → 補償後 1。預彎擬合落在合理範圍 1/3（中位 5.2 m）。輪轂高度 ±20% 會翻掉補償結論的有 0/3 張。

這些是營運中的風機被路人拍下，先驅上沒有一台葉尖偏了兩公尺——所以原始標記幾乎都是假警報，「補償後剩幾個」是補償的成績、「新增幾個」是代價。**這裡量不到缺陷召回率**，那要有已知缺陷的照片。

## 1. 輸入

| 項目 | 值 |
|---|---|
| 照片來源 | Wikimedia Commons 機型分類頁（`fetch_commons_turbines.py search`），篩 CC／PD 授權 + EXIF `FocalLengthIn35mmFilm` + 寬 ≥ 1600 |
| 分析尺度 | 長邊 1024 px（與 App 相同）；焦距換 px 用縮放後的長邊，所以縮圖不影響 |
| 轉子半徑 | 機型型錄直徑 ÷ 2（manifest `specs`） |
| 輪轂高度 | typical 42、description 3（`typical` = 機型常見值，不是那一台的） |
| 相機高度 | 1.6 m（假設手持站立；Commons 照片有些從高處或無人機拍，這時仰角會高估） |
| 機艙 overhang | 5.0 m 預設（yaw 粗估） |
| 雜訊底 | 1.5 px（與 `SENSITIVITY.md` 相同） |
| 每張耗時中位 | 0.39 s |

## 2. 閘門

| 結果 | 張數 |
|---|---|
| 放行（正視） | 3 |
| 放行（側視） | 2 |
| 拒收 | 38 |
| 結構定位丟例外 | 2 |
| 放行但警告畫面裡有第二個轉子 | 3 |

拒收原因（同一張可能多條）：

| 原因 | 次數 |
|---|---|
| 只定位到 N 片葉片（…） | 23 |
| 三片葉尖半徑差 N%（…） | 21 |
| 一片葉片都沒有定位到 | 5 |
| 結構定位失敗（…） | 2 |

## 3. 姿態估計

| 量 | 中位 | 範圍 |
|---|---|---|
| 仰角（°） | 4.8 | [3.95, 10.15] |
| |yaw|（°） | 5.9 | [-15.58, 5.9] |
| 距離（m） | 1148.9 | [359.6, 1806.69] |

## 4. 補償前後

| 指標 | 原始標記 | 補償後標記 | 消掉 | 留下 | 新增 |
|---|---|---|---|---|---|
| 葉尖偏移 | 1 | 1 | 0 | 1 | 0 |
| 半徑 | 1 | 1 | 0 | 1 | 0 |

- 葉尖偏移離群量中位：原始 78 cm → 補償後 132 cm。
- 預彎擬合在 0–8 m 內：1/3，全部範圍 [-5.43, 17.55] m。
- 半徑有補償（|yaw| ≤ 15°）：2/3。
- 有葉片落在六點鐘 ±35° 而被點名：2/3。
- 輪轂高度 ×0.8／×1.2：補償標記集合改變 0/3 張，仰角變動中位 1.0°。

### 4.1 逐張（正視放行）

| 照片 | 機型 | 來源 | f35 | 輪轂高 m | 仰角° | yaw° | 距離 m | 葉尖偏移 原始 | 補償後 | 預彎 m | 半徑 原始 | 補償後 | 近塔 | ±20% |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| [c184853067](https://commons.wikimedia.org/?curid=184853067) | Enercon E-126 | model | 105 | 126.0 | 3.9 | 5.6 | 1807 | +70 cm | -132 cm | 5.2 | +149 cm | +236 cm | — | 穩 |
| [c36383488](https://commons.wikimedia.org/?curid=36383488) | Enercon E-40 | model | 127 | 65.0* | 10.2 | -15.6 | 360 | **+273 cm ⚑** | **+273 cm ⚑** | -5.4 ✗ | **+279 cm ⚑** | **+279 cm ⚑** | C | 穩 |
| [c5682409](https://commons.wikimedia.org/?curid=5682409) | Enercon E-66 | model | 89 | 98.0* | 4.8 | 5.9 | 1149 | -78 cm | -78 cm | 17.6 ✗ | -303 cm | +112 cm | C | 穩 |

`*` 輪轂高度是機型典型值。⚑ = 三片互比標記（z ≥ 3 且另兩片一致）。「翻」= 輪轂高度 ±20% 時補償後的標記集合會變。

## 5. 每機型

| 機型 | 張數 | 放行 | 正視互比 | 姿態可用 | 葉尖偏移原始標記 | 補償後 |
|---|---|---|---|---|---|---|
| Enercon E-101 | 5 | 0 | 0 | 0 | 0 | 0 |
| Enercon E-115 | 9 | 1 | 0 | 0 | 0 | 0 |
| Enercon E-126 | 8 | 1 | 1 | 1 | 0 | 0 |
| Enercon E-40 | 10 | 1 | 1 | 1 | 1 | 1 |
| Enercon E-66 | 8 | 1 | 1 | 1 | 0 | 0 |
| Enercon E-70 | 5 | 1 | 0 | 0 | 0 | 0 |

### 5.1 每種來源

`model` = 機型分類頁本身；`model-subcat` = 機型分類頁往下的子分類（檔案繼承機型）；`view` = 地區／取景分類頁，機型由檔案自己的分類或描述推斷（`search-view`）。

| 來源 | 張數 | 放行 | 正視互比 | 姿態可用 | 葉尖偏移原始標記 | 補償後 |
|---|---|---|---|---|---|---|
| model | 45 | 5 | 3 | 3 | 1 | 1 |

## 6. 來源與授權

照片不進版控。逐張：

| 檔案 | 作者 | 授權 | 相機 | 寬×高（原檔） |
|---|---|---|---|---|
| [c116792602](https://commons.wikimedia.org/?curid=116792602) File:Föhr Windturbines 2022.jpg | Mrb-Wind | CC BY-SA 4.0 | X-E1 | 4896×3264 |
| [c12869944](https://commons.wikimedia.org/?curid=12869944) File:Mellerhoefe windkraft 09.jpg | Achim Raschka  (  talk  ) | CC BY-SA 4.0 | NIKON D40 | 3008×2000 |
| [c16043004](https://commons.wikimedia.org/?curid=16043004) File:Windpark Vetschau 1.jpg | Peter Tritthart | CC BY 3.0 | DMC-TZ3 | 1872×3328 |
| [c184853055](https://commons.wikimedia.org/?curid=184853055) File:Hörlitz Aussichtsturm lub 2025-09-07 img04 Aussicht.jpg | Lukas Beck | CC BY 4.0 | ILCE-7RM3 | 7952×5304 |
| [c184853067](https://commons.wikimedia.org/?curid=184853067) File:Hörlitz Aussichtsturm lub 2025-09-07 img05 Aussicht.jpg | Lukas Beck | CC BY 4.0 | ILCE-7RM3 | 7952×5304 |
| [c184853092](https://commons.wikimedia.org/?curid=184853092) File:Hörlitz Aussichtsturm lub 2025-09-07 img11 Aussicht.jpg | Lukas Beck | CC BY 4.0 | ILCE-7RM3 | 7952×5304 |
| [c185379090](https://commons.wikimedia.org/?curid=185379090) File:Rosskopf (Breisgau) Wind turbines 20260302.jpg | Chondriammos | CC BY 4.0 | DSC-HX90V | 4896×3672 |
| [c189094433](https://commons.wikimedia.org/?curid=189094433) File:2026-03-22 D500-2040 Achim-Lammerts Windpark-Hatzenbühl | Achim Lammerts (Syntaxys) | CC BY-SA 4.0 | NIKON D500 | 5568×3712 |
| [c189094434](https://commons.wikimedia.org/?curid=189094434) File:2026-03-21 Z5-2163 Achim-Lammerts Windpark-Hatzenbühl.j | Achim Lammerts (Syntaxys) | CC BY-SA 4.0 | NIKON Z 5 | 5400×3600 |
| [c19002876](https://commons.wikimedia.org/?curid=19002876) File:Wind turbine with observation deck bruck an der leitha. | KoeppiK | CC BY-SA 3.0 | NIKON D80 | 2592×3872 |
| [c19326536](https://commons.wikimedia.org/?curid=19326536) File:Göslow Enercon E-101.JPG | Erell | CC BY-SA 3.0 | DMC-FZ150 | 3000×4000 |
| [c19669637](https://commons.wikimedia.org/?curid=19669637) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9347.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 4256×2848 |
| [c19674205](https://commons.wikimedia.org/?curid=19674205) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9604.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 4256×2848 |
| [c19674208](https://commons.wikimedia.org/?curid=19674208) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9605.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 4256×2848 |
| [c19674213](https://commons.wikimedia.org/?curid=19674213) File:2012-05-28 Fotoflug Cuxhaven Wilhelmshaven DSCF9606.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 4256×2848 |
| [c20885155](https://commons.wikimedia.org/?curid=20885155) File:Pala eolica Mele 01.jpg | Alessio Sbarbaro  User_talk:Yoggysot | CC BY-SA 3.0 | PENTACON Dpix 1100Z | 2448×3264 |
| [c21367677](https://commons.wikimedia.org/?curid=21367677) File:Pala eolica Mele 12.jpg | Alessio Sbarbaro  User_talk:Yoggysot | CC BY-SA 3.0 | PENTACON Dpix 1100Z | 2448×3264 |
| [c26679267](https://commons.wikimedia.org/?curid=26679267) File:Lausitz Luftsport- & Techniktage 2013 by-RaBoe 037.jpg | ©  Ra Boe / Wikipedia | CC BY-SA 3.0 de | NIKON D90 | 2600×1727 |
| [c26679295](https://commons.wikimedia.org/?curid=26679295) File:Lausitz Luftsport- & Techniktage 2013 by-RaBoe 039.jpg | ©  Ra Boe / Wikipedia | CC BY-SA 3.0 de | NIKON D90 | 2600×1727 |
| [c26679298](https://commons.wikimedia.org/?curid=26679298) File:Lausitz Luftsport- & Techniktage 2013 by-RaBoe 040.jpg | ©  Ra Boe / Wikipedia | CC BY-SA 3.0 de | NIKON D90 | 2600×1727 |
| [c32385663](https://commons.wikimedia.org/?curid=32385663) File:29 Windpark-Standort 4 und 5 (9725253758).jpg | EnergieAgentur.NRW | CC BY 2.0 | NIKON D700 | 2126×1469 |
| [c36383488](https://commons.wikimedia.org/?curid=36383488) File:20110425 xl wiki m podszun-D90-0760.jpg | Pantona | CC BY-SA 4.0 | NIKON D90 | 2848×4288 |
| [c36383498](https://commons.wikimedia.org/?curid=36383498) File:20120802 xl wiki m podszun-P7100-9016.JPG | Pantona | CC BY-SA 4.0 | COOLPIX P7100 | 2736×3648 |
| [c36405367](https://commons.wikimedia.org/?curid=36405367) File:20110425 xl m podszun-NIKON-D90-0782.JPG | Pantona | CC BY-SA 4.0 | NIKON D90 | 2848×4288 |
| [c36405368](https://commons.wikimedia.org/?curid=36405368) File:20120802 xl wiki m podszun-P7100-9020.JPG | Pantona | CC BY-SA 4.0 | COOLPIX P7100 | 2736×3648 |
| [c38239735](https://commons.wikimedia.org/?curid=38239735) File:ENOVA Windpark Holtgaste.jpg | Herr Zellmer | CC BY-SA 4.0 | DMC-TZ7 | 3776×2520 |
| [c38239738](https://commons.wikimedia.org/?curid=38239738) File:ENOVA Windpark Bunderhee.jpg | Herr Brinkema | CC BY-SA 4.0 | DMC-FS30 | 4320×3240 |
| [c41928516](https://commons.wikimedia.org/?curid=41928516) File:20150726 xl P1000643 Windkraftanlagen an der Bahnstreck | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 4896×3672 |
| [c42148833](https://commons.wikimedia.org/?curid=42148833) File:20150806 xl P1010667 Wildpoldsried.JPG | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 4896×3672 |
| [c42148836](https://commons.wikimedia.org/?curid=42148836) File:20150806 xl P1010654 Wildpoldsried.JPG | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 4896×3672 |
| [c42148853](https://commons.wikimedia.org/?curid=42148853) File:20150806 xl P1010845 Wildpoldsried.JPG | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 3672×4896 |
| [c42148854](https://commons.wikimedia.org/?curid=42148854) File:20150806 xl P1010872 Wildpoldsried.JPG | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 4896×3672 |
| [c42148858](https://commons.wikimedia.org/?curid=42148858) File:20150806 xl P1010664 Wildpoldsried.JPG | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 4896×3672 |
| [c42148865](https://commons.wikimedia.org/?curid=42148865) File:20150806 xl P1010671 Wildpoldsried.JPG | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 4896×3672 |
| [c49383831](https://commons.wikimedia.org/?curid=49383831) File:20160604 xl P1040381-Feldheim-Treuenbrietzen.jpg | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 4896×3672 |
| [c49383834](https://commons.wikimedia.org/?curid=49383834) File:20160604 xl P1040384-Feldheim-Treuenbrietzen.jpg | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 4896×3672 |
| [c49383836](https://commons.wikimedia.org/?curid=49383836) File:20160604 xl P1040386-Feldheim-Treuenbrietzen.jpg | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 4896×3672 |
| [c49384455](https://commons.wikimedia.org/?curid=49384455) File:20160604 xl P1040400-Feldheim-Treuenbrietzen-WMC.jpg | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 4896×3672 |
| [c49384464](https://commons.wikimedia.org/?curid=49384464) File:20160604 xl P1040440-Feldheim-Treuenbrietzen-WMC.jpg | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 4896×3672 |
| [c49395978](https://commons.wikimedia.org/?curid=49395978) File:20160604 xl P1040458-Feldheim-Treuenbrietzen-WMC.jpg | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 4896×3672 |
| [c50571490](https://commons.wikimedia.org/?curid=50571490) File:20160604 xl P1040444-Feldheim-Treuenbrietzen.jpg | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 3672×4896 |
| [c50571491](https://commons.wikimedia.org/?curid=50571491) File:20160604 xl P1040455-Feldheim-Treuenbrietzen.jpg | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 3672×4896 |
| [c5682409](https://commons.wikimedia.org/?curid=5682409) File:Hoheward-DSCI0492.jpg | Rainer Halama | CC BY 3.0 | DigitalCAM | 3072×2304 |
| [c6914141](https://commons.wikimedia.org/?curid=6914141) File:Enercon E-126 Aurich-Georgsfeld02.jpg | Prankster | Public domain | NIKON D40 | 3008×2000 |
| [c87603470](https://commons.wikimedia.org/?curid=87603470) File:20200301 Windrad-Großbaustelle Flamschen, Coesfeld (095 | Günter Seggebäing | CC BY-SA 3.0 | ILCE-7M2 | 5924×3949 |
