系統架構設計
本系統採用現代化的三層式無伺服器架構，以確保高可擴展性、高彈性與成本效益。架構圍繞 Google Cloud 平台構建，並採用事件驅動的設計模式。

1. 高層架構圖
+---------------------------+       +---------------------------+       +-----------------------------+
|    Presentation Layer     |       |     Business Logic Layer  |       |         Data Layer          |
|  (Flutter Mobile App)     |       |    (Serverless on GCP)    |       |      (GCP Storage)          |
+---------------------------+       +---------------------------+       +-----------------------------+
| - Firebase Authentication |       | - API Gateway             |       | - Cloud Storage             |
| - Camera Integration      |------>|   - Manages API calls     |<----->|   - Stores images & reports |
| - Offline Storage (SQLite)|       |                           |       +-----------------------------+
| - Task Checklist UI       |       | - Cloud Run (Microservices) |     | - Firestore (NoSQL DB)      |
| - Data Review & Override  |       |   - auth-service          |<----->|   - Stores inspection data  |
+---------------------------+       |   - task-service          |       |   - User profiles           |
        /|\                     |   - upload-service        |       +-----------------------------+
         |                      |   - processing-service    |       | - Vertex AI                 |
         | (Secure Upload URL)    |                           |<----->|   - Gemini API access       |
         |                      +---------------------------+       +-----------------------------+
         |                              /|\       |
         |                               |       | (Event Trigger)
         | (Direct Upload)               | (AI Analysis) |
         |                             +---------------------------+
         +---------------------------->|        Eventarc           |
                                       +---------------------------+

2. 各層詳細設計
2.1 表現層 (Presentation Layer) - 行動前端
技術棧: Flutter (用於跨平台開發 iOS/Android)。

核心組件:

使用者認證: 整合 Firebase Authentication SDK，提供電子郵件/密碼及 Google 登入方式。

任務管理: 從 Firestore 實時讀取分配的巡檢任務，並以檢查表 (Checklist) 形式呈現。

相機功能: 使用 camera 套件，提供穩定的拍照功能，並允許控制閃光燈和對焦。

離線儲存: 使用 sqflite 或類似的本地資料庫，暫存未上傳的圖像檔案路徑和巡檢數據。設計一個背景同步服務，在網路恢復時觸發上傳流程。

安全上傳:

App 向後端的 upload-service 請求一個預簽章 (pre-signed) URL。

App 使用此 URL 將圖像檔案直接、安全地從客戶端上傳到 Google Cloud Storage。此方法可避免大型檔案流經後端伺服器，從而提高效率並降低成本。

2.2 業務邏輯層 (Business Logic Layer) - 無伺服器後端
技術棧: Python (配合 FastAPI 或 Flask 框架)，容器化後部署於 Cloud Run。

核心服務 (Microservices on Cloud Run):

auth-service: 處理使用者註冊、登入，並核發 JWT 權杖。

inspection-task-service: 提供 CRUD API，用於管理巡檢任務與檢查表。

upload-service: 產生用於客戶端直接上傳至 Cloud Storage 的預簽章 URL。

processing-service: 核心 AI 處理服務。此服務由 Eventarc 觸發。

工作流程觸發:

當新圖像成功上傳到 Cloud Storage 指定的儲存桶 (bucket) 後。

Cloud Storage 會發出一個事件通知。

Eventarc 捕獲此事件，並觸發 processing-service 的一個實例來處理該圖像。

2.3 數據層 (Data Layer) - 雲端儲存與 AI
物件儲存:

服務: Google Cloud Storage。

用途:

儲存由巡檢員上傳的原始圖像。

儲存由系統生成的最終 PDF 報告。

結構: 建議使用 images/{job_id}/{point_id}.jpg 和 reports/{job_id}.pdf 的路徑結構。

資料庫:

服務: Firestore (NoSQL)。

理由: 其靈活的 schemaless 結構非常適合儲存半結構化的 AI 輸出數據，並且能與 Flutter 前端實現無縫的即時數據同步。

用途: 儲存使用者資訊、巡檢任務定義、以及由 AI 分析得出的結構化巡檢結果。

AI 模型服務:

服務: Vertex AI。

用途: 提供對 gemini-2.5-pro 和 gemini-2.5-flash 模型的企業級、安全的 API 存取端點。processing-service 將透過 Vertex AI SDK 與 Gemini 模型進行互動。