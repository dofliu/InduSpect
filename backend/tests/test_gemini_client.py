"""gemini_client 與新版 google-genai SDK 遷移的行為鎖定測試

對應 LAUNCH_PLAN P1「SDK 汰換」：`google-generativeai`（已停止維護）→ `google-genai`。

鎖定的性質：
1. **延遲建立 client**：沒有 GEMINI_API_KEY 也能建構各 service（非 AI 路徑仍可用）。
   這是遷移中最容易回歸的地方——新版 `Client(api_key="")` 會直接拋 ValueError，
   若有人把 client 建構搬回 `__init__`，Excel/Word 回填會在沒設 key 的環境全掛。
2. **依 key 快取**：同 key 共用 client，換 key 取得新 client。
3. **generate_text**：帶對模型、回傳 `.text`、`.text` 為 None 時回空字串。
4. **檔案狀態判讀**：enum / 物件 / 字串三種形態都要能判讀（RAG 文件匯入輪詢用）。
5. **舊版 SDK 不再被 import**：避免遷移做一半留下混用。
"""

import os
import sys
from types import SimpleNamespace

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("GEMINI_API_KEY", "test-key")

from app.config import settings  # noqa: E402
from app.services import gemini_client  # noqa: E402


@pytest.fixture(autouse=True)
def _clean_client_cache():
    """每個測試前後都清掉 client 快取，避免 key 被前一個測試污染。"""
    original_key = settings.gemini_api_key
    gemini_client.reset_client_cache()
    yield
    settings.gemini_api_key = original_key
    gemini_client.reset_client_cache()


# ============ 1. 延遲建立：沒有 key 也能建構 service ============


def test_services_construct_without_api_key():
    """沒設 GEMINI_API_KEY 時，各 service 仍可建構（非 AI 路徑不受影響）。

    新版 SDK 的 Client(api_key="") 會拋 ValueError，所以 client 必須延遲建立。
    """
    from app.services.auto_fill_service import AutoFillService
    from app.services.embedding import EmbeddingService
    from app.services.form_analysis_service import FormAnalysisService

    settings.gemini_api_key = ""

    assert AutoFillService() is not None
    assert FormAnalysisService() is not None
    assert EmbeddingService() is not None


def test_form_fill_service_constructs_without_api_key():
    """FormFillService 每請求 new 一次，沒有 key 時也不能在建構就爆掉。"""
    from app.services.form_fill import FormFillService

    settings.gemini_api_key = ""
    assert FormFillService() is not None


def test_get_client_without_key_raises_typed_error():
    settings.gemini_api_key = "   "
    assert gemini_client.is_configured() is False
    with pytest.raises(gemini_client.GeminiNotConfiguredError):
        gemini_client.get_client()


def test_is_configured_true_with_key():
    settings.gemini_api_key = "some-key"
    assert gemini_client.is_configured() is True


# ============ 2. client 快取 ============


def test_client_cached_per_api_key():
    settings.gemini_api_key = "key-aaaa"
    first = gemini_client.get_client()
    assert gemini_client.get_client() is first, "同一把 key 應共用 client"

    settings.gemini_api_key = "key-bbbb"
    assert gemini_client.get_client() is not first, "換 key 應取得新 client"


def test_api_key_whitespace_is_stripped():
    settings.gemini_api_key = "  key-cccc  "
    stripped = gemini_client.get_client()
    settings.gemini_api_key = "key-cccc"
    assert gemini_client.get_client() is stripped


# ============ 3. generate_text ============


class _FakeModels:
    def __init__(self, text):
        self._text = text
        self.calls = []

    def generate_content(self, *, model, contents):
        self.calls.append({"model": model, "contents": contents})
        return SimpleNamespace(text=self._text)


class _FakeClient:
    def __init__(self, text="回應內容"):
        self.models = _FakeModels(text)


def test_generate_text_passes_model_and_returns_text(monkeypatch):
    fake = _FakeClient("建議一\n建議二")
    monkeypatch.setattr(gemini_client, "get_client", lambda: fake)

    result = gemini_client.generate_text("prompt 內容", model="gemini-test-model")

    assert result == "建議一\n建議二"
    assert fake.models.calls == [
        {"model": "gemini-test-model", "contents": "prompt 內容"}
    ]


def test_generate_text_defaults_to_flash_model(monkeypatch):
    fake = _FakeClient()
    monkeypatch.setattr(gemini_client, "get_client", lambda: fake)

    gemini_client.generate_text("prompt")

    assert fake.models.calls[0]["model"] == settings.gemini_flash_model


def test_generate_text_accepts_multimodal_contents(monkeypatch):
    """RAG 文件匯入送的是 [prompt, uploaded_file] 列表。"""
    fake = _FakeClient()
    monkeypatch.setattr(gemini_client, "get_client", lambda: fake)

    uploaded = SimpleNamespace(name="files/abc")
    gemini_client.generate_text(["prompt", uploaded], model="doc-model")

    assert fake.models.calls[0]["contents"] == ["prompt", uploaded]


def test_generate_text_returns_empty_string_when_text_is_none(monkeypatch):
    """被安全過濾擋下時 `.text` 為 None —— 應回空字串讓呼叫端走既有 fallback。"""
    fake = _FakeClient(None)
    monkeypatch.setattr(gemini_client, "get_client", lambda: fake)

    assert gemini_client.generate_text("prompt") == ""


def test_generate_text_returns_empty_string_when_text_raises(monkeypatch):
    class _Raising:
        @property
        def text(self):
            raise ValueError("no candidates")

    class _Models:
        def generate_content(self, *, model, contents):
            return _Raising()

    monkeypatch.setattr(
        gemini_client, "get_client", lambda: SimpleNamespace(models=_Models())
    )

    assert gemini_client.generate_text("prompt") == ""


# ============ 4. 檔案狀態判讀 ============


def test_file_state_name_reads_enum():
    """新版 SDK 的 File.state 是 types.FileState enum。"""
    file = SimpleNamespace(state=gemini_client.types.FileState.PROCESSING)
    assert gemini_client.file_state_name(file) == "PROCESSING"

    file = SimpleNamespace(state=gemini_client.types.FileState.ACTIVE)
    assert gemini_client.file_state_name(file) == "ACTIVE"


def test_file_state_name_reads_object_with_name():
    """舊版 SDK 形態：帶 .name 的物件。"""
    file = SimpleNamespace(state=SimpleNamespace(name="FAILED"))
    assert gemini_client.file_state_name(file) == "FAILED"


def test_file_state_name_reads_plain_string_and_missing():
    assert gemini_client.file_state_name(SimpleNamespace(state="ACTIVE")) == "ACTIVE"
    assert gemini_client.file_state_name(SimpleNamespace()) == ""
    assert gemini_client.file_state_name(SimpleNamespace(state=None)) == ""


def test_delete_file_swallows_errors(monkeypatch):
    """刪除失敗不應中斷匯入流程（檔案本來就會自動過期）。"""

    class _Files:
        def delete(self, *, name):
            raise RuntimeError("already gone")

    monkeypatch.setattr(
        gemini_client, "get_client", lambda: SimpleNamespace(files=_Files())
    )

    gemini_client.delete_file("files/abc")  # 不應拋出


def test_upload_file_passes_display_name(monkeypatch):
    captured = {}

    class _Files:
        def upload(self, *, file, config):
            captured["file"] = file
            captured["config"] = config
            return SimpleNamespace(name="files/xyz")

    monkeypatch.setattr(
        gemini_client, "get_client", lambda: SimpleNamespace(files=_Files())
    )

    result = gemini_client.upload_file(path="/tmp/a.pdf", display_name="手冊.pdf")

    assert result.name == "files/xyz"
    assert captured["file"] == "/tmp/a.pdf"
    assert captured["config"].display_name == "手冊.pdf"


# ============ 5. 遷移完整性 ============


def test_legacy_sdk_not_imported_anywhere():
    """整個 app/ 不應再出現舊版 google.generativeai 的 import。"""
    import pathlib
    import re

    app_dir = pathlib.Path(__file__).resolve().parent.parent / "app"
    pattern = re.compile(r"^\s*(import\s+google\.generativeai|from\s+google\.generativeai)", re.M)

    offenders = [
        str(path.relative_to(app_dir.parent))
        for path in app_dir.rglob("*.py")
        if pattern.search(path.read_text(encoding="utf-8"))
    ]
    assert offenders == [], f"仍在使用舊版 SDK: {offenders}"


def test_embedding_task_type_locked():
    """embedding task type 必須維持 RETRIEVAL_DOCUMENT。

    知識庫既有向量都是以此 task type 產生；換掉會讓新舊向量落在不同語意空間，
    pgvector 餘弦相似度檢索直接失準。
    """
    from app.services.embedding import EMBEDDING_TASK_TYPE

    assert EMBEDDING_TASK_TYPE == "RETRIEVAL_DOCUMENT"


@pytest.mark.asyncio
async def test_embedding_uses_new_sdk_with_task_type(monkeypatch):
    """embed 走新版 SDK 的 models.embed_content，且帶上 task_type。"""
    from app.services.embedding import EmbeddingService

    captured = {}

    class _Models:
        def embed_content(self, *, model, contents, config):
            captured.update(model=model, contents=contents, config=config)
            return SimpleNamespace(embeddings=[SimpleNamespace(values=[0.1, 0.2, 0.3])])

    monkeypatch.setattr(
        gemini_client, "get_client", lambda: SimpleNamespace(models=_Models())
    )

    service = EmbeddingService(provider="gemini")
    vector = await service.embed_text("軸承溫度異常")

    assert vector == [0.1, 0.2, 0.3]
    assert captured["model"] == settings.embedding_model
    assert captured["config"].task_type == "RETRIEVAL_DOCUMENT"
    # 中文內容會被加上英文關鍵字前綴（既有行為，不應被遷移改掉）
    assert "bearing" in captured["contents"]
    assert "軸承溫度異常" in captured["contents"]
