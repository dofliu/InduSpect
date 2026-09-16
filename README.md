# InduSpect AI — 工業設備智慧巡檢系統

> 最後更新：2026-09-13 ・ 開發團隊：doflab 劉瑞弘老師研究團隊

把「紙本定檢表 + 現場拍照 + 人工判定 + 手寫報告」的傳統巡檢流程，換成
**上傳定檢表 → 一鍵自動檢測 → AI 讀值 → 法規自動判定 → 匯出申報格式**。

現場網路差、廠區禁止上雲、判定要有法規依據——這三件事決定了系統的架構：
**判定完全離線、讀值分層降級、報告在裝置端產生**。

**操作步驟看 [使用手冊](docs/USER_GUIDE.md)**，本文件講的是系統做什麼、為什麼這樣做、怎麼跑起來。

---

## 目錄

- [兩條產品線](#兩條產品線)
- [運作原理](#運作原理)
- [技術棧](#技術棧)
- [快速開始](#快速開始)
- [測試](#測試)
- [文件導覽](#文件導覽)

---

## 兩條產品線

### A. 定檢表 pipeline（主線）

| 功能 | 說明 |
|------|------|
| **定檢表結構辨識** | 上傳客戶原本的 Excel / Word / 紙本照片，AI + 規則引擎分析表單結構，產生欄位對應與拍照任務清單 |
| **一鍵自動檢測** | 引導拍照 → 批次 AI 分析 → 讀值自動回填 → 自動產生 AI 總結報告，全程無需逐項操作 |
| **法規自動判定（離線）** | 內建 56 條台灣法規標準，讀值進來自動判合格／不合格／警告並附法規依據；**含單位換算**（kΩ/MΩ 等數量級防呆），純本機執行 |
| **分層降級讀值** | 聯網走 Gemini 精判；離線走裝置端 ML Kit OCR（數位錶、銘牌）；兩者皆不可用時保留手動填寫 |
| **拍照品質閘門** | 純本機偵測模糊（Laplacian）、過曝、欠曝、錶面反光，不合格當場提示重拍並給具體建議 |
| **申報用 PDF 報告** | 裝置端純 Dart 產生，離線可用；含判定統計、逐項法規依據與單位換算、AI 總結、照片附件 |
| **原格式回填** | 後端可用時把讀值與判定回填客戶原本的 Excel / Word；不可用時降級匯出 JSON 摘要 |
| **歷史紀錄** | GPS 定位、可編輯標題、搜尋、重新分享；離線分享佇列（無網路時暫存，連線後自動送出） |

### B. 風力機葉片檢測（獨立模組）

與定檢表 pipeline **平行、不共用流程**（資產驅動 vs 表單驅動）。分成兩個模式，
差別在取像條件，不是在功能多寡：

| | **Mode A：地面整機**（已上線） | **Mode B：近身影像**（規格階段） |
|---|---|---|
| 輸入 | 整台風機入鏡的照片 + 影片 + 音軌 | 葉片填滿畫面的近身照 |
| 判斷依據 | **物理**：三片剪影互比、轉子尺度、逐片聲學互比 | **外觀**：學過的缺陷樣貌 + 領域知識 |
| 要不要缺陷樣本 | **不要**（互比與物理即可） | **要** |
| 能判到 | IEA Level 3 以上 | IEA Level 1–2 |
| 回答的問題 | 「這台要不要派人上去」 | 「這個損傷是什麼、多嚴重」 |
| 現況 | App 端完整實作（表面／幾何／聲音層） | 規格 + 分類表 + 語料實測完成，**未實作** |

**Mode A 已實作的層**：

- **表面層**：前緣侵蝕粗糙度（前緣 rms ÷ 後緣 rms，同一張照片內互比）
- **幾何層**：局部天空模型分割、結構定位、三片剪影互比
- **聲音層**：逐片寬頻位準／高頻占比／窄頻哨音互比，轉速由包絡自相關取得
- **動態層**：影片抽幀已由 Android 原生實作接上（`MediaMetadataRetriever`）

報告**不輸出「合格」判定**，而且會明寫這次跑了哪一層、沒跑哪一層——手機地面拍攝屬
Level 1 篩檢，「未檢出異常」不等於「整支葉片都查過了」。所有發現預設為「待人工確認」。

> **實測現況**：75 張公開真實照片。原本「有雲就整個垮掉」（命中 1/13）的天空模型瓶頸已
> 換成局部天空模型解決——整體輪轂命中 **23/30**、有雲 **10/13**、遮罩全空 4 → 0。逆光仍是硬限制。
> 另以 14 段真實地面影片驗證了**運動分割輪轂定位**（設計範圍內 5/5，同樣五段顏色法只有 1/5）。
> **還沒有真實手機拍的葉片語料**，所以葉片拍攝閘門刻意保守，原始量測值全部存進 DB 供外業回來重新定門檻。

### 目前隱藏的功能

快速分析、範本系統、設備管理、雲端同步、RAG 管理等已有實作但未連結到主頁，非當前開發重點。

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

**為什麼判定要離線**：判定是純規則邏輯，沒有 AI 也能做。移到裝置端後，「離線 → 待判定 → 重試」
的整段補償邏輯退化成備援，後端不再是判定的單點故障，也省下每次判定的往返延遲。

**為什麼讀值不靠端側小模型**：CVPR 2026 的 MeasureBench 基準顯示，指針式儀表讀值對所有 VLM
都是弱項，小模型更差。所以指針錶留在雲端，端側只做它擅長的事（OCR、品質把關）。
詳見 [`LAUNCH_PLAN.md`](LAUNCH_PLAN.md) §5。

### 其他關鍵設計

- **結構化輸出**：強制 AI 回傳嚴格 JSON，確保讀值能被程式準確解析，不受文字描述影響。
- **標準資料單一來源**：法規標準以 `backend/app/data/inspection_standards.py` 為唯一來源，
  匯出 JSON 供 App 內嵌，有同步守門測試防止兩份資料漂移。
- **離線優先儲存**：SQLite（目前 **v5**）存檢測紀錄、照片路徑、判定結果與葉片三表；
  照片存檔案系統，路徑以 JSON array 序列化。
- **死角查核進 CI**：新的 service 公開方法要有人叫、新的 DB 欄位要有人寫也要有人讀，
  否則 `flutter_app/scripts/audit_dead_ends.py` 會擋 PR。刻意保留的死角要在名單裡附理由，
  **過期條目一樣紅**。

---

## 技術棧

### Flutter App（`flutter_app/`，主要開發版本）

- **框架**：Flutter 3.27+（Android / iOS）、Dart 3.5+
- **AI**：`google_generative_ai`（Gemini Flash 圖像分析、Pro 報告生成），模型 ID 可在設定頁覆寫
- **端側 ML**：`google_mlkit_text_recognition`（離線 OCR，含中文）
- **本地儲存**：`sqflite`（SQLite v5）+ `shared_preferences`
- **影像**：`image_picker`、`camera`、`image`（品質閘門的 Laplacian 計算）
- **音訊**：`record`（葉片聲學層錄音；WAV／單聲道／自動增益與降噪一律關）
- **報告**：`pdf` + 內嵌 Noto Sans TC 字型子集（離線產生繁中 PDF）
- **定位**：`geolocator`
- **原生**：`android/.../BladeVideoFrames.kt`（platform channel，影片抽幀）

### 後端（`backend/`，FastAPI）

- Python 3.11 + FastAPI，25 個端點（表單結構分析、欄位對應、原格式回填、報告、RAG、讀值判定）
- Gemini 呼叫統一走 `app/services/gemini_client.py`（`google-genai` SDK，延遲建立 client、依 key 快取）
- 部署：Docker / Cloud Run（`cloudbuild.yaml` 已改 Artifact Registry + Secret Manager）
- 也可跑在廠區內網的 mini-PC，供禁止照片上雲的場域使用

### 葉片模組原型（`blade_prototype/`）

- Python + NumPy / SciPy / OpenCV，無深度學習、無 AI 呼叫
- 純演算法：分割、結構定位、中心線幾何、邊緣粗糙度、影片葉尖追蹤、逐片聲學、
  運動分割輪轂定位、太陽方位
- App 端的 Dart 實作與這裡逐 zone 交叉驗證到小數第三位

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
python -m blade_proto --help
```

命令列用法與外業拍攝協定見 [`blade_prototype/README.md`](blade_prototype/README.md)。

---

## 測試

```bash
cd flutter_app && python3 scripts/audit_dead_ends.py                        # 死角查核（CI 排在 analyze 之前）
cd flutter_app && flutter analyze && flutter test                           # 533 tests
cd backend && GEMINI_API_KEY=ci-fake-key pytest tests/ --asyncio-mode=auto  # 197 tests
cd blade_prototype && pytest                                                # 115 tests
```

三者皆在 CI（`.github/workflows/ci.yml`）逐 PR 執行；`flutter analyze` 為硬性門檻（warning 級以上擋 PR）。

改動法規標準資料後必須重新匯出 JSON，否則守門測試會失敗：

```bash
python backend/scripts/export_standards.py
```

改動葉片 Mode B 分類表（`blade_prototype/data/closeup_taxonomy.json`）後要重新渲染 markdown：

```bash
python blade_prototype/scripts/render_closeup_taxonomy.py
```

---

## 文件導覽

### 讀這個就好

| 文件 | 說明 |
|------|------|
| [README.md](README.md) | 本文件 — 專案總覽、運作原理、快速開始 |
| [docs/USER_GUIDE.md](docs/USER_GUIDE.md) | **使用手冊** — 操作步驟、離線行為、常見問題 |
| [CLAUDE.md](CLAUDE.md) | 開發規則速查（關鍵檔案表、慣例、已知問題） |
| [LAUNCH_PLAN.md](LAUNCH_PLAN.md) | 產品化評估與 90 天上線計畫（含離線 AI 深度評估、目標市場、風險） |
| [ROADMAP.md](ROADMAP.md) | 功能規劃藍圖 |
| [flutter_app/DEVELOPMENT.md](flutter_app/DEVELOPMENT.md) | Flutter 開發指南（架構、DB schema、測試、變更紀錄） |

### 模組規格

| 文件 | 說明 |
|------|------|
| [AUTO_FILL_SYSTEM.md](AUTO_FILL_SYSTEM.md) | 定檢表自動回填系統設計 |
| [BLADE_INSPECTION_SPEC.md](BLADE_INSPECTION_SPEC.md) | 葉片 **Mode A**：地面整機目視檢測規格 |
| [BLADE_CLOSEUP_SPEC.md](BLADE_CLOSEUP_SPEC.md) | 葉片 **Mode B**：近身影像檢測規格（未實作） |
| [BLADE_CLOSEUP_TAXONOMY.md](BLADE_CLOSEUP_TAXONOMY.md) | 葉片 Mode B 標註分類表（B0 產出，由 JSON 渲染） |
| [blade_prototype/README.md](blade_prototype/README.md) | 葉片模組演算法原型用法與外業流程 |

### 葉片模組的量化紀錄

| 文件 | 說明 |
|------|------|
| [blade_prototype/SENSITIVITY.md](blade_prototype/SENSITIVITY.md) | 合成影像上的可偵測門檻 |
| [blade_prototype/REAL_IMAGE_VALIDATION.md](blade_prototype/REAL_IMAGE_VALIDATION.md) | 75 張真實照片實測：成功率、失敗案例集、拍攝品質閘門 |
| [blade_prototype/INNOVATION_REVIEW.md](blade_prototype/INNOVATION_REVIEW.md) | 八個改進方向的文獻對照與離線驗證（太陽方位、運動分割輪轂定位） |
| [blade_prototype/CLOSEUP_BASELINE_REPORT.md](blade_prototype/CLOSEUP_BASELINE_REPORT.md) | Mode B 語料現況實測：授權盤點、可用率、cm/px 可得率、標註者一致度 |

### 其他

| 文件 | 說明 |
|------|------|
| [docs/PRIVACY_POLICY.md](docs/PRIVACY_POLICY.md) | 隱私權政策 |
| [docs/handover/session-handover.md](docs/handover/session-handover.md) | Session 接棒筆記 |
| [docs/routines/weekly-progress.md](docs/routines/weekly-progress.md) | 每週進度 routine 的執行規範 |
| [docs/archive/](docs/archive/) | **已完成或已被取代的文件**——留作決策紀錄，不要照著做 |

---

## 聯絡

**專案負責人**：dofliu
**技術支援**：[GitHub Issues](https://github.com/dofliu/InduSpect/issues)
