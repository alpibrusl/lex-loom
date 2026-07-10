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

import os

from fastapi import FastAPI

app = FastAPI(title="app")


@app.get("/health")
def health() -> dict:
    return {"ok": True}


if __name__ == "__main__":
    import uvicorn

    port = int(os.environ.get("PORT", 8081))
    uvicorn.run(app, host="0.0.0.0", port=port)
