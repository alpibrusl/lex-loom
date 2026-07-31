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


# Read by the company's own strategic planning (the Strategist agent between
# iterations), never by end users. As the product's domain model grows, keep
# this returning a short, honest summary of REAL usage (row counts, notable
# trends) so the company can steer itself on its own data instead of flying
# blind between iterations. Build agents extend this — do not leave it as
# the trivial stub past the first real feature.
@app.get("/loom/usage")
def loom_usage() -> dict:
    return {"summary": "no usage data yet"}


if __name__ == "__main__":
    import uvicorn

    port = int(os.environ.get("PORT", 8081))
    uvicorn.run(app, host="0.0.0.0", port=port)
