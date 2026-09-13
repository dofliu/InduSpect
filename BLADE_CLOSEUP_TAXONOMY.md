# Mode B 標註分類表（B0 產出）

> 版本 `b0-2026-09-13`。**本檔由 `blade_prototype/scripts/render_closeup_taxonomy.py` 產生，不要手改。** 單一來源是 `blade_prototype/data/closeup_taxonomy.json`；改完 JSON 要重跑腳本，否則 `tests/test_closeup_taxonomy.py` 會紅。
>
> 規格：[`BLADE_CLOSEUP_SPEC.md`](BLADE_CLOSEUP_SPEC.md)。這張表是該規格 §10 的 B0 出口條件之一。

這張表有兩個用途，缺一不可：

1. **標註指引**——人拿著它標語料，B1 的評估腳本吃 §6 的紀錄格式。
2. **知識庫種子**——每個子類的「幾何規則」欄就是規格 §8.2 知識庫第 1 項的內容，`normal_structures` 就是第 2 項。寫這張表等於在建知識庫。

---

## 1. 四個機制類（照片級標籤）

| 類別 | 中文 | 定義 | 證據型態 | 嚴重度尺規 |
|---|---|---|---|---|
| `healthy` | 健康 | 看過且確認沒有成立的損傷。含乾淨表面、正常結構、汙染。 | 排除法：要能說出畫面上每一個可疑物件為什麼不是損傷 | `none` |
| `surface` | 表面劣化 | 蒙皮材料被減少或被破壞，但未及承載結構。 | 紋理與顏色（影像檢索有效，§5.3 的消融顯示只用影像檢索時 surface 類仍站得住） | `iea_task46` |
| `environmental` | 環境事件 | 外部事件造成的附著或燒蝕，成因在葉片之外。 | 顏色與場景（§5.3：只用文字檢索時 F1 掉到 0.500，這類要靠參考影像） | `generic_1_5` |
| `structural` | 結構損傷 | 承載結構的完整性受損：裂縫、分層、斷裂。 | 幾何（§5.3：只用影像檢索時 F1 = 0.000，這類**一定要**把幾何規則用文字講出來） | `generic_1_5` |

**照片級標籤規則**：照片級標籤取畫面內最嚴重的機制類，優先序 structural > environmental > surface > healthy。uncertain 與 reject 不參與這個比較，見 decision_rules。

### 1.1 `healthy` — 健康

| 子類 | 中文 | 是否損傷 | 外觀 | **幾何規則** | 位置 | 需要的解析度 | 易混淆於 |
|---|---|---|---|---|---|---|---|
| `clean_surface` | 乾淨表面 | ✗ | 連續、單一色、無邊界特徵的葉片蒙皮 | 無 | 任意 | — | — |
| `normal_structure` | 正常結構 | ✗ | 見 normal_structures 清單，標註時要指到清單的哪一項 | 多半規則、重複、對稱、或有明確製造意圖 | 依項目 | — | — |
| `contamination` | 汙染 | ✗ | 汙漬、鹽霧白痕、油汙、藻類綠斑、蟲屍、鳥糞。顏色附加在表面上，不改變表面幾何 | 邊界柔和、常沿重力方向流下；蟲屍集中在前緣且呈點狀散布 | 任意，前緣較多 | — | `environmental/lightning_damage`、`normal_structures/vortex_generator`、`structural/transverse_crack`、`surface/corrosion_metal_part`、`surface/surface_pitting` |

- **`contamination`**：照片級算 healthy，但要單獨統計。Blade30 的標註把 contamination 與 defect 分開，§5.4 的 YOLOv8n 基線兩類就是 damage/dirt——不分開統計就無法與它們比較。

### 1.2 `surface` — 表面劣化

| 子類 | 中文 | 是否損傷 | 外觀 | **幾何規則** | 位置 | 需要的解析度 | 易混淆於 |
|---|---|---|---|---|---|---|---|
| `leading_edge_erosion` | 前緣侵蝕 | ✓ | 由點蝕起、擴為塗層剝除露出底漆（白轉灰或黃），嚴重時露出膠衣與積層 | 只在前緣；沿展向的連續或半連續帶狀；外緣不規則呈鋸齒；寬度沿展向變化 | 前緣，外側 1/3 展向最嚴重（線速度最高） | ≤ 0.07 cm/px | `environmental/ice_accretion`、`normal_structures/lep_edge_step`、`surface/coating_peeling` |
| `coating_peeling` | 塗層剝落／起泡 | ✓ | 片狀脫落露出底層，邊緣常捲起帶陰影；起泡時為圓形隆起 | 邊界銳利、形狀不規則的封閉片狀；不限前緣；單一大片而非沿緣帶狀 | 任意 | ≤ 0.17 cm/px | `normal_structures/lep_edge_step`、`normal_structures/marking_decal`、`normal_structures/paint_seam`、`normal_structures/repair_patch`、`structural/delamination`、`surface/leading_edge_erosion` |
| `corrosion_metal_part` | 金屬件腐蝕 | ✓ | 避雷接點、排水孔、根部法蘭等金屬件本體出現橘褐色鏽蝕與表面粗化 | 以金屬件為中心；鏽蝕在件上，不只是件下方的流痕 | 金屬件周圍 | ≤ 0.17 cm/px | `healthy/contamination`、`normal_structures/contamination_streak`、`normal_structures/lightning_receptor` |
| `gelcoat_crack_network` | 膠衣龜裂 | ✓ | 細密網狀裂紋，如陶瓷開片 | 網狀、無單一主走向、不貫穿、裂縫不張開 | 任意，日照面較多 | ≤ 0.07 cm/px | `structural/longitudinal_crack`、`structural/transverse_crack` |
| `surface_pitting` | 點蝕／針孔群 | ✓ | 直徑 < 1 mm 的密集小孔 | 點狀密集分布，多在前緣 | 前緣 | ≤ 0.03 cm/px | `healthy/contamination`、`normal_structures/drain_hole` |

- **`leading_edge_erosion`**：與結冰的關鍵區別是減法 vs 加法：侵蝕把材料磨掉，邊界不規則且下陷；結冰堆上去，邊界平滑且隆起。
- **`corrosion_metal_part`**：順流而下的鏽色條痕本身是汙染不是損傷。判 corrosion 的條件是**源頭的金屬件本體**看得出腐蝕，只看到流痕要標 contamination。
- **`gelcoat_crack_network`**：這是 surface 與 structural 的邊界案例。判 surface 的條件是**網狀且無主走向**；一旦出現單一、有走向、張開的裂縫，改判 structural。
- **`surface_pitting`**：對應 IEA Level 0。§2 已證明**合規取像條件下都做不到**（1 mm 在 12 m / 120 mm eq 只有 1.5 px）。列在表上是為了讓標註者知道「影像上看不到」不等於「沒有」，報告不得因為沒偵測到就宣稱無 Level 0。

### 1.3 `environmental` — 環境事件

| 子類 | 中文 | 是否損傷 | 外觀 | **幾何規則** | 位置 | 需要的解析度 | 易混淆於 |
|---|---|---|---|---|---|---|---|
| `ice_accretion` | 結冰 | ✓ | 前緣白色不透明堆積，表面光滑或呈羽狀／角狀 | 沿前緣分布但為**加法**：邊界平滑、剖面隆起、常向迎風側伸出 | 前緣 | ≤ 0.35 cm/px | `environmental/snow_adhesion`、`surface/leading_edge_erosion` |
| `snow_adhesion` | 積雪附著 | ✓ | 鬆散白色附著，表面粗糙不反光 | 分布不限前緣；邊界鬆散 | 任意 | ≤ 0.35 cm/px | `environmental/ice_accretion` |
| `lightning_damage` | 雷擊損傷 | ✓ | 黑褐色碳化燒蝕、放射狀焦痕；嚴重時葉尖爆裂缺口或殼體撕裂 | **有明確中心點**（多為避雷接點或葉尖），焦痕自該點放射 | 葉尖與避雷接點周圍 | ≤ 0.35 cm/px | `healthy/contamination`、`normal_structures/lightning_receptor`、`normal_structures/tip_marking` |

- **`ice_accretion`**：場景線索是強證據：同一張照片裡的地面、機艙、塔架若也有積冰積雪，結冰的可信度大幅提高。
- **`lightning_damage`**：避雷接點本身是深色金屬圓盤，是**正常結構**。判雷擊的條件是接點**周圍**有碳化或材料破壞，不是接點本身顏色深。

### 1.4 `structural` — 結構損傷

| 子類 | 中文 | 是否損傷 | 外觀 | **幾何規則** | 位置 | 需要的解析度 | 易混淆於 |
|---|---|---|---|---|---|---|---|
| `transverse_crack` | 橫向裂縫 | ✓ | 單一線狀開口，兩端漸細；開口處常有深色陰影或滲出物 | 與展向夾角 > 45°；線寬沿長度變化；走向可有偏折；**不貫穿全長** | 任意，常起於前緣或後緣向內延伸 | ≤ 0.07 cm/px | `healthy/contamination`、`normal_structures/contamination_streak`、`normal_structures/marking_decal`、`normal_structures/shadow_and_specular`、`surface/gelcoat_crack_network` |
| `longitudinal_crack` | 縱向裂縫 | ✓ | 沿展向的線狀開口，常沿黏合線或殼體接合縫發展 | 與展向夾角 < 45°；**寬度變化、走向有偏折、邊緣有陰影或滲出物** | 黏合線、前後緣接合處 | ≤ 0.07 cm/px | `normal_structures/mould_parting_line`、`normal_structures/paint_seam`、`normal_structures/shadow_and_specular`、`surface/gelcoat_crack_network` |
| `trailing_edge_split` | 後緣開裂 | ✓ | 後緣沿線張開成縫，兩側殼體分離 | 沿後緣；開口寬度自某點向兩端收斂；後緣輪廓在該處中斷或變形 | 後緣，中外段較多 | ≤ 0.17 cm/px | `normal_structures/serrated_trailing_edge` |
| `delamination` | 分層 | ✓ | 表面鼓起或呈波浪狀陰影，敲擊聲空 | 閉合、邊界柔和的隆起區；尺度 > 10 cm | 任意 | ≤ 0.35 cm/px | `normal_structures/repair_patch`、`normal_structures/vortex_generator`、`surface/coating_peeling` |
| `tip_damage` | 葉尖損傷 | ✓ | 葉尖缺損、撕裂、材料剝離 | 葉尖輪廓與另兩片不一致；缺口邊緣不規則 | 葉尖 | ≤ 0.35 cm/px | `normal_structures/tip_marking` |
| `structural_fracture` | 斷裂／缺損 | ✓ | 葉片缺一整塊或整段斷離，露出內部腹板與夾層 | 葉片外形中斷；斷面可見內部構造 | 任意 | ≤ 0.46 cm/px | `normal_structures/drain_hole` |

- **`transverse_crack`**：最關鍵也最難的一類。§5.2 的基線在這一類 recall 只有 0.500，12 張有 6 張被判成健康，多發生在低光照。Mode B 要追的主指標就是這一格。
- **`longitudinal_crack`**：與模具合模線最易混淆，這是 §5.4 的 YOLOv8n 誤報主因。區別：合模線**筆直、等寬、貫穿全長、兩側無顏色差異**；裂縫寬度變化、走向偏折、邊緣有陰影。分不出來就標 uncertain，不要標 healthy。
- **`delamination`**：影像上只能標「疑似」。分層的確診要靠敲擊法或熱像，近身照給不出證據。標註時 severity 不得高於 3，並在 note 寫明未確診。
- **`structural_fracture`**：Mode A 也抓得到（三片剪影互比）。Mode B 在這一類沒有優勢，列出是為了分類體系完整。

---

## 2. 正常結構清單（報成缺陷就是誤報）

規格 §6 第 4 條要求誤報分開報「在正常結構上」與「在乾淨表面上」。要做到這件事，正常結構必須被**正面標記**，不能只是「沒有缺陷標記」——否則誤報落在哪裡無從歸因。

| 項目 | 中文 | 怎麼認 | 會被誤判成 |
|---|---|---|---|
| `mould_parting_line` | 模具合模線／殼體接合縫 | 筆直、等寬、沿展向貫穿全長，兩側顏色相同 | `structural/longitudinal_crack` |
| `paint_seam` | 塗裝接縫／色帶邊界 | 顏色分界線，兩側都是完整塗層，無材料缺失 | `structural/longitudinal_crack`、`surface/coating_peeling` |
| `lep_edge_step` | LEP 前緣保護膜邊緣階差 | 沿前緣兩側各一條平行於前緣的規則階差，兩側等距、邊緣平直 | `surface/coating_peeling`、`surface/leading_edge_erosion` |
| `vortex_generator` | 渦流產生器（VG 板） | 成排等距的小三角片，規則重複 | `healthy/contamination`、`structural/delamination` |
| `serrated_trailing_edge` | 鋸齒尾緣 | 後緣等間距鋸齒，齒形一致 | `structural/trailing_edge_split` |
| `drain_hole` | 排水孔 | 葉尖或後緣附近的規則圓孔，邊緣整齊，常有加強環 | `structural/structural_fracture`、`surface/surface_pitting` |
| `lightning_receptor` | 避雷接點 | 圓形金屬盤嵌在蒙皮上，表面平整，位置對稱成對 | `environmental/lightning_damage`、`surface/corrosion_metal_part` |
| `marking_decal` | 編號噴漆／標記貼紙／警示帶 | 文字、數字、幾何圖形，邊界規則 | `structural/transverse_crack`、`surface/coating_peeling` |
| `tip_marking` | 葉尖航警塗裝 | 葉尖橘紅或紅白色段，色帶邊界平直垂直於展向 | `environmental/lightning_damage`、`structural/tip_damage` |
| `repair_patch` | 修補痕 | 補土、重塗或貼補的區塊，表面質感與周圍不同但完整，邊界常呈規則橢圓或矩形 | `structural/delamination`、`surface/coating_peeling` |
| `contamination_streak` | 汙漬流痕 | 沿重力方向的深色條痕，邊界柔和，寬度向下發散 | `structural/transverse_crack`、`surface/corrosion_metal_part` |
| `shadow_and_specular` | 陰影與反光帶 | 隨光源方向變化；同一位置在另一張不同角度的照片上消失 | `structural/longitudinal_crack`、`structural/transverse_crack` |

- **`repair_patch`**：不是損傷，但**要記錄位置**。修補處是既往缺陷的位置，跨次比對時那裡再出問題的機率比別處高。
- **`shadow_and_specular`**：規格 §3.3 的原始清單沒有這一項，是本表新增。理由：硬邊陰影在影像上與裂縫**幾何相同**（單一線狀、有走向、邊緣銳利），§5.2 的低光照漏檢與這件事是同一個問題的兩面。唯一可靠的排除法是另一張不同光線角度的照片，所以 §1.1 的「兩面都要拍」在標註上也有用。

---

## 3. 嚴重度尺規

### 3.1 `iea_task46`

- 適用：`surface/leading_edge_erosion`
- 需要尺度：**是**
- 來源：IEA Wind TCP Task 46, Leading Edge Erosion Classification System, 2023

| 等級 | 判準 | 可偵測 | 需要的解析度 |
|---|---|---|---|
| 0 | 針孔，單一尺寸 < 1 mm | **✗** | — |
| 1 | 單一實例面積 1–10 cm² | ✓ | ≤ 0.07 cm/px |
| 2 | 單一實例面積 10 cm² – 1 m² | ✓ | ≤ 0.17 cm/px |
| 3 | 待從 IEA 原文逐條抄錄核對 | ✓ | ≤ 0.46 cm/px |
| 4 | 待從 IEA 原文逐條抄錄核對 | ✓ | ≤ 0.46 cm/px |
| 5 | 待從 IEA 原文逐條抄錄核對 | ✓ | ≤ 0.46 cm/px |

- Level 0：§2 已證明合規取像條件下都做不到

> **未決**：Level 0–2 的門檻取自 BLADE_CLOSEUP_SPEC.md §2.2，已可用。Level 3–5 **尚未從 IEA 原始文件核對**，在核對完成前不得寫進報告——安全分級的門檻不可以憑印象填。

### 3.2 `generic_1_5`

- 適用：`environmental/*`、`structural/*`、`surface/* 無尺度時`
- 需要尺度：否
- 來源：沿用 Mode A 既有 severity 1–5

| 等級 | 判準 | 可偵測 | 需要的解析度 |
|---|---|---|---|
| 1 | 可見異常，不影響運轉 | — | — |
| 2 | 輕微，列入追蹤 | — | — |
| 3 | 中度，排程修補 | — | — |
| 4 | 嚴重，近期停機處理 | — | — |
| 5 | 危急，立即停機 | — | — |


---

## 4. 品質旗標

| 旗標 | 判準 | 為什麼要記 |
|---|---|---|
| `low_light` | 整體偏暗或陰影覆蓋葉片主要區域 | §5.2 的 6 張漏檢全在低光照。不單獨切子集，改善與惡化都會被平均掉 |
| `motion_blur` | 邊緣拖影，Laplacian 變異數低於門檻 | 裂縫的判準是邊緣銳利，模糊直接摧毀那個判準 |
| `backlit` | 光源在葉片後方，葉片呈剪影 | Mode A 的閘門唯一擋不了的拒收原因；解法在站位不在演算法（見 blade_proto/sunpos.py） |
| `specular` | 鏡面反光帶覆蓋畫面 | 反光帶與裂縫幾何相同 |
| `scale_unknown` | 無 EXIF 焦距／距離，畫面內也無已知尺寸物件 | 觸發 §9.4：不得輸出 IEA Level |
| `off_spec_framing` | 葉片弦向未橫跨畫面 1/3 | 觸發 §9.5：拒收並說明原因 |

---

## 5. 判定順序（有衝突時由上而下）

1. 取像不合 §1.2（葉片弦向未橫跨畫面 ≥ 1/3）→ photo_label = reject，不給任何類別標籤，不進訓練集也不進測試集。
2. 尺度未知 → 可以標類別與 generic severity，**不得**標 IEA Level（§9.4）。
3. 一張照片可有多個 region。照片級標籤取最嚴重的機制類：structural > environmental > surface > healthy。
4. 疑似 structural 但無法與 normal_structure 區分 → photo_label = uncertain，**不得**標 healthy。理由：§5.2 的失效模式正是裂縫被判成健康，把不確定倒向 healthy 會複製那個失效。uncertain 不計入任何類別的分母，單獨報張數。
5. 修補痕 → normal_structure/repair_patch，照片級算 healthy，但位置要留在 region 裡。
6. 汙染 → healthy/contamination，照片級算 healthy，但要單獨統計張數。
7. healthy 是「看過且確認乾淨」，不是「沒標到東西」。沒有人看過的照片 photo_label = unreviewed，與 healthy 不同。這條對齊 blade_dataset_service.dart 的 humanClean 規則。
8. 低光照／模糊／逆光照樣標，但要打 quality_flags。§6 補充要求低光照單獨切子集報數字。

---

## 6. 公開語料的類別對照

把公開語料的類別名對到本表。**對照是暫定的**：依 CLOSEUP_BASELINE_REPORT.md §5 逐張目視得到，樣本每類 4–6 張，尚未逐張核對全集。名稱相同不代表定義相同——這份對照的價值正是把「名稱一樣但東西不一樣」寫出來。

### 6.1 Multiclass Dataset for Intelligent Detection of Wind Turbine Blade Defects Using Drone Imagery, figshare 10.6084/m9.figshare.30210175.v1

- 授權：**CC BY 4.0（可商用；三份主要語料中唯一一份）**
- 規模：1065 張，全部 1024×1024，Pascal VOC 標註，兩位獨立標註者

| 它的類別 | 對到本表 | 注意 |
|---|---|---|
| `crack` | `structural/structural_fracture`、`structural/tip_damage` | **不是近身裂縫**。取樣的 6 張全是整機照上的葉片斷損（輪轂與塔架入鏡），依 §1.2 全數拒收（0/6 通過取像判定）。這一類在 Mode B 的輸入定義下不存在，要由 Mode A 處理。 |
| `craze` | `structural/longitudinal_crack`、`surface/leading_edge_erosion` | 名稱是龜裂，但目視多為**開放型裂損與前緣缺口**，不是本表定義的細密網狀 `gelcoat_crack_network`。取樣 2/6 通過取像判定。 |
| `hide_craze` | `surface/gelcoat_crack_network`、`structural/longitudinal_crack` | 細長線狀、標註框多為長條。與 craze 是兩位標註者最常互換的一對（40 次分歧）。 |
| `corrosion` | `healthy/contamination`、`surface/corrosion_metal_part` | **混了兩件事**：部分是生物附著（綠藻）——依本表屬 contamination 不是損傷；部分是金屬件鏽蝕。且有數張拍的是**塔架不是葉片**。與 surface_injure 是第二常互換的一對（52 次分歧）。 |
| `surface_injure` | `surface/coating_peeling` | — |
| `thunderstrike` | `environmental/lightning_damage` | 本表最乾淨的對照。近身、中心明確、碳化特徵清楚。 |

**這份語料缺什麼**：

- **沒有健康照**：1065 張每一張都至少有一個缺陷框。§6 第 4 條要求測試集至少 1/3 是健康照且含易誤判的正常結構——這份語料一張都給不出來，誤報率無從量。
- **沒有正常結構標註**：接縫、LEP 邊緣、VG 板、避雷接點都沒有被正面標記，所以誤報落在哪裡無從歸因。
- **沒有尺度**：1065 張只有 3 張還留著 EXIF、1 張有焦距。§9.4 因此適用於幾乎全部——用這份語料訓出來的模型不得輸出 IEA Level。
- **沒有葉片編號**：檔名是流水號，§6 第 1 條的「按葉片切」在這份語料上執行不了，只能退而按時間戳或飛行批次粗分，且要先確認可行。

**標註者間一致度**：兩位標註者的一致度是任何模型在這份語料上的**可量測上限**。超過它的分數是在報雜訊。

| 量 | 值 |
|---|---|
| A 的標註框 | 1584 |
| B 的標註框 | 1543 |
| IoU ≥ 0.5 配對成功 | 1543 |
| 定位一致率 | 97.4% |
| 配對成功者的類別一致率 | **94.0%** |
| Cohen's kappa | 0.897 |

全部 92 次類別分歧只落在兩對上：surface_injure↔corrosion 52 次、hide_craze↔craze 40 次。這是兩個獨立的人給的證據，說明這兩條界線畫得不夠利。

---

## 7. 紀錄格式

B1 的評估腳本吃這個格式。blade_id 與 flight_id 是**必填**——§6.1 的「按葉片切不按照片切」靠它們執行，不是靠記得。

必填：`image_id`、`blade_id`、`flight_id`、`source`、`licence`、`photo_label`、`annotator`

| 欄位 | 內容 |
|---|---|
| `image_id` | 字串，語料內唯一 |
| `blade_id` | 字串，哪一支葉片。**必填**，切分依據 |
| `flight_id` | 字串，哪一次飛行／哪一次拍攝。**必填**，切分依據 |
| `source` | 語料來源代號（dtu / blade30 / openverse / field） |
| `licence` | 授權字串，例如 CC BY 4.0。NC 的不得進訓練集 |
| `intake` | {accepted: bool, reason: str, blade_fraction: float} |
| `scale` | {cm_per_px: float\|null, method: exif\|reference_object\|unknown, focal_35mm_eq: float\|null, distance_m: float\|null} |
| `quality_flags` | quality_flags 的 id 陣列 |
| `photo_label` | healthy \| surface \| environmental \| structural \| uncertain \| reject \| unreviewed |
| `regions` | [{bbox:[x,y,w,h], class, subclass, is_defect, severity, iea_level, note}] |
| `annotator` | 標註者代號。**不得填演算法輸出**（§9.3） |

