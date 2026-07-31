"""Application entry point — the golden-path skeleton for `python-fastapi`.

Pick this path over `python-flask` when the API needs request/response
VALIDATION (Pydantic models catch bad input before your handler runs) or
free OpenAPI/Swagger docs at /docs — the common case for a documented public
API a developer integrates against. Pick `python-flask` for a genuinely
minimal server with no validation needs.

Reads PORT from the environment so the loom `launch` node can boot it on
any port. Build agents EXTEND this file rather than inventing a fresh
layout each sprint.
"""
from __future__ import annotations

import html
import os

from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

app = FastAPI(title="app")

# In-process store, deliberately the simplest thing that actually works for
# a single dev/demo server (same scope as the rest of this skeleton) — build
# agents extend this into real persistence once the product needs it to
# survive a restart.
_POSTS: list[dict] = []


class ContentPost(BaseModel):
    title: str
    body: str


@app.get("/health")
def health() -> dict:
    return {"ok": True}


# Read by the company's own strategic planning (the Strategist agent between
# iterations), never by end users. As the product's domain model grows, keep
# this returning a short, honest summary of REAL usage (row counts, notable
# trends) so the company can steer itself on its own data instead of flying
# blind between iterations. Build agents extend this — do not leave it as
# the trivial stub past the first real feature.
@app.get("/loom/usage")
def loom_usage() -> dict:
    return {"summary": "no usage data yet"}


# Real, self-hosted distribution — no external platform, no API keys. The
# Content Creator agent POSTs here to actually publish (not just write prose
# nobody reads); /blog serves it to real visitors and /loom/usage's sibling
# read here is how loom measures whether anyone showed up. Build agents may
# extend this with real templates/styling, but keep the two routes and the
# {title, body, views} shape so loom's distribution signal keeps working.
@app.get("/loom/content")
def loom_content_list() -> dict:
    return {"posts": [{"title": p["title"], "views": p["views"]} for p in _POSTS]}


@app.post("/loom/content", status_code=201)
def loom_content_publish(post: ContentPost) -> dict:
    title = post.title.strip()
    body = post.body.strip()
    if not title or not body:
        raise HTTPException(status_code=400, detail="title and body are required")
    _POSTS.append({"title": title, "body": body, "views": 0})
    return {"ok": True, "post_count": len(_POSTS)}


@app.get("/blog", response_class=HTMLResponse)
def blog() -> str:
    if not _POSTS:
        return "<h1>Blog</h1><p>No posts yet.</p>"
    parts = ["<h1>Blog</h1>"]
    for p in _POSTS:
        p["views"] += 1
        parts.append(f"<article><h2>{html.escape(p['title'])}</h2><p>{html.escape(p['body'])}</p></article>")
    return "".join(parts)


if __name__ == "__main__":
    import uvicorn

    port = int(os.environ.get("PORT", 8081))
    uvicorn.run(app, host="0.0.0.0", port=port)
