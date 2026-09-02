# InduSpect AI — 工業設備智慧巡檢系統

拍照 → AI 讀值 → **台灣法規自動判定** → 回填你原本的定檢表。

> **狀態**：功能開發完成，工程面已達可上線水準；**尚待實機端到端驗證與上架**。
> 詳見 [LAUNCH_PLAN.md](LAUNCH_PLAN.md)（產品化評估與 90 天行動計畫）。
> 最後更新：2026-08-31

| 指標 | 現況 |
|------|------|
| 測試 | Flutter **137** / 後端 **172 pytest**，全套進 CI |
| 靜態分析 | `flutter analyze` **0 error / 0 warning** |
| 法規標準庫 | **56 條**（電氣 / 消防 / 機械 / 壓力），單一來源、CI 守門 |
| 離線能力 | 拍照品質閘門 → OCR 讀值 → 法規判定 → 分享佇列，**全程可斷網** |

---

## 為什麼做這個

台灣每年數十萬場次的法定定期檢查，流程幾乎沒有數位化：

- 現場抄錶，回辦公室再謄寫一次；**漏抄一項就得重跑一趟**
- 「這個數字算合格嗎？」——法規門檻與條文依據往往只存在老師傅的記憶裡
- **單位差一個數量級，安全判定就翻轉**（500 kΩ 與 0.5 MΩ）

InduSpect 把這段流程收進一支 App，而且**交付物仍是客戶原本的 Excel / Word**——導入不需要改變任何習慣。

---

## 核心功能（只有兩個）

其餘功能（快速分析、範本系統、設備管理、雲端同步等）目前為隱藏狀態，非核心開發重點。

### 1. 完整檢測 Pipeline
上傳定檢表 → 一鍵自動檢測（引導拍照 → AI 批次分析 → 法規判定 → 自動回填）→ AI 摘要報告 → 分享（離線暫存）

### 2. 歷史紀錄
GPS 定位與地名、可編輯標題、標題/地點搜尋、重新匯出與分享；法規判定結果隨紀錄留存作為稽核依據。

---

## 使用說明

### 步驟 1：上傳定檢表
首頁點「**開始檢測**」，選擇 `.xlsx` / `.xls` / `.docx` 定檢表。系統解析欄位結構並產生檢測項目清單，同時在背景取得 GPS 定位。

> 後端不可用時會自動改用**本機解析**並明確提示（此時匯出可能無法回填原始格式）。

### 步驟 2：一鍵自動檢測
點「**自動檢測**」進入引導式批次拍照。每個項目會依欄位型別顯示專業拍攝提示（例如壓力欄位提示「確保指針位置和刻度清晰可見」）。

**拍照品質閘門**：照片模糊、光線不足或錶面反光時，會即時提示問題與具體建議（對焦重拍／開手電筒補光／側身避開反光），可選擇重拍或仍要使用。

拍完後自動進行 AI 批次分析（並發上限 3），顯示即時進度。也可切換**手動填寫模式**。

### 步驟 3：法規判定與預覽
量測欄位會自動帶出**合格 / 不合格 / 警告**與法規依據。判定前會先把讀值換算成法規單位——例如 `500 kΩ` 換算為 `0.5 MΩ` 後與 `≥ 1.0 MΩ` 比較，正確判為不合格。

預覽頁顯示統計摘要與逐項結果，所有欄位都可人工修改。

### 步驟 4：匯出
系統嘗試把結果回填到**原始表格格式**；失敗時改匯出 JSON 檢測摘要並明確告知。

### 步驟 5：完成與分享
自動產生 AI 摘要報告，可分享表單或報告。**離線時自動排入佇列**，恢復網路後自動送出。

### 離線作業
| 階段 | 斷網時 |
|------|-------|
| 拍照／暫存 | 完全本機，每步寫入 SQLite |
| 品質檢查 | 本機運算，離線同樣有效 |
| AI 讀值 | 雲端不可用 → **裝置端 OCR**（ML Kit）抽數值 |
| 法規判定 | **內建 56 條標準離線判定**（非「待判定」） |
| 匯出／分享 | 本機匯出；分享排入佇列，恢復網路自動送出 |

---

## 技術特性

### 三層 AI 架構

| 層 | 位置 | 職責 |
|----|------|------|
| **Tier 0** | 離線 · 全機型 | 法規判定引擎（純規則、零 AI、零 token 成本） |
| **Tier 1a** | 離線 · 全機型 | 裝置端 OCR 讀值（數位錶、銘牌） |
| **Tier 2** | 聯網 | Gemini 精判（指針錶、複雜異常）＋ AI 摘要報告 |

法規資料為**單一來源**：後端 Python 為編輯來源，經 `backend/scripts/export_standards.py` 匯出 JSON 內嵌 App，CI 守門確保兩端永不漂移。

### 工程韌性
- **模型可換**：GA 穩定版模型；`參數 > .env > 內建預設` 三層覆寫，模型下架免改版
- **自帶 API Key**：資料與費用都在使用者自己的帳號
- **可達性探測**：廠區「連上 AP 沒有 uplink」時快速失敗走離線路徑，不空等逾時
- **地端部署**：資安敏感廠區可將後端整套部署到廠內網

### 技術棧
- **App**：Flutter 3.47 / Dart 3.13、Provider、SQLite（sqflite v4）、ML Kit OCR
- **後端**：FastAPI、openpyxl / python-docx（原格式回填）、pgvector（RAG）
- **AI**：Google Gemini（圖像分析與報告生成）
- **平台**：Android（主要）、Web / Windows（開發用）；iOS 未建置

---

## 快速開始

### App

```bash
cd flutter_app
cp .env.example .env          # 填入 GEMINI_API_KEY（與選填的 BACKEND_API_URL）
flutter pub get
flutter run                   # 或 flutter build apk --release
```

Release 建置需先設定簽署金鑰，見 [flutter_app/ANDROID_DEPLOYMENT.md](flutter_app/ANDROID_DEPLOYMENT.md)。

### 後端

```bash
cd backend
pip install -r requirements.txt
cp .env.example .env          # GEMINI_API_KEY、BACKEND_API_KEY、CORS_ALLOW_ORIGINS
uvicorn app.main:app --reload --port 8000
```

### 測試

```bash
cd flutter_app && flutter test                                        # 137 tests
cd backend && GEMINI_API_KEY=ci-fake-key pytest tests/ --asyncio-mode=auto   # 172 tests
```

> 修改 `backend/app/data/inspection_standards.py` 後**必須**執行
> `python backend/scripts/export_standards.py` 重新匯出 JSON，否則同步守門測試會失敗。

---

## 文件導覽

### 目前有效
| 文件 | 說明 |
|------|------|
| [LAUNCH_PLAN.md](LAUNCH_PLAN.md) | ★ 產品化評估、市場定位與 90 天行動計畫 |
| [CLAUDE.md](CLAUDE.md) | 專案開發規則與關鍵檔案索引 |
| [STATUS.yaml](STATUS.yaml) | 專案狀態摘要（進度、指標、下一里程碑） |
| [flutter_app/DEVELOPMENT.md](flutter_app/DEVELOPMENT.md) | App 架構、DB schema、測試清單、完整變更紀錄 |
| [flutter_app/ANDROID_DEPLOYMENT.md](flutter_app/ANDROID_DEPLOYMENT.md) | Android 建置與 Release 簽署 |
| [docs/PRIVACY_POLICY.md](docs/PRIVACY_POLICY.md) | 隱私權政策草稿（Play 上架用） |
| [CLOUD_RUN_ASSESSMENT.md](CLOUD_RUN_ASSESSMENT.md) | 後端部署就緒度評估 |
| [docs/handover/session-handover.md](docs/handover/session-handover.md) | ★ 接手筆記：現況與下一步 |
| [docs/media/](docs/media/) | App 真實截圖與介紹影片素材 |

### 歷史文件（僅供追溯）
`ROADMAP.md`（已重整）、`todo.md`（已重整）、`arch.md`、`aimodel.md`、`ui.md`、`prj.md`、`database.md`、`feature_enhancements.md`、`DEVELOPMENT_PLAN.md`、`REFACTORING_PLAN.md`、`FLUTTER_MIGRATION_PLAN.md`、`TEMPLATE_SYSTEM_SPEC.md`、`AISTUDIO_REBUILD_SPEC.md`、`COMPILE_CHECK_REPORT.md`、`legacy/`（React 原型）

> 這些文件多數停留在 2025-10 ～ 2026-03，內容可能與現況不符；**以上方「目前有效」清單為準**。

---

## 下一步

1. **實機端到端驗證**（[#43](https://github.com/dofliu/InduSpect/issues/43)）：完整流程 + 斷網情境 + R8 release build 煙霧測試
2. **拍照品質閘門門檻校準**：目前以合成影像校準，需用現場實拍照片調整
3. **上架準備**：upload keystore、隱私政策公開 URL、Play 內部測試軌
4. **後端部署**：Cloud Run + Secret Manager
5. **試點計畫**：2–3 場域，量測時間節省與 AI 讀值免修改率

---

**開發團隊**：doflab · 國立勤益科技大學 劉瑞弘研究團隊
**問題回報**：[GitHub Issues](https://github.com/dofliu/InduSpect/issues)
