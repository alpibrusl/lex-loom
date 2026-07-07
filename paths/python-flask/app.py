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

    return app


app = create_app()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8081))
    app.run(host="0.0.0.0", port=port)
