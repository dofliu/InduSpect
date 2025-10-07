AI 模型整合規格
本文件為 AI 開發人員提供整合 Gemini 模型的具體技術指南，包括模型選擇、API 介面和提示工程策略。

1. 模型選擇與路由邏輯
系統採用混合式 AI 策略，根據任務的複雜度和流量，在 gemini-2.5-flash 和 gemini-2.5-pro 之間進行智慧路由，以平衡成本與效能。

gemini-2.5-flash: 作為系統的主力分析引擎。處理所有單張圖像的分析任務，因其速度快、成本效益高，非常適合高流量的逐點分析。

gemini-2.5-pro: 作為系統的首席推理引擎。僅用於處理低流量、高複雜度的任務，即生成最終的巡檢摘要報告。

路由邏輯 (在 processing-service 中實現):

圖像分析請求: 當 processing-service 被新上傳的圖像觸發時，固定呼叫 gemini-2.5-flash 模型。

報告生成請求: 當使用者在 App 中提交完成的巡檢工作時，前端會呼叫一個特定的 API 端點。該端點的後端邏輯會：
a. 從 Firestore 收集該次巡檢工作所有點的 JSON 分析結果。
b. 將所有結果匯總。
c. 固定呼叫 gemini-2.5-pro 模型來生成摘要報告。

2. API 介面定義 (processing-service)
端點: POST /analyze-image (由 Eventarc 觸發)
輸入 (來自 Eventarc 事件):

{
  "bucket": "your-inspection-images-bucket",
  "name": "images/job_123/point_456.jpg"
}

處理流程:

從事件中獲取圖像的 GCS URI (gs://your-inspection-images-bucket/images/job_123/point_456.jpg)。

根據圖像元數據 (例如，所屬的巡檢點類型) 選擇合適的提示範本。

呼叫 Vertex AI 的 gemini-2.5-flash API。

驗證回傳的 JSON 是否符合預期格式。

將驗證後的 JSON 寫入 Firestore 對應的巡檢點文件中。

輸出: (寫入 Firestore)

3. 提示工程指南 (Prompt Templates)
以下是針對不同任務的基礎提示範本，應在後端程式碼中作為可配置的字串。

3.1 範本一：標準設備巡檢 (通用)
此為最常用的提示，用於從單張圖像中提取結構化數據。

您是一位專業的工業巡檢 AI。請分析提供的設備巡檢點圖像。

任務指令：
1. 識別圖像中的主要設備類型 (例如：泵、閥門、壓力錶、馬達)。
2. 如果存在任何形式的儀表或計量器，請執行 OCR 以讀取其數值和單位。如果無法讀取或不存在，請回傳 null。
3. 仔細評估設備的整體狀況，重點描述任何磨損、生鏽、腐蝕、洩漏或物理損壞的跡象。如果狀況良好，請註明「狀況良好」。
4. 根據您的評估，判斷是否存在需要關注的異常情況。

輸出格式：
請務必將您的所有發現以一個單一、最小化、不含 markdown 標記的 JSON 物件格式回傳。JSON 結構必須如下：
{
  "equipment_type": "string",
  "reading": {
    "value": "float" or "null",
    "unit": "string" or "null"
  },
  "condition_assessment": "string",
  "is_anomaly": "boolean"
}

3.2 範本二：指針式儀表讀取 (進階)
當巡檢點被標記為「指針式儀表」時，可使用此更具體的提示。

您是一位精於儀表讀數的 AI 分析師。請分析這張指針式壓力錶的圖像。

已知資訊：
- 儀表錶盤的測量範圍是從 0 到 100 PSI。
- 刻度標記位於 0, 10, 20, ..., 100。

任務指令：
1. 根據指針相對於錶盤刻度的角度位置，進行空間推理，估算當前的精確讀數。
2. 將結果輸出到小數點後一位。

輸出格式：
請務必將您的所有發現以一個單一、最小化、不含 markdown 標記的 JSON 物件格式回傳。JSON 結構必須如下：
{
  "equipment_type": "指針式壓力錶",
  "reading": {
    "value": "float",
    "unit": "PSI"
  },
  "condition_assessment": "string",
  "is_anomaly": "boolean"
}

3.3 範本三：高階主管摘要報告生成
此提示用於呼叫 gemini-2.5-pro。

您是一位經驗豐富的工廠營運經理 AI 助理。

背景資料：
以下是一個 JSON 陣列，包含了某次設施巡檢中每個檢查點的數據。每個物件代表一個巡檢點的發現。
[
  { "equipment_type": "泵 A-01", "reading": null, "condition_assessment": "偵測到輕微表面生鏽", "is_anomaly": true },
  { "equipment_type": "壓力錶 C-03", "reading": { "value": 85.2, "unit": "PSI" }, "condition_assessment": "讀數超出正常範圍 (70-80 PSI)", "is_anomaly": true },
  { "equipment_type": "閥門 D-09", "reading": null, "condition_assessment": "狀況良好", "is_anomaly": false }
  // ... 此處將插入所有其他數據點
]

任務指令：
請根據上述數據，生成一份不超過 250 字的高階主管級摘要報告。報告應包含以下三個部分：
1.  **總體概述**: 簡要總結本次巡檢的整體情況。
2.  **關鍵問題**: 以點列方式，列出 3 個最需要立即關注的異常問題，並明確指出設備位置和具體問題。
3.  **結論**: 用一句話總結設施的整體維護狀況。

報告語氣應正式、專業且簡潔。直接輸出報告內容，不要包含任何額外的開場白或結語。
 