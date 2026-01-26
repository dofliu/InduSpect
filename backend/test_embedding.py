"""
測試更新後的 EmbeddingService (使用新版 SDK 和英文關鍵字增強)
"""
import asyncio
import math
from app.services.embedding import EmbeddingService
from app.config import settings

def cosine_similarity(a, b):
    dot_product = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(x * x for x in b))
    if norm_a == 0 or norm_b == 0: return 0.0
    return dot_product / (norm_a * norm_b)

async def test():
    print(f"Provider: {settings.embedding_provider}")
    print(f"Model: {settings.embedding_model}")
    print(f"Dimension: {settings.embedding_dimension}")
    
    service = EmbeddingService()
    
    # 中文測試文字
    text1 = "風力發電機塔架接合處"  # Wind turbine tower joint
    text2 = "轉向齒輪"  # Steering gear
    text3 = "風力發電機葉片"  # Wind turbine blade
    
    print(f"\nText 1: {text1}")
    print(f"Text 2: {text2}")
    print(f"Text 3: {text3}")
    
    try:
        print("\nEmbedding text 1...")
        vec1 = await service.embed_text(text1)
        print(f"Vec1[:5]: {vec1[:5]}")
        
        print("Embedding text 2...")
        vec2 = await service.embed_text(text2)
        print(f"Vec2[:5]: {vec2[:5]}")
        
        print("Embedding text 3...")
        vec3 = await service.embed_text(text3)
        print(f"Vec3[:5]: {vec3[:5]}")
        
        sim12 = cosine_similarity(vec1, vec2)
        sim13 = cosine_similarity(vec1, vec3)
        
        print(f"\n塔架 vs 齒輪 相似度: {sim12:.4f} (應該較低)")
        print(f"塔架 vs 葉片 相似度: {sim13:.4f} (應該較高)")
        
        if sim12 > 0.9:
            print("\n⚠️ 警告：相似度仍然過高！")
        else:
            print("\n✅ 成功！中文 Embedding 現在正常運作了！")
            
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    asyncio.run(test())
