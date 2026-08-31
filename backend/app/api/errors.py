"""
API 錯誤處理共用工具

原則：內部例外細節（traceback、檔案路徑、DB 錯誤）只進伺服器 log，
不回傳給客戶端，避免資訊洩漏（LAUNCH_PLAN P0-8）。
"""

import logging

from fastapi import HTTPException

logger = logging.getLogger("induspect.api")


def internal_error(e: Exception, context: str = "") -> HTTPException:
    """記錄完整例外於伺服器端，回傳不含內部細節的 500。

    用法：
        except Exception as e:
            raise internal_error(e, "analyze-structure")
    """
    logger.error("API internal error%s: %s", f" [{context}]" if context else "", e, exc_info=True)
    return HTTPException(status_code=500, detail="伺服器內部錯誤，請稍後再試")
