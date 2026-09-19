# 真實整機照上的姿態估計與透視補償（Commons）

> 版本 `commons-pose-2026-09-19`。由 `scripts/real_pose_validation.py report` 從 `data/commons_pose_results.json` 產生，**數字不手抄**；照片本體不進版控（CC BY／BY-SA，來源列在 §6），重跑用 `fetch_commons_turbines.py download` 抓同一份 manifest。

## 0. 一句話

84 張帶 EXIF 焦距、分類在機型頁下的 Commons 整機照：閘門放行 **5**（正視 3、側視 2），姿態可用 **3/3**。正視放行照片的三片互比原始標記葉尖偏移 **1** 張，補償後剩 **1**（消掉 0、留下 1、新增 0）；半徑原始 1 → 補償後 1。預彎擬合落在合理範圍 1/3（中位 5.2 m）。輪轂高度 ±20% 會翻掉補償結論的有 0/3 張。

這些是營運中的風機被路人拍下，先驅上沒有一台葉尖偏了兩公尺——所以原始標記幾乎都是假警報，「補償後剩幾個」是補償的成績、「新增幾個」是代價。**這裡量不到缺陷召回率**，那要有已知缺陷的照片。

## 1. 輸入

| 項目 | 值 |
|---|---|
| 照片來源 | Wikimedia Commons 機型分類頁（`fetch_commons_turbines.py search`），篩 CC／PD 授權 + EXIF `FocalLengthIn35mmFilm` + 寬 ≥ 1600 |
| 分析尺度 | 長邊 1024 px（與 App 相同）；焦距換 px 用縮放後的長邊，所以縮圖不影響 |
| 轉子半徑 | 機型型錄直徑 ÷ 2（manifest `specs`） |
| 輪轂高度 | typical 81、description 3（`typical` = 機型常見值，不是那一台的） |
| 相機高度 | 1.6 m（假設手持站立；Commons 照片有些從高處或無人機拍，這時仰角會高估） |
| 機艙 overhang | 5.0 m 預設（yaw 粗估） |
| 雜訊底 | 1.5 px（與 `SENSITIVITY.md` 相同） |
| 每張耗時中位 | 0.33 s |

## 2. 閘門

| 結果 | 張數 |
|---|---|
| 放行（正視） | 3 |
| 放行（側視） | 2 |
| 拒收 | 77 |
| 結構定位丟例外 | 2 |
| 放行但警告畫面裡有第二個轉子 | 3 |

拒收原因（同一張可能多條）：

| 原因 | 次數 |
|---|---|
| 只定位到 N 片葉片（…） | 34 |
| 三片葉尖半徑差 N%（…） | 31 |
| 一片葉片都沒有定位到 | 30 |
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
| Enercon E-126 | 41 | 1 | 1 | 1 | 0 | 0 |
| Enercon E-40 | 16 | 1 | 1 | 1 | 1 | 1 |
| Enercon E-66 | 8 | 1 | 1 | 1 | 0 | 0 |
| Enercon E-70 | 5 | 1 | 0 | 0 | 0 | 0 |

### 5.1 每種來源

`model` = 機型分類頁本身；`model-subcat` = 機型分類頁往下的子分類（檔案繼承機型）；`view` = 地區／取景分類頁，機型由檔案自己的分類或描述推斷（`search-view`）。

| 來源 | 張數 | 放行 | 正視互比 | 姿態可用 | 葉尖偏移原始標記 | 補償後 |
|---|---|---|---|---|---|---|
| model | 51 | 5 | 3 | 3 | 1 | 1 |
| model-subcat | 32 | 0 | 0 | 0 | 0 | 0 |
| view | 1 | 0 | 0 | 0 | 0 | 0 |

## 6. 來源與授權

照片不進版控。逐張：

| 檔案 | 作者 | 授權 | 相機 | 寬×高（原檔） |
|---|---|---|---|---|
| [c113015211](https://commons.wikimedia.org/?curid=113015211) File:Enercon E-126.jpg | Leo Bro | CC BY-SA 4.0 | COOLPIX L25 | 3648×2736 |
| [c116792602](https://commons.wikimedia.org/?curid=116792602) File:Föhr Windturbines 2022.jpg | Mrb-Wind | CC BY-SA 4.0 | X-E1 | 4896×3264 |
| [c12869944](https://commons.wikimedia.org/?curid=12869944) File:Mellerhoefe windkraft 09.jpg | Achim Raschka  (  talk  ) | CC BY-SA 4.0 | NIKON D40 | 3008×2000 |
| [c16043004](https://commons.wikimedia.org/?curid=16043004) File:Windpark Vetschau 1.jpg | Peter Tritthart | CC BY 3.0 | DMC-TZ3 | 1872×3328 |
| [c181564589](https://commons.wikimedia.org/?curid=181564589) File:E40 on a wet winter day, Wetteren, 2026.jpg | DimiTalen | CC0 | NIKON Z50_2 | 5501×3668 |
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
| [c26562677](https://commons.wikimedia.org/?curid=26562677) File:2013-06-08 Projekt Heißlufftballon DSCF7612.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 2500×1673 |
| [c26562683](https://commons.wikimedia.org/?curid=26562683) File:2013-06-08 Projekt Heißlufftballon DSCF7613.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 2500×1673 |
| [c26562709](https://commons.wikimedia.org/?curid=26562709) File:2013-06-08 Projekt Heißlufftballon DSCF7617.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S5Pro   | 2500×1673 |
| [c26565245](https://commons.wikimedia.org/?curid=26565245) File:2013-06-08 Projekt Heißluftballon DSCF0819.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S3Pro   | 2500×1673 |
| [c26565336](https://commons.wikimedia.org/?curid=26565336) File:2013-06-08 Projekt Heißluftballon DSCF0825.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S3Pro   | 2500×1673 |
| [c26565345](https://commons.wikimedia.org/?curid=26565345) File:2013-06-08 Projekt Heißluftballon DSCF0826.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S3Pro   | 2500×1673 |
| [c26565565](https://commons.wikimedia.org/?curid=26565565) File:2013-06-08 Projekt Heißluftballon DSCF0843.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S3Pro   | 2500×1673 |
| [c26565658](https://commons.wikimedia.org/?curid=26565658) File:2013-06-08 Projekt Heißluftballon DSCF0847.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S3Pro   | 2500×1673 |
| [c26565683](https://commons.wikimedia.org/?curid=26565683) File:2013-06-08 Projekt Heißluftballon DSCF0848.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S3Pro   | 2500×1673 |
| [c26565687](https://commons.wikimedia.org/?curid=26565687) File:2013-06-08 Projekt Heißluftballon DSCF0849.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S3Pro   | 2500×1673 |
| [c26565694](https://commons.wikimedia.org/?curid=26565694) File:2013-06-08 Projekt Heißluftballon DSCF0850.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S3Pro   | 2500×1673 |
| [c26565702](https://commons.wikimedia.org/?curid=26565702) File:2013-06-08 Projekt Heißluftballon DSCF0851.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S3Pro   | 2500×1673 |
| [c26567504](https://commons.wikimedia.org/?curid=26567504) File:2013-06-08 Projekt Heißluftballon DSCF0863.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S3Pro   | 2500×1673 |
| [c26567508](https://commons.wikimedia.org/?curid=26567508) File:2013-06-08 Projekt Heißluftballon DSCF0864.jpg | Martina Nolte | CC BY-SA 3.0 de | FinePix S3Pro   | 2500×1673 |
| [c26679267](https://commons.wikimedia.org/?curid=26679267) File:Lausitz Luftsport- & Techniktage 2013 by-RaBoe 037.jpg | ©  Ra Boe / Wikipedia | CC BY-SA 3.0 de | NIKON D90 | 2600×1727 |
| [c26679282](https://commons.wikimedia.org/?curid=26679282) File:Lausitz Luftsport- & Techniktage 2013 by-RaBoe 038.jpg | ©  Ra Boe / Wikipedia | CC BY-SA 3.0 de | NIKON D90 | 2600×1727 |
| [c26679295](https://commons.wikimedia.org/?curid=26679295) File:Lausitz Luftsport- & Techniktage 2013 by-RaBoe 039.jpg | ©  Ra Boe / Wikipedia | CC BY-SA 3.0 de | NIKON D90 | 2600×1727 |
| [c26679298](https://commons.wikimedia.org/?curid=26679298) File:Lausitz Luftsport- & Techniktage 2013 by-RaBoe 040.jpg | ©  Ra Boe / Wikipedia | CC BY-SA 3.0 de | NIKON D90 | 2600×1727 |
| [c26727051](https://commons.wikimedia.org/?curid=26727051) File:Ellerholzhöft (Hamburg-Steinwerder).1.phb.ajb.jpg | Ajepbah | CC BY-SA 3.0 de | NIKON D5000 | 4244×2818 |
| [c26747464](https://commons.wikimedia.org/?curid=26747464) File:Köhlbrandbrücke (Hamburg).1.phb.ajb.jpg | Ajepbah | CC BY-SA 3.0 de | NIKON D5000 | 4168×2768 |
| [c26747500](https://commons.wikimedia.org/?curid=26747500) File:Köhlbrandbrücke (Hamburg).2.phb.ajb.jpg | Ajepbah | CC BY-SA 3.0 de | NIKON D5000 | 4127×2741 |
| [c26835458](https://commons.wikimedia.org/?curid=26835458) File:Hansaport (Hamburg-Waltershof).1.phb.ajb.jpg | Ajepbah | CC BY-SA 3.0 de | NIKON D5000 | 4137×2748 |
| [c26835574](https://commons.wikimedia.org/?curid=26835574) File:Hansaport (Hamburg-Waltershof).4.phb.ajb.jpg | Ajepbah | CC BY-SA 3.0 de | NIKON D5000 | 4288×2848 |
| [c26835656](https://commons.wikimedia.org/?curid=26835656) File:Hansaport (Hamburg-Waltershof).Gleisanbindung.2.phb.ajb | Ajepbah | CC BY-SA 3.0 de | NIKON D5000 | 4288×2848 |
| [c26835707](https://commons.wikimedia.org/?curid=26835707) File:Hansaport (Hamburg-Waltershof).Gleisanbindung.phb.ajb.j | Ajepbah | CC BY-SA 3.0 de | NIKON D5000 | 4254×2826 |
| [c26835764](https://commons.wikimedia.org/?curid=26835764) File:Köhlbrand-Freileitungskreuzung (Hamburg).phb.ajb.jpg | Ajepbah | CC BY-SA 3.0 de | NIKON D5000 | 4254×2825 |
| [c26876567](https://commons.wikimedia.org/?curid=26876567) File:Hansaport (Hamburg-Waltershof).5.phb.ajb.jpg | Ajepbah | CC BY-SA 3.0 de | NIKON D5000 | 4254×2825 |
| [c26894840](https://commons.wikimedia.org/?curid=26894840) File:Containerterminal Altenwerder (Hamburg-Altenwerder).4.p | Ajepbah | CC BY-SA 3.0 de | NIKON D5000 | 2848×4288 |
| [c26894897](https://commons.wikimedia.org/?curid=26894897) File:Containerterminal Altenwerder (Hamburg-Altenwerder).3.p | Ajepbah | CC BY-SA 3.0 de | NIKON D5000 | 2848×4288 |
| [c26895300](https://commons.wikimedia.org/?curid=26895300) File:Hamburg-Altenwerder.phb.ajb.jpg | Ajepbah | CC BY-SA 3.0 de | NIKON D5000 | 4254×2826 |
| [c26978844](https://commons.wikimedia.org/?curid=26978844) File:Altenwerder Hauptdeich (Hamburg-Altenwerder).1.phb.ajb. | Ajepbah | CC BY-SA 3.0 de | NIKON D5000 | 2848×4288 |
| [c26978900](https://commons.wikimedia.org/?curid=26978900) File:Altenwerder Hauptdeich (Hamburg-Altenwerder).2.phb.ajb. | Ajepbah | CC BY-SA 3.0 de | NIKON D5000 | 2804×4222 |
| [c26979080](https://commons.wikimedia.org/?curid=26979080) File:Hochstraße Elbmarsch (Hamburg-Altenwerder).1.phb.ajb.jp | Ajepbah | CC BY-SA 3.0 de | NIKON D5000 | 4254×2826 |
| [c32385663](https://commons.wikimedia.org/?curid=32385663) File:29 Windpark-Standort 4 und 5 (9725253758).jpg | EnergieAgentur.NRW | CC BY 2.0 | NIKON D700 | 2126×1469 |
| [c36383488](https://commons.wikimedia.org/?curid=36383488) File:20110425 xl wiki m podszun-D90-0760.jpg | Pantona | CC BY-SA 4.0 | NIKON D90 | 2848×4288 |
| [c36383498](https://commons.wikimedia.org/?curid=36383498) File:20120802 xl wiki m podszun-P7100-9016.JPG | Pantona | CC BY-SA 4.0 | COOLPIX P7100 | 2736×3648 |
| [c36405367](https://commons.wikimedia.org/?curid=36405367) File:20110425 xl m podszun-NIKON-D90-0782.JPG | Pantona | CC BY-SA 4.0 | NIKON D90 | 2848×4288 |
| [c36405368](https://commons.wikimedia.org/?curid=36405368) File:20120802 xl wiki m podszun-P7100-9020.JPG | Pantona | CC BY-SA 4.0 | COOLPIX P7100 | 2736×3648 |
| [c38239735](https://commons.wikimedia.org/?curid=38239735) File:ENOVA Windpark Holtgaste.jpg | Herr Zellmer | CC BY-SA 4.0 | DMC-TZ7 | 3776×2520 |
| [c38239738](https://commons.wikimedia.org/?curid=38239738) File:ENOVA Windpark Bunderhee.jpg | Herr Brinkema | CC BY-SA 4.0 | DMC-FS30 | 4320×3240 |
| [c41901328](https://commons.wikimedia.org/?curid=41901328) File:Luftbild Müllverbrennungsanlage Wuppertal.jpg | Krd | CC BY-SA 4.0 | NIKON D7100 | 2906×1938 |
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
| [c49863098](https://commons.wikimedia.org/?curid=49863098) File:20160604 xl P1040436-Feldheim-Treuenbrietzen-Sitz des F | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 4896×3672 |
| [c49863100](https://commons.wikimedia.org/?curid=49863100) File:20160604 xl P1040477-Feldheim-Treuenbrietzen-Sitz des F | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 4896×3672 |
| [c50571490](https://commons.wikimedia.org/?curid=50571490) File:20160604 xl P1040444-Feldheim-Treuenbrietzen.jpg | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 3672×4896 |
| [c50571491](https://commons.wikimedia.org/?curid=50571491) File:20160604 xl P1040455-Feldheim-Treuenbrietzen.jpg | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 3672×4896 |
| [c5682409](https://commons.wikimedia.org/?curid=5682409) File:Hoheward-DSCI0492.jpg | Rainer Halama | CC BY 3.0 | DigitalCAM | 3072×2304 |
| [c57659697](https://commons.wikimedia.org/?curid=57659697) File:20160521 xl P1040190-Windkraftanlagen-WKA-bei-Freudenbe | Molgreen | CC BY-SA 4.0 | DMC-TZ61 | 4896×3672 |
| [c6326631](https://commons.wikimedia.org/?curid=6326631) File:Enercon-P1130626.JPG | Gunnar Ries  Amphibol | CC BY-SA 3.0 | DMC-FZ50 | 3648×2736 |
| [c6326636](https://commons.wikimedia.org/?curid=6326636) File:Enercon-P1130627.JPG | Gunnar Ries  Amphibol | CC BY-SA 3.0 | DMC-FZ50 | 3648×2736 |
| [c6914141](https://commons.wikimedia.org/?curid=6914141) File:Enercon E-126 Aurich-Georgsfeld02.jpg | Prankster | Public domain | NIKON D40 | 3008×2000 |
| [c87603470](https://commons.wikimedia.org/?curid=87603470) File:20200301 Windrad-Großbaustelle Flamschen, Coesfeld (095 | Günter Seggebäing | CC BY-SA 3.0 | ILCE-7M2 | 5924×3949 |
| [c89696937](https://commons.wikimedia.org/?curid=89696937) File:20170422 Eilum WindTurbine WindSensor DSC01195 PtrQs.jp | PtrQs | CC BY-SA 4.0 | DSLR-A900 | 6048×4032 |
