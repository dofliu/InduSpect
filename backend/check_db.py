import asyncio
import os
from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy import text
from app.config import settings

# Load env if needed (assuming already loaded by config or python-dotenv)
# settings.database_url should be correct if .env is correct

async def test_connection():
    url = settings.database_url.replace("postgresql+asyncpg://", "postgresql://") # For print only
    print(f"Connecting to {url}...")
    
    try:
        engine = create_async_engine(settings.database_url)
        async with engine.connect() as conn:
            # Check version
            res = await conn.execute(text("SELECT version();"))
            version = res.scalar()
            print(f"Database Connected! Version: {version}")
            
            # Check pgvector
            res = await conn.execute(text("SELECT * FROM pg_extension WHERE extname = 'vector';"))
            ext = res.scalar()
            if ext:
                print("pgvector extension is installed.")
            else:
                print("WARNING: pgvector extension is NOT installed.")
                # Try to create it
                try:
                    await conn.execute(text("CREATE EXTENSION IF NOT EXISTS vector;"))
                    await conn.commit()
                    print("pgvector extension installed successfully.")
                except Exception as e:
                    print(f"Failed to install pgvector: {e}")

    except Exception as e:
        print(f"Connection Failed: {e}")
    finally:
        await engine.dispose()

if __name__ == "__main__":
    asyncio.run(test_connection())
