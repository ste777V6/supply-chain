from app.main import app


def test_healthz():
    resp = app.test_client().get("/healthz")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok"}


def test_version_defaults_to_unknown(monkeypatch):
    monkeypatch.delenv("GIT_SHA", raising=False)
    resp = app.test_client().get("/version")
    assert resp.get_json() == {"commit": "unknown"}
