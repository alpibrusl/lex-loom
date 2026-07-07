"""Skeleton test — proves the app boots and /health responds.

Build agents extend this file with real feature tests; keeping a passing
test from iteration zero means the `py_qa` gate has something green to
start from rather than an empty suite.
"""
from app import create_app


def test_health():
    client = create_app().test_client()
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json() == {"ok": True}
