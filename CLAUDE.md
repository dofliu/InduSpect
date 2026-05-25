# InduSpect AI — 專案開發規則

## 專案定位
工業設備智慧巡檢系統，Flutter 行動 App + FastAPI 後端 + Gemini AI。

## 核心功能（僅兩個）
1. **完整檢測 Pipeline**：上傳定檢表 → 一鍵自動檢測（引導拍照 → AI 批次分析 → 自動回填 → 自動 AI 報告）→ 分享（離線暫存）
2. **歷史紀錄**：GPS 定位、可編輯標題、搜尋、重新分享

其餘功能（快速分析、範本系統、設備管理、雲端同步等）目前為隱藏狀態，非核心開發重點。

## 關鍵檔案
| 檔案 | 用途 |
|------|------|
| `flutter_app/lib/screens/form_inspection_screen.dart` | ★ 核心：5 步驟檢測流程 |
| `flutter_app/lib/screens/unified_history_screen.dart` | 歷史紀錄 |
| `flutter_app/lib/screens/dashboard_screen.dart` | 主頁（2 入口） |
| `flutter_app/lib/models/form_inspection_record.dart` | 檢測紀錄 model |
| `flutter_app/lib/services/database_service.dart` | SQLite v3 CRUD |
| `flutter_app/lib/services/location_service.dart` | GPS 定位 |
| `flutter_app/lib/services/share_queue_service.dart` | 離線分享佇列 |
| `flutter_app/DEVELOPMENT.md` | 完整開發文件 |

## 開發慣例
- 路徑操作用 `package:path/path.dart`，不手動 `split('/')`
- photoPaths 用 JSON array 序列化（向後相容 `|||`）
- 日期用 ISO8601 字串存 SQLite
- DB migration 必須處理既有使用者升級路徑
- 繁體中文註解，技術術語保留英文

## 測試
```bash
flutter test test/form_inspection_record_test.dart test/database_service_test.dart test/inspection_item_state_test.dart test/photo_service_test.dart
```
目前 46 tests，全部通過。DB 測試使用 `sqflite_common_ffi` in-memory。

## 已知問題追蹤
- GitHub Issues #14-#19 已全數修復並關閉（2026-04-16）
- GitHub Issues #27-#28 自動化 AI 定檢功能增強（2026-04-17）
- 自動定檢標準判定單位換算修正（2026-05-25）：修正 kΩ/MΩ 單位數量級誤判與匹配假陽性，新增 `judge-readings` 端點。詳見 `flutter_app/DEVELOPMENT.md` 變更紀錄

## 既有 error（已修復）
- ~~`measurement.dart`: `sqrt` 未 import `dart:math`~~ → 已修復
- ~~`widget_test.dart`: `MyApp` 已不存在~~ → 已更新為 `InduSpectApp`
