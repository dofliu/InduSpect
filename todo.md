# 開發與部署路線圖

> **最後更新**：2026-08-31
> 這份文件只保留**階段層級**的進度。逐項待辦看 [LAUNCH_PLAN.md](LAUNCH_PLAN.md) 的 90 天計畫，
> 功能藍圖看 [ROADMAP.md](ROADMAP.md)，接手筆記看 [docs/handover/session-handover.md](docs/handover/session-handover.md)。

---

## ✅ 第一階段：原型與可行性驗證（已完成）

React 網頁原型驗證多模態 AI 能從設備照片抽出結構化資料，並取得關係人對流程的認可。
原型已凍結於 [`legacy/`](legacy/)。

## ✅ 第二階段：MVP 與工程可上線化（已完成）

- [x] Flutter App：完整檢測 pipeline + 歷史紀錄兩大核心功能
- [x] FastAPI 後端：表單結構分析、原格式回填、法規判定端點
- [x] **法規判定引擎**：56 條標準、單位換算防呆、條文引用
- [x] **離線三層架構**：拍照品質閘門 → 裝置端 OCR → 離線法規判定
- [x] **工程紀律**：Flutter 137 + 後端 172 測試全套進 CI、analyze 0 warning
- [x] **上線前置**：Release 簽署、後端 API 認證、錯誤淨化、隱私政策草稿

## ⏳ 第三階段：實機驗證與試點（進行中）

**這是目前所在階段。多數項目需實機或帳號操作，非程式面工作。**

- [ ] **實機端到端驗證**（[#43](https://github.com/dofliu/InduSpect/issues/43)）
  - [ ] 完整流程：上傳 Excel → 一鍵自動檢測 → 法規判定回填 → 匯出 → 分享
  - [ ] 斷網情境：驗證走本地判定與 OCR（而非「待判定」），恢復網路後自動分享
  - [ ] R8 開啟後的 release build 煙霧測試
  - [ ] 拍照品質閘門門檻以現場實拍照片校準
- [ ] **上架準備**
  - [ ] 產生 upload keystore（見 [flutter_app/ANDROID_DEPLOYMENT.md](flutter_app/ANDROID_DEPLOYMENT.md)）
  - [ ] 隱私政策發布到公開 URL（[docs/PRIVACY_POLICY.md](docs/PRIVACY_POLICY.md)）
  - [ ] Play Data Safety 表 + 內部測試軌
- [ ] **後端部署**：Cloud Run + Secret Manager（見 [CLOUD_RUN_ASSESSMENT.md](CLOUD_RUN_ASSESSMENT.md)）
- [ ] **監控**：Crashlytics 或 Sentry
- [ ] **試點計畫**：2–3 場域、5–10 名巡檢員
  - 量測：單場總時間、AI 讀值免修改率（目標 ≥70%）、判定引用正確率、週活躍留存

**退出條件**：至少 1 個場域願意付費或簽 LOI；論文所需實驗數據齊備。

## 🚀 第四階段：規模化（規劃中）

依試點回饋決定走向：管理式訂閱 SaaS（後端代 key + 帳號 + 計費）或擴大試點。
團隊協作、設備管理、地端部署產品化等，見 [ROADMAP.md](ROADMAP.md) 中期規劃。
