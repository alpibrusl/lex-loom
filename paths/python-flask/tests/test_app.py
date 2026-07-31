"""Skeleton test — proves the app boots and /health responds.

Build agents extend this file with real feature tests; keeping a passing
test from iteration zero means the `py_qa` gate has something green to
start from rather than an empty suite.
"""
import pytest

import app as app_module
from app import create_app


@pytest.fixture(autouse=True)
def _reset_posts():
    # _POSTS is module-level state shared across the whole test process;
    # reset it so tests don't see posts left behind by an earlier one.
    app_module._POSTS.clear()
    yield
    app_module._POSTS.clear()


def test_health():
    client = create_app().test_client()
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json() == {"ok": True}


def test_loom_usage():
    client = create_app().test_client()
    resp = client.get("/loom/usage")
    assert resp.status_code == 200
    assert "summary" in resp.get_json()


def test_loom_content_publish_and_list():
    client = create_app().test_client()
    resp = client.post("/loom/content", json={"title": "Launch post", "body": "We shipped it."})
    assert resp.status_code == 201
    resp = client.get("/loom/content")
    assert resp.status_code == 200
    posts = resp.get_json()["posts"]
    assert posts == [{"title": "Launch post", "views": 0}]


def test_loom_content_rejects_missing_fields():
    client = create_app().test_client()
    resp = client.post("/loom/content", json={"title": "No body"})
    assert resp.status_code == 400


def test_blog_renders_published_posts_and_counts_a_view():
    client = create_app().test_client()
    client.post("/loom/content", json={"title": "Hello", "body": "World"})
    resp = client.get("/blog")
    assert resp.status_code == 200
    assert b"Hello" in resp.data
    stats = client.get("/loom/content").get_json()["posts"]
    assert stats[0]["views"] == 1
