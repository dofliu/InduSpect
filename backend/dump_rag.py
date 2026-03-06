
import asyncio
from sqlalchemy import select
from app.db.database import async_session_maker
from app.db.models import RAGItem

async def dump_rag_items():
    async with async_session_maker() as session:
        result = await session.execute(select(RAGItem))
        items = result.scalars().all()
        print(f"\n\n=== TOTAL ITEMS: {len(items)} ===")
        for i, item in enumerate(items):
            print(f"Item #{i+1}")
            print(f"Type: {item.equipment_type}")
            print(f"Content Start: {item.content[:50]}...")
            print("-" * 20)
        print("=== END DUMP ===\n\n")

if __name__ == "__main__":
    import logging
    logging.getLogger('sqlalchemy.engine').setLevel(logging.WARNING)
    asyncio.run(dump_rag_items())
