# flutter_app — InduSpect AI 行動應用

這是專案的**主要開發版本**。根目錄的 `legacy/` 是已凍結的 React 網頁原型，不再維護。

| 你要找的 | 去這裡 |
|---|---|
| 系統做什麼、為什麼這樣做 | [`../README.md`](../README.md) |
| 怎麼操作（現場使用者） | [`../docs/USER_GUIDE.md`](../docs/USER_GUIDE.md) |
| **架構、DB schema、測試清單、變更紀錄** | [`DEVELOPMENT.md`](DEVELOPMENT.md) |
| 開發規則、關鍵檔案表、已知問題 | [`../CLAUDE.md`](../CLAUDE.md) |

---

## 平台現況

**目前只有 `android/`。** `ios/` 目錄尚未建立——iOS 建置指令在本機跑不起來，
要先 `flutter create --platforms=ios .`，並補上 `NSCameraUsageDescription`、
`NSPhotoLibraryUsageDescription`、`NSLocationWhenInUseUsageDescription`、
`NSMicrophoneUsageDescription`（葉片聲學層要錄音）。

`android/app/src/main/kotlin/.../BladeVideoFrames.kt` 是影片抽幀的原生實作，
**CI 不建 APK 所以它從未被編譯過**——第一次實機要先確認它 build 得起來。

---

## 跑起來

```bash
flutter pub get

cp .env.example .env
# GEMINI_API_KEY=your_key
# BACKEND_API_URL=https://your-backend   # 選填，未設定則走本機解析

flutter run
flutter build apk --release
```

Release 簽署要自備 keystore 並設定 `key.properties`，見 [`DEVELOPMENT.md`](DEVELOPMENT.md)。

## 檢查

```bash
python3 scripts/audit_dead_ends.py   # 死角查核，CI 排在 analyze 之前
flutter analyze                      # warning 級以上擋 PR
flutter test                         # 504 tests
```

`scripts/audit_dead_ends.py` 擋的是「新的 service 公開方法沒人叫」與「新的 DB 欄位只讀不寫
或只寫不讀」。刻意保留的死角寫進 `scripts/audit_allowlist.json` 並附理由；
**問題修好後要把條目移除，過期條目一樣紅。**

## 疑難排解

| 症狀 | 先看這個 |
|---|---|
| Gemini 呼叫失敗 | `.env` 的 `GEMINI_API_KEY`、配額、設定頁的模型 ID 是否被覆寫成不存在的值 |
| 相機打不開 | `AndroidManifest.xml` 的 `CAMERA` 權限；葉片模組用的是**系統相機**不是 `camera` plugin |
| 錄音錄不到 | 裝置不支援 WAV 時會**直接不開始錄**（刻意的——否則會靜靜錄成壓縮格式，等分析才發現解不開） |
| 照片存不下來 | 應用文件目錄可寫性；photoPaths 以 JSON array 序列化，舊資料是 `|||` 分隔 |
| 相依裝不起來 | `flutter clean && flutter pub get` |
| 葉片影片抽不到幀 | 只有 Android 支援；**沒有音軌的影片解不了**（抽幀時刻由音軌決定） |
