
import asyncio
from sqlalchemy import text
from app.db.database import async_session_maker

async def reset_db():
    print("Connecting to database...")
    try:
        async with async_session_maker() as session:
            print("Truncating rag_items table...")
            # TRUNCATE is faster and resets identity (if RESTART IDENTITY is used)
            # Using CASCADE to handle potential foreign keys, though RAG items are usually standalone here
            await session.execute(text("TRUNCATE TABLE rag_items RESTART IDENTITY CASCADE"))
            await session.commit()
        print("✅ Done! All items in 'rag_items' table have been cleared.")
        print("You can now run Quick Analysis again to generate fresh, correct vectors.")
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    asyncio.run(reset_db())
