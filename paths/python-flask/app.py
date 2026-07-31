"""Application entry point — the golden-path skeleton for `python-flask`.

The bootstrap lays this down so every company on this path starts from the
SAME known-good structure: build agents EXTEND these files rather than
inventing a fresh layout each sprint (which is what caused scattered files
and broken devops Dockerfiles before). Reads PORT from the environment so
the loom `launch` node can boot it on any port.
"""
from __future__ import annotations

import os

from flask import Flask, jsonify


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

    return app


app = create_app()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8081))
    app.run(host="0.0.0.0", port=port)
