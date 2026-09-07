# InduSpect AI — 工業設備智慧巡檢系統

> 最後更新：2026-09-06
> 開發團隊：doflab 劉瑞弘老師研究團隊

把「紙本定檢表 + 現場拍照 + 人工判定 + 手寫報告」的傳統巡檢流程，換成
**上傳定檢表 → 一鍵自動檢測 → AI 讀值 → 法規自動判定 → 匯出申報格式**。

現場網路差、廠區禁止上雲、判定要有法規依據——這三件事決定了系統的架構：
**判定完全離線、讀值分層降級、報告在裝置端產生**。

---

## 目錄

- [核心功能](#核心功能)
- [使用方法](#使用方法)
- [運作原理](#運作原理)
- [技術棧](#技術棧)
- [快速開始](#快速開始)
- [測試](#測試)
- [文件導覽](#文件導覽)

---

## 核心功能

### 主線：定檢表 pipeline（Flutter App）

| 功能 | 說明 |
|------|------|
| **定檢表結構辨識** | 上傳客戶原本的 Excel / Word / 紙本照片，AI + 規則引擎自動分析表單結構，產生欄位對應與拍照任務清單 |
| **一鍵自動檢測** | 引導拍照 → 批次 AI 分析 → 讀值自動回填 → 自動產生 AI 總結報告，全程無需逐項操作 |
| **法規自動判定（離線）** | 內建 56 條台灣法規標準，讀值進來自動判合格／不合格／警告並附法規依據；**含單位換算**（kΩ/MΩ 等數量級防呆），純本機執行、零延遲 |
| **分層降級讀值** | 聯網走 Gemini 精判；離線走裝置端 ML Kit OCR（數位錶、銘牌）；兩者皆不可用時保留手動填寫 |
| **拍照品質閘門** | 純本機偵測模糊（Laplacian）、過曝、欠曝、錶面反光，不合格當場提示重拍並給具體建議 |
| **申報用 PDF 報告** | 裝置端純 Dart 產生，離線可用；含判定統計、逐項法規依據與單位換算、AI 總結、照片附件 |
| **原格式回填** | 後端可用時把讀值與判定回填客戶原本的 Excel / Word；不可用時降級匯出 JSON 摘要 |
| **歷史紀錄** | GPS 定位、可編輯標題、搜尋、重新分享；離線分享佇列（無網路時暫存，連線後自動送出） |

### 獨立模組：風力機葉片地面目視檢測

用一般手機在地面拍葉片，做「有沒有明顯壞掉、形狀有沒有跟另外兩片不一樣、轉起來有沒有異常」的篩檢。
**與定檢表 pipeline 平行、不共用流程**（資產驅動 vs 表單驅動）。
App 端已可跑完整流程（Phase 1，表面層）：主頁第三個入口
「風機葉片檢測」→ 選風機 → 引導拍攝 → 演算法量測 → **人工確認** → PDF 報告。

- 表面層：前緣侵蝕粗糙度、裂縫候選（長焦分區段照）— **App 端已實作**
- 幾何層：三片葉片中心線曲率互比、後緣開裂、附加件缺失 — 原型完成，Dart 移植排 Phase 2
- 動態層：轉速、三片葉尖軌跡一致性、六點鐘自動取幀（轉動影片）— 原型完成，排 Phase 3
- 聲音層：逐片寬頻噪音（前緣侵蝕）、窄頻哨音（後緣裂縫）——指出「哪一片在叫」— 原型完成
- 周邊層：塔架油漬、機艙罩破損
- 交付物：App 端 PDF 報告；原型端圖文檢測報告（單一自帶內容 HTML，含疊圖、圖表、數值表）

報告**不輸出「合格」判定**，而且會明寫這次跑了哪一層、沒跑哪一層——手機地面拍攝屬
Level 1 篩檢，「未檢出異常」不等於「整支葉片都查過了」。所有發現預設為「待人工確認」。

規格見 [`BLADE_INSPECTION_SPEC.md`](BLADE_INSPECTION_SPEC.md)，原型與可偵測門檻見 [`blade_prototype/`](blade_prototype/)。

> 目前狀態：75 張公開真實照片實測。原本「有雲就整個垮掉」（命中 1/13）的天空模型瓶頸已
> 換成**局部天空模型**解決——整體輪轂命中 **23/30**、有雲 **10/13**、遮罩全空 4 → 0。
> 逆光仍是硬限制。**還沒有真實手機拍的葉片語料**，所以葉片拍攝閘門目前刻意保守
> （只擋讀不到檔與整張過暗），原始量測值全部存進 DB 供外業回來重新定門檻。
> 實測結果與失敗案例見
> [`blade_prototype/REAL_IMAGE_VALIDATION.md`](blade_prototype/REAL_IMAGE_VALIDATION.md)。

### 目前隱藏的功能

快速分析、範本系統、設備管理、雲端同步、RAG 管理等已有實作但未連結到主頁，非當前開發重點。

---

## 使用方法

App 主頁三個入口：**開始檢測**、**歷史紀錄**、**風機葉片檢測**。前兩個是定檢主線，第三個是獨立的平行流程。

### 開始檢測（4 步驟）

**步驟 1 — 上傳定檢表**
選擇客戶原本的 Excel / Word 檔或紙本照片。系統辨識表單結構，產生欄位對應與拍照任務清單。
後端不可用時自動改用本機解析（此時匯出可能無法回填原始格式，會有明確提示）。

**步驟 2 — 逐項拍照檢測**
可選「一鍵自動檢測」批次跑完，或逐項拍照。每張照片流程如下：

1. 拍照後先過品質閘門，模糊／過曝／反光會提示重拍並說明怎麼補救。
2. 探測網路是否真的通（廠區常見連上 AP 但沒有 uplink），不通就直接走離線路徑，不空等逾時。
3. 聯網 → Gemini 分析，回傳設備類型、讀值、狀況評估、是否異常。
4. 離線 → 裝置端 OCR 抽數位錶／銘牌讀值。
5. 讀值進判定引擎，自動帶出合格／不合格／警告與法規依據。

**步驟 3 — 預覽確認**
所有欄位都可編輯。AI 判斷過的項目會標示來源（雲端精判 / 離線 OCR / 本地判定），人工修改會覆蓋 AI 結果。

**步驟 4 — 產生報告**
自動匯出回填後的定檢表與 AI 總結報告。完成頁可再匯出**申報用 PDF**（含照片與法規判定），以及分享給客戶。
沒有網路時分享會進離線佇列，連線後自動送出。

### 歷史紀錄

依 GPS 位置與時間列出過往檢測，可改標題、搜尋、重新匯出 PDF 或重新分享。

### 風機葉片檢測（5 步驟）

**步驟 1 — 選風機**
葉片檢測跟著一台風機累積紀錄，不是跟著一張表單。選同一台，下次到場才比對得起來。

**步驟 2 — 引導拍攝**
格位清單（正視全機、側視全機、每片葉片的根／中／尖三段）。每個格位會顯示**上次同格位的照片**
與**到上次拍攝點的 GPS 距離**——兩次的取景要接近，比對才有意義。
用系統相機拍（分區段照要用 5x 光學長焦），照片**原尺寸保存不壓縮**。
拍完立刻判定品質：讀不到檔或整張過暗會擋下，其餘只提醒。

**步驟 3 — 演算法分析**
表面層前緣粗糙度：對邊緣輪廓擬合平滑基線，殘差即粗糙度，前緣 rms ÷ 後緣 rms 是主判據
（同一張照片內互比，不需絕對校準）。數值由演算法算，AI 只判斷「這是缺陷還是正常結構」。

**步驟 4 — 人工確認**
逐筆確認或駁回，可加備註。**沒有人簽過的發現不具效力。**

**步驟 5 — 報告**
PDF 報告。**不下「合格」判定**，並明寫這次跑了哪一層、沒跑哪一層——
手機地面拍攝屬 Level 1 篩檢，「未檢出異常」不等於「整支葉片都查過了」。

### 風機葉片檢測（原型階段，命令列）

```bash
cd blade_prototype
python -m blade_proto analyze-still  IMG_1234.JPG --rotor-radius-m 60 --out r.json --overlay o.png
python -m blade_proto analyze-edge   IMG_1240.JPG --cm-per-px 0.4 --le top --out e.json
python -m blade_proto analyze-video  VID_0001.MP4 --step 2 --out v.json --frames-dir six/
python -m blade_proto analyze-audio  VID_0001.MP4 --rpm 12 --out a.json

# 一次跑完並產生圖文報告（單一 HTML，含疊圖照片、圖表、數值表；可列印成 PDF）
python -m blade_proto case --asset WTG-07 --still IMG_1234.JPG --edge IMG_1240.JPG \
  --video VID_0001.MP4 --view side --out-dir cases/WTG-07/
```

詳細用法與外業拍攝協定見 [`blade_prototype/README.md`](blade_prototype/README.md)。

---

## 運作原理

### 四層讀值架構

判定與讀值刻意分開，因為兩者的離線可行性差很多。

```
拍照
 ├─ Tier 1a【離線・全機型】ML Kit Text Recognition
 │    數位錶讀值 / 銘牌 OCR → 有數值 → 直接進判定
 ├─ Tier 1b【離線・高階機】端側 VLM（規劃中）
 │    外觀異常初判，標記「離線初判」，聯網後覆核
 ├─ Tier 0 【離線・全機型】判定引擎（Dart）
 │    56 條標準 + 單位換算 → 合格／不合格／警告 + 法規依據
 └─ Tier 2 【聯網】Gemini Flash 精判 + Pro 產生報告
```

**為什麼判定要離線**：判定是純規則邏輯，沒有 AI 也能做。移到裝置端後，「離線 → 待判定 → 重試」的整段補償邏輯退化成備援，後端不再是判定的單點故障，也省下每次判定的往返延遲。

**為什麼讀值不靠端側小模型**：CVPR 2026 的 MeasureBench 基準顯示，指針式儀表讀值對所有 VLM 都是弱項，小模型更差。所以指針錶留在雲端，端側只做它擅長的事（OCR、品質把關）。詳見 [`LAUNCH_PLAN.md`](LAUNCH_PLAN.md) §5。

### 其他關鍵設計

- **結構化輸出**：強制 AI 回傳嚴格 JSON，確保讀值能被程式準確解析，不受文字描述影響。
- **標準資料單一來源**：法規標準以 `backend/app/data/inspection_standards.py` 為唯一來源，匯出 JSON 供 App 內嵌，有同步守門測試防止兩份資料漂移。
- **離線優先儲存**：SQLite（目前 v4）存檢測紀錄、照片路徑、判定結果；照片存檔案系統，路徑以 JSON array 序列化。

---

## 技術棧

### Flutter App（`flutter_app/`，主要開發版本）

- **框架**：Flutter 3.x（Android / iOS）、Dart 3.2+
- **AI**：`google_generative_ai`（Gemini Flash 圖像分析、Pro 報告生成），模型 ID 可在設定頁覆寫
- **端側 ML**：`google_mlkit_text_recognition`（離線 OCR，含中文）
- **本地儲存**：`sqflite`（SQLite v4，檢測紀錄與判定）+ `shared_preferences`（設定與偏好）
- **影像**：`image_picker`、`camera`、`image`（品質閘門的 Laplacian 計算）
- **報告**：`pdf` + 內嵌 Noto Sans TC 字型子集（離線產生繁中 PDF）
- **定位**：`geolocator`

### 後端（`backend/`，FastAPI）

- Python 3.11 + FastAPI，25 個端點（表單結構分析、欄位對應、原格式回填、報告、RAG、讀值判定）
- Gemini 呼叫統一走 `app/services/gemini_client.py`（`google-genai` SDK，延遲建立 client、依 key 快取）
- 部署：Docker / Cloud Run（`cloudbuild.yaml` 已改 Artifact Registry + Secret Manager）
- 也可跑在廠區內網的 mini-PC，供禁止照片上雲的場域使用

### 葉片模組原型（`blade_prototype/`）

- Python + NumPy / SciPy / OpenCV，無深度學習、無 AI 呼叫
- 純演算法：分割、結構定位、中心線幾何、邊緣粗糙度、影片葉尖追蹤

### 已凍結

Web 原型（React + TypeScript）已由 Flutter 版取代，原始碼在 [`legacy/`](legacy/)，不再維護。

---

## 快速開始

### Flutter App

```bash
cd flutter_app
flutter pub get

cp .env.example .env
# 編輯 .env：GEMINI_API_KEY=your_key
#            BACKEND_API_URL=https://your-backend   # 選填，未設定則走本機解析

flutter run
flutter build apk --release        # Android
flutter build ios --release        # iOS（需 macOS）
```

Release 簽署需自備 keystore 並設定 `key.properties`，詳見 [`flutter_app/DEVELOPMENT.md`](flutter_app/DEVELOPMENT.md)。

### 後端

```bash
cd backend
pip install -r requirements.txt
export GEMINI_API_KEY=your_key
uvicorn app.main:app --reload      # http://localhost:8000/docs
```

### 葉片模組原型

```bash
cd blade_prototype
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
python -m blade_proto sensitivity --quick --out SENSITIVITY.md
```

---

## 測試

```bash
cd flutter_app && flutter test                                              # 211 tests
cd backend && GEMINI_API_KEY=ci-fake-key pytest tests/ --asyncio-mode=auto  # 191 tests
cd blade_prototype && pytest                                                # 76 tests
```

三者皆在 CI（`.github/workflows/ci.yml`）逐 PR 執行；`flutter analyze` 為硬性門檻（warning 級以上擋 PR）。

改動法規標準資料後必須重新匯出 JSON，否則守門測試會失敗：

```bash
python backend/scripts/export_standards.py
```

---

## 文件導覽

### 讀這個就好

| 文件 | 說明 |
|------|------|
| [README.md](README.md) | 本文件 — 專案總覽、使用方法、快速開始 |
| [CLAUDE.md](CLAUDE.md) | 開發規則速查（關鍵檔案表、慣例、已知問題） |
| [LAUNCH_PLAN.md](LAUNCH_PLAN.md) | **產品化評估與 90 天上線計畫**（含離線 AI 深度評估、目標市場、風險） |
| [ROADMAP.md](ROADMAP.md) | 功能規劃藍圖 |
| [flutter_app/DEVELOPMENT.md](flutter_app/DEVELOPMENT.md) | Flutter 開發指南（架構、DB schema、測試、變更紀錄） |

### 模組規格

| 文件 | 說明 |
|------|------|
| [BLADE_INSPECTION_SPEC.md](BLADE_INSPECTION_SPEC.md) | 風力機葉片地面目視檢測模組規格 |
| [blade_prototype/README.md](blade_prototype/README.md) | 葉片模組演算法原型用法 |
| [blade_prototype/SENSITIVITY.md](blade_prototype/SENSITIVITY.md) | 葉片模組可偵測門檻（合成影像量化） |
| [blade_prototype/REAL_IMAGE_VALIDATION.md](blade_prototype/REAL_IMAGE_VALIDATION.md) | 葉片模組真實影像實測：成功率、失敗案例集、拍攝品質閘門 |
| [AUTO_FILL_SYSTEM.md](AUTO_FILL_SYSTEM.md) | 定檢表自動回填系統設計 |
| [TEMPLATE_SYSTEM_SPEC.md](TEMPLATE_SYSTEM_SPEC.md) | 範本系統規格（目前隱藏功能） |

### 設計與歷史文件

| 文件 | 說明 |
|------|------|
| [aimodel.md](aimodel.md) | AI 模型整合與 Prompt 工程規範 |
| [arch.md](arch.md) | 系統架構設計（後端規劃） |
| [database.md](database.md) | 資料庫設計 |
| [ui.md](ui.md) | UI/UX 設計規範 |
| [feature_enhancements.md](feature_enhancements.md) | 準確度優化策略 |
| [CLOUD_RUN_ASSESSMENT.md](CLOUD_RUN_ASSESSMENT.md) | Cloud Run 部署評估 |
| [FLUTTER_MIGRATION_PLAN.md](FLUTTER_MIGRATION_PLAN.md) | Web → Flutter 遷移計畫（已完成） |
| [AISTUDIO_REBUILD_SPEC.md](AISTUDIO_REBUILD_SPEC.md) | 早期 AI Studio 版規格（歷史） |

---

## 聯絡

**專案負責人**：dofliu
**技術支援**：[GitHub Issues](https://github.com/dofliu/InduSpect/issues)
