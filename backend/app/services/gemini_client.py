"""Gemini SDK 統一入口 — 新版 `google-genai`

背景（LAUNCH_PLAN P1「SDK 汰換」）：
舊版 `google-generativeai` 0.3.2 已停止維護（Google 官方建議遷移至 `google-genai`），
且原本各 service 各自 `genai.configure()` + `genai.GenerativeModel()`，
造成三個問題：

1. **全域狀態**：`configure()` 是行程級設定，多 service 互相覆蓋，難以測試。
2. **無 key 即炸**：新版 SDK 的 `Client(api_key="")` 會直接拋 ValueError，
   若沿用「在 __init__ 建 client」的寫法，連不需要 AI 的路徑
   （Excel/Word 回填、結構分析）都會因為沒設 key 而無法使用。
3. **重複建構**：`FormFillService` 每個請求 new 一次，等於每請求建一個 HTTP client。

因此本模組的設計原則：

- **延遲建立**：只有真的要呼叫 AI 時才建 client；服務建構不碰網路、不需要 key。
- **依 key 快取**：同一把 key 共用同一個 client（`lru_cache`），
  key 變更（測試 monkeypatch、輪替）會自動取得新 client。
- **統一取值**：`generate_text()` 收斂 `response.text` 的 None 處理，
  呼叫端不必各自防禦。

新舊 SDK 對照（供日後維護參考）：

| 舊 `google-generativeai`                  | 新 `google-genai`                                  |
|-------------------------------------------|----------------------------------------------------|
| `genai.configure(api_key=...)`            | `genai.Client(api_key=...)`                        |
| `genai.GenerativeModel(m).generate_content(p)` | `client.models.generate_content(model=m, contents=p)` |
| `genai.embed_content(model=f"models/{m}", content=t, task_type=...)` | `client.models.embed_content(model=m, contents=t, config=EmbedContentConfig(task_type=...))` |
| `genai.upload_file(path=..., display_name=...)` | `client.files.upload(file=..., config=UploadFileConfig(display_name=...))` |
| `genai.get_file(name)` / `genai.delete_file(name)` | `client.files.get(name=...)` / `client.files.delete(name=...)` |
"""

import logging
from functools import lru_cache
from typing import Any, Optional

from google import genai
from google.genai import types

from app.config import settings

logger = logging.getLogger(__name__)

__all__ = [
    "GeminiNotConfiguredError",
    "is_configured",
    "get_client",
    "generate_text",
    "upload_file",
    "get_file",
    "delete_file",
    "file_state_name",
    "reset_client_cache",
    "types",
]


class GeminiNotConfiguredError(RuntimeError):
    """GEMINI_API_KEY 未設定 —— 呼叫端應降級為非 AI 路徑，而非讓請求 500。"""


@lru_cache(maxsize=4)
def _build_client(api_key: str) -> genai.Client:
    """依 API key 建立並快取 client（同 key 共用連線池）。"""
    logger.info("建立 google-genai client（key 尾碼 ...%s）", api_key[-4:])
    return genai.Client(api_key=api_key)


def reset_client_cache() -> None:
    """清空 client 快取（測試用；正式流程不需要呼叫）。"""
    _build_client.cache_clear()


def _api_key() -> str:
    return (settings.gemini_api_key or "").strip()


def is_configured() -> bool:
    """是否已設定 GEMINI_API_KEY（呼叫端可據此決定要不要走 AI 路徑）。"""
    return bool(_api_key())


def get_client() -> genai.Client:
    """取得共用的 Gemini client。

    Raises:
        GeminiNotConfiguredError: 未設定 GEMINI_API_KEY。
    """
    api_key = _api_key()
    if not api_key:
        raise GeminiNotConfiguredError(
            "GEMINI_API_KEY 未設定，無法使用 AI 功能（非 AI 路徑不受影響）。"
            "請於環境變數或 Secret Manager 提供 GEMINI_API_KEY。"
        )
    return _build_client(api_key)


def generate_text(contents: Any, *, model: Optional[str] = None) -> str:
    """呼叫 Gemini 產生文字，回傳純文字內容。

    Args:
        contents: prompt 字串，或 [prompt, uploaded_file] 這類多模態列表。
        model: 模型 ID，預設 `settings.gemini_flash_model`。

    Returns:
        回應文字；被安全過濾擋下或無候選內容時回傳空字串（不拋例外，
        由呼叫端既有的 fallback 邏輯處理）。
    """
    client = get_client()
    response = client.models.generate_content(
        model=model or settings.gemini_flash_model,
        contents=contents,
    )
    return _response_text(response)


def _response_text(response: Any) -> str:
    """安全取出回應文字：無 candidates / 被過濾時 `.text` 可能是 None 或拋例外。"""
    try:
        text = response.text
    except Exception as e:  # pragma: no cover - SDK 版本差異的防禦
        logger.warning("讀取 Gemini 回應文字失敗: %s", e)
        return ""
    return text or ""


# ============ File API（RAG 文件匯入用） ============


def upload_file(path: str, display_name: Optional[str] = None) -> types.File:
    """上傳檔案供 Gemini 分析（對應舊版 `genai.upload_file`）。"""
    client = get_client()
    config = types.UploadFileConfig(display_name=display_name) if display_name else None
    return client.files.upload(file=path, config=config)


def get_file(name: str) -> types.File:
    """查詢已上傳檔案的最新狀態（對應舊版 `genai.get_file`）。"""
    return get_client().files.get(name=name)


def delete_file(name: str) -> None:
    """刪除已上傳檔案；失敗僅記錄（檔案本來就會自動過期）。"""
    try:
        get_client().files.delete(name=name)
    except Exception as e:
        logger.warning("刪除 Gemini 檔案 %s 失敗（可忽略，檔案會自動過期）: %s", name, e)


def file_state_name(file: Any) -> str:
    """取出檔案狀態名稱（PROCESSING / ACTIVE / FAILED）。

    新版 SDK 的 `File.state` 是 `types.FileState` enum，舊版是帶 `.name` 的物件，
    測試替身則常直接給字串 —— 三種都要能判讀。
    """
    state = getattr(file, "state", None)
    if state is None:
        return ""
    return str(getattr(state, "name", state))
