資料庫結構設計 (Supabase)
本文件定義了 Supabase (PostgreSQL) 資料庫的資料表 (Tables) 結構，用於儲存系統的所有數據。此設計採用關聯式數據模型。

數據模型
1. users 資料表
儲存應用程式使用者的基本資訊。此資料表與 Supabase Auth 的 users 表相關聯。

資料表名稱: users

欄位 (Columns):

id: UUID (主鍵, PRIMARY KEY, 關聯至 auth.users.id)

email: TEXT (使用者註冊的電子郵件)

display_name: TEXT (使用者的顯示名稱)

created_at: TIMESTAMPTZ (帳號建立時間, 預設為 now())

2. inspection_jobs 資料表
儲存巡檢工作的元數據。

資料表名稱: inspection_jobs

欄位 (Columns):

id: UUID (主鍵, PRIMARY KEY, 預設為 gen_random_uuid())

title: TEXT (巡檢工作的標題，例如："東廠區第一季度例行巡檢")

assigned_to: UUID (外鍵, FOREIGN KEY, 關聯至 users.id)

status: TEXT (工作狀態: "pending", "in_progress", "completed")

created_at: TIMESTAMPTZ (工作建立時間, 預設為 now())

completed_at: TIMESTAMPTZ (工作完成時間, 可為 NULL)

summary_report_url: TEXT (最終 PDF 報告在 Supabase Storage 中的 URL, 可為 NULL)

3. inspection_points 資料表
儲存每個巡檢點的詳細資訊。

資料表名稱: inspection_points

欄位 (Columns):

id: UUID (主鍵, PRIMARY KEY, 預設為 gen_random_uuid())

job_id: UUID (外鍵, FOREIGN KEY, 關聯至 inspection_jobs.id)

name: TEXT (巡檢點的名稱，例如："主冷卻泵入口壓力錶")

location: TEXT (巡檢點的位置描述，例如："B 棟 3 樓，機房 302")

status: TEXT (巡檢點狀態: "pending", "inspected")

original_image_url: TEXT (原始照片在 Supabase Storage 中的 URL, 可為 NULL)

inspected_at: TIMESTAMPTZ (巡檢完成時間, 可為 NULL)

inspector_override: BOOLEAN (標記 AI 結果是否被人工修改過, 預設為 false)

ai_analysis_result: JSONB (儲存由 Gemini AI 分析回傳的 JSON 物件, 可為 NULL)。結構如下：

{
  "equipment_type": "string",
  "reading": {
    "value": "float" or "null",
    "unit": "string" or "null"
  },
  "condition_assessment": "string",
  "is_anomaly": "boolean"
}

關聯 (Relationships)
一對多: 一個 user 可以有多個 inspection_jobs (users.id -> inspection_jobs.assigned_to)。

一對多: 一個 inspection_job 可以有多個 inspection_points (inspection_jobs.id -> inspection_points.job_id)。