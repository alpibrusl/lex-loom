"""Application entry point — the golden-path skeleton for `python-flask`.

The bootstrap lays this down so every company on this path starts from the
SAME known-good structure: build agents EXTEND these files rather than
inventing a fresh layout each sprint (which is what caused scattered files
and broken devops Dockerfiles before). Reads PORT from the environment so
the loom `launch` node can boot it on any port.
"""
from __future__ import annotations

import os

from flask import Flask, jsonify, request
from markupsafe import escape

# In-process store, deliberately the simplest thing that actually works for
# a single dev/demo server (same scope as the rest of this skeleton) — build
# agents extend this into real persistence once the product needs it to
# survive a restart.
_POSTS: list[dict] = []


def create_app() -> Flask:
    app = Flask(__name__)

    @app.route("/health", methods=["GET"])
    def health():
        return jsonify({"ok": True})

    # Read by the company's own strategic planning (the Strategist agent
    # between iterations), never by end users. As the product's domain model
    # grows, keep this returning a short, honest summary of REAL usage (row
    # counts, notable trends) so the company can steer itself on its own
    # data instead of flying blind between iterations. Build agents extend
    # this — do not leave it as the trivial stub past the first real feature.
    @app.route("/loom/usage", methods=["GET"])
    def loom_usage():
        return jsonify({"summary": "no usage data yet"})

    # Real, self-hosted distribution — no external platform, no API keys.
    # The Content Creator agent POSTs here to actually publish (not just
    # write prose nobody reads); /blog serves it to real visitors and
    # /loom/usage's sibling read here is how loom measures whether anyone
    # showed up. Build agents may extend this with real templates/styling,
    # but keep the two routes and the {title, body, views} shape so loom's
    # distribution signal keeps working.
    @app.route("/loom/content", methods=["GET", "POST"])
    def loom_content():
        if request.method == "POST":
            data = request.get_json(silent=True) or {}
            title = str(data.get("title", "")).strip()
            body = str(data.get("body", "")).strip()
            if not title or not body:
                return jsonify({"error": "title and body are required"}), 400
            _POSTS.append({"title": title, "body": body, "views": 0})
            return jsonify({"ok": True, "post_count": len(_POSTS)}), 201
        return jsonify({"posts": [{"title": p["title"], "views": p["views"]} for p in _POSTS]})

    @app.route("/blog", methods=["GET"])
    def blog():
        if not _POSTS:
            return "<h1>Blog</h1><p>No posts yet.</p>", 200
        parts = ["<h1>Blog</h1>"]
        for p in _POSTS:
            p["views"] += 1
            parts.append(f"<article><h2>{escape(p['title'])}</h2><p>{escape(p['body'])}</p></article>")
        return "".join(parts), 200

    return app


app = create_app()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8081))
    app.run(host="0.0.0.0", port=port)
