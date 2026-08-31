"""
API Key middleware 與錯誤淨化測試（LAUNCH_PLAN P0-3 / P0-8）

驗證 app.main 的存取控制行為：
- BACKEND_API_KEY 設定時，/api/* 需帶相符 X-API-Key，否則 401
- `/` 與 `/health`（Cloud Run 探針）永遠開放
- OPTIONS（CORS preflight）放行
- BACKEND_API_KEY 未設定（開發模式）不驗證

注意：TestClient 不以 context manager 使用 → 不觸發 lifespan（不連 DB）。
judge-readings 為純邏輯端點，適合作為 middleware 探測目標。
"""

import os
import sys

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("GEMINI_API_KEY", "test-key")

from app.config import settings  # noqa: E402
from app.main import app  # noqa: E402

PROBE = "/api/auto-fill/judge-readings"
PAYLOAD = {"readings": [{"field_name": "絕緣電阻", "value": 52.3, "unit": "MΩ"}], "equipment_type": "電氣"}


@pytest.fixture
def client():
    return TestClient(app)


def test_health_endpoints_open_even_with_key(monkeypatch, client):
    monkeypatch.setattr(settings, "backend_api_key", "secret-key")
    assert client.get("/health").status_code == 200
    assert client.get("/").status_code == 200


def test_api_requires_key_when_configured(monkeypatch, client):
    monkeypatch.setattr(settings, "backend_api_key", "secret-key")
    resp = client.post(PROBE, json=PAYLOAD)
    assert resp.status_code == 401
    assert "API Key" in resp.json()["detail"]


def test_api_rejects_wrong_key(monkeypatch, client):
    monkeypatch.setattr(settings, "backend_api_key", "secret-key")
    resp = client.post(PROBE, json=PAYLOAD, headers={"X-API-Key": "wrong"})
    assert resp.status_code == 401


def test_api_accepts_valid_key(monkeypatch, client):
    monkeypatch.setattr(settings, "backend_api_key", "secret-key")
    resp = client.post(PROBE, json=PAYLOAD, headers={"X-API-Key": "secret-key"})
    assert resp.status_code == 200
    assert resp.json()["success"] is True


def test_options_preflight_bypasses_key(monkeypatch, client):
    """CORS preflight 不帶自訂 header，不可被 API key 擋下。"""
    monkeypatch.setattr(settings, "backend_api_key", "secret-key")
    resp = client.options(
        PROBE,
        headers={
            "Origin": "https://example.com",
            "Access-Control-Request-Method": "POST",
        },
    )
    assert resp.status_code != 401


def test_api_open_when_key_unset(monkeypatch, client):
    """開發模式（未設定 key）不驗證，既有測試與本地開發不受影響。"""
    monkeypatch.setattr(settings, "backend_api_key", "")
    resp = client.post(PROBE, json=PAYLOAD)
    assert resp.status_code == 200


def test_internal_error_is_sanitized():
    """internal_error 不得把例外內容洩漏到 detail。"""
    from app.api.errors import internal_error

    exc = internal_error(RuntimeError("secret db path /var/lib/x"), "unit-test")
    assert exc.status_code == 500
    assert "secret" not in exc.detail
    assert "/var/lib" not in exc.detail
