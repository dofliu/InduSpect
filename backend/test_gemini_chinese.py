
import asyncio
from google import genai
import math

import os
from dotenv import load_dotenv

load_dotenv()

# New API Key
API_KEY = os.getenv("GEMINI_API_KEY")
if not API_KEY:
    raise ValueError("GEMINI_API_KEY not found in .env file")

def cosine_similarity(a, b):
    dot_product = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(x * x for x in b))
    if norm_a == 0 or norm_b == 0: return 0.0
    return dot_product / (norm_a * norm_b)

def test():
    client = genai.Client(api_key=API_KEY)
    
    # Test with Chinese text
    text1 = "風力發電機塔架接合處"  # Wind turbine tower joint
    text2 = "轉向齒輪"  # Steering gear
    text3 = "風力發電機葉片"  # Wind turbine blade
    
    print(f"Testing with API Key: {API_KEY[:10]}...")
    print(f"Text 1 (風力發電機塔架接合處): {text1}")
    print(f"Text 2 (轉向齒輪): {text2}")
    print(f"Text 3 (風力發電機葉片): {text3}")
    
    try:
        print("\nEmbedding text 1...")
        res1 = client.models.embed_content(
            model="text-embedding-004",
            contents=text1,
        )
        vec1 = res1.embeddings[0].values
        print(f"Vec1 length: {len(vec1)}, first 5: {vec1[:5]}")
        
        print("Embedding text 2...")
        res2 = client.models.embed_content(
            model="text-embedding-004",
            contents=text2,
        )
        vec2 = res2.embeddings[0].values
        print(f"Vec2 length: {len(vec2)}, first 5: {vec2[:5]}")
        
        print("Embedding text 3...")
        res3 = client.models.embed_content(
            model="text-embedding-004",
            contents=text3,
        )
        vec3 = res3.embeddings[0].values
        print(f"Vec3 length: {len(vec3)}, first 5: {vec3[:5]}")

        sim12 = cosine_similarity(vec1, vec2)
        sim13 = cosine_similarity(vec1, vec3)
        
        print(f"\nSimilarity (塔架 vs 齒輪 - should be LOW): {sim12:.4f}")
        print(f"Similarity (塔架 vs 葉片 - should be HIGHER): {sim13:.4f}")
        
        output = [
            f"Text1: {text1}",
            f"Text2: {text2}",
            f"Text3: {text3}",
            f"Vec1[:5]: {vec1[:5]}",
            f"Vec2[:5]: {vec2[:5]}",
            f"Vec3[:5]: {vec3[:5]}",
            f"Sim(塔架 vs 齒輪): {sim12:.4f}",
            f"Sim(塔架 vs 葉片): {sim13:.4f}",
        ]
        
        with open("test_gemini_chinese_result.txt", "w", encoding="utf-8") as f:
            f.write("\n".join(output))
        
        if sim12 > 0.95:
            print("\n⚠️ WARNING: Similarity too high - Chinese embedding may have issues!")
        else:
            print("\n✅ Chinese embedding is working correctly!")
            
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    test()
