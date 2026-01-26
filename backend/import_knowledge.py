
import json
import requests
import os
import sys

# API URL (預設為本地後端)
API_URL = "http://localhost:8000/api/rag/add"

def import_knowledge(json_file_path):
    """
    從 JSON 文件導入知識到 RAG 系統
    """
    if not os.path.exists(json_file_path):
        print(f"❌ 錯誤: 找不到文件 {json_file_path}")
        return

    try:
        with open(json_file_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
            
        print(f"📦 準備導入 {len(data)} 筆資料...")
        
        success_count = 0
        fail_count = 0
        
        for i, item in enumerate(data):
            try:
                # 準備 payload
                payload = {
                    "equipment_type": item.get("equipment_type", "Unknown"),
                    "content": item.get("content", ""),
                    "source_type": "document",  # 標記為文件導入
                    "source_id": f"import_{i+1}",
                    "metadata": item.get("metadata", {})
                }
                
                # 發送請求
                response = requests.post(API_URL, json=payload)
                
                if response.status_code == 200:
                    print(f"✅ [{i+1}/{len(data)}] 成功: {item.get('equipment_type')} - {item.get('content')[:20]}...")
                    success_count += 1
                else:
                    print(f"❌ [{i+1}/{len(data)}] 失敗: {response.status_code} - {response.text}")
                    fail_count += 1
                    
            except Exception as e:
                print(f"❌ [{i+1}/{len(data)}] 請求錯誤: {e}")
                fail_count += 1
        
        print("\n" + "="*30)
        print(f"🎉 導入完成!")
        print(f"   成功: {success_count}")
        print(f"   失敗: {fail_count}")
        print("="*30)
        
    except json.JSONDecodeError:
        print(f"❌ 錯誤: JSON 格式無效")
    except Exception as e:
        print(f"❌ 系統錯誤: {e}")

if __name__ == "__main__":
    # 使用範例文件路徑，或讓用戶輸入
    default_path = os.path.join(os.path.dirname(__file__), "data", "knowledge_template.json")
    
    file_path = default_path
    if len(sys.argv) > 1:
        file_path = sys.argv[1]
    
    print(f"正在讀取檔案: {file_path}")
    import_knowledge(file_path)
