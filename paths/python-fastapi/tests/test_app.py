"""Skeleton test — proves the app boots and /health responds.

Build agents extend this file with real feature tests; keeping a passing
test from iteration zero means the `py_qa` gate has something green to
start from rather than an empty suite.
"""
from fastapi.testclient import TestClient

from app import app


def test_health():
    client = TestClient(app)
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}


def test_loom_usage():
    client = TestClient(app)
    resp = client.get("/loom/usage")
    assert resp.status_code == 200
    assert "summary" in resp.json()
