# lex-loom

[![CI](https://github.com/alpibrusl/lex-loom/actions/workflows/ci.yml/badge.svg)](https://github.com/alpibrusl/lex-loom/actions/workflows/ci.yml)

**Part of the [Lex](https://lexlang.org) project** — Agents · [Manifesto](https://lexlang.org/manifesto) · [All packages](https://lexlang.org)

**Autonomous companies.** Give loom a persistent goal and it runs a **company**: a
series of iterating sprint cycles — Architect, Build, QA, Demo, Retro, Digest —
that design, build, verify, ship, and learn from the result, carrying tightened
specs and agent memory forward between iterations until a grounded condition
says stop. A **sprint** is the primitive a company runs on each iteration; you
can also run a single sprint standalone to test one change.

Every phase transition is evidence-gated. Every artifact is content-addressed. The audit trail is append-only. The system learns: the Digest phase tightens specs and seeds the next iteration's graph from lessons in the current trail.

> **Status: sprint engine AND company layer complete** (epic #212, closed).
> The sprint pipeline (Intake → Design → Implementation → QA → Demo → Retro →
> Digest) with learning loop, agent pool scoring, bounce penalties, and
> retirement is complete. Above it, the full company layer is landed:
> **heartbeat** (a scheduler daemon owns every company in a workspace,
> external events wake dormant companies within seconds, runs are truly
> concurrent — HB1–3), **org structure** (reporting lines → typed delegation
> with rework → manager review → a CEO that proposes pivots → a board-approved
> dynamic role registry — ORG1–5), and **board governance** (blocking human
> gates, per-role budget envelopes, a revenue-driven allocation loop, and one
> typed board decision surface with append-only minutes — GOV1–4). The
> **Operate loop** (epic #118, on the shared
> [`lex-ctl`](https://github.com/alpibrusl/lex-ctl) kernel) is at v1:
> sensing → incident → capability-gated actuation → effect verification.
> Real monetization wiring (an actual Stripe/Gumroad product) is
> deliberately, permanently human-gated by design (#89) — see
> [`docs/design/agentic-company.md`](docs/design/agentic-company.md) for the
> full layer inventory and implementation index.

---

## The company lifecycle in three commands

```bash
# 1. Scaffold a company from a declarative manifest into a workspace
LOOM_WORKSPACE=~/loom-companies bin/bootstrap-company.sh examples/linksnap.company.toml --no-run

# 2. Start the heartbeat — a daemon that classifies, runs, monitors, and
#    wakes every company in the workspace (event wakes land within seconds)
LOOM_WORKSPACE=~/loom-companies bin/loom-scheduler.sh

# 3. Govern — see everything the company owes you an answer on, and decide
COMPANY_ID=linksnap DB_PATH=~/loom-companies/linksnap/company.db \
  lex run --allow-effects env,io,sql,fs_read,fs_write src/main.lex board_pending_cmd
ATTENTION_ID=<id> VERDICT=approved RESOLVER_ID=<your-contact-id> \
  DB_PATH=~/loom-companies/linksnap/company.db \
  lex run --allow-effects env,io,sql,fs_read,fs_write,time,random,crypto src/main.lex board_decide_cmd
```

Everything below — provider setup, the sprint primitive, the HTTP API — is in
service of that loop. See "Running a company" for the full surface.

---

## Quick start

Requirements: Docker, `gcloud` or an Anthropic API key, `curl`.

```bash
git clone https://github.com/alpibrusl/lex-loom
cd lex-loom
```

### With Vertex AI (Gemini 3.5 Flash)

```bash
# One-time: authenticate with gcloud
gcloud auth login

# Set up .env
cat > .env <<EOF
VERTEX_ACCESS_TOKEN=$(gcloud auth print-access-token)
VERTEX_PROJECT=your-gcp-project-id
EOF

# Build and run
GITHUB_TOKEN=your-token docker build --secret id=github_token,env=GITHUB_TOKEN -t lex-loom .
docker compose up -d
```

> Vertex AI access tokens expire after ~1 hour. Refresh with:
> `gcloud auth print-access-token` and update `.env`.

### With Anthropic

```bash
cat > .env <<EOF
ANTHROPIC_API_KEY=sk-ant-...
EOF
GITHUB_TOKEN=your-token docker build --secret id=github_token,env=GITHUB_TOKEN -t lex-loom .
docker compose up -d
```

### With Ollama via LiteLLM (local, no API key, recommended)

LiteLLM gives cleaner OpenAI-compatible tool calling over Ollama than the native Ollama adapter. Pull a model, start the proxy, then point lex-loom at it:

```bash
# 1. Pull the recommended local model
ollama pull qwen3-coder:30b

# 2. Start the LiteLLM proxy (includes qwen3-coder:30b and others)
cd litellm && docker compose up -d && cd ..

# 3. Build and run lex-loom
touch .env
GITHUB_TOKEN=your-token docker build --secret id=github_token,env=GITHUB_TOKEN -t lex-loom .

# 4. Run with a local model via the proxy
LITELLM_BASE_URL=http://localhost:4000 MODEL=qwen3-coder:30b \
  docker compose up -d
```

The LiteLLM proxy config (`litellm/config.yaml`) includes:

| Model | VRAM | Best for |
|-------|------|----------|
| `qwen3-coder:30b` | 45 GB | Code tasks (recommended) |
| `devstral-small-2:latest` | ~14 GB | Code tasks, lighter |
| `gemma4:26b` | 19 GB | General tasks (thinking model — see note below) |
| `gemma4:latest` | 10 GB | General tasks, lightest local option |

> **Thinking models (gemma4:26b):** These models generate 500–700 chain-of-thought tokens before producing any visible output. They also tend to emit tool calls as plain JSON text rather than using the `tool_calls` wire format, which degrades reliability under the large (10+ tool) schemas used by lex-loom agents. Use `qwen3-coder:30b` or `devstral-small-2` for Lex code generation tasks.

#### Running without Docker (host-direct)

```bash
# Start the proxy directly (no Docker)
litellm --config litellm/config.yaml --port 4000 &

# Run lex-loom against it
LITELLM_BASE_URL=http://localhost:4000 MODEL=qwen3-coder:30b \
  lex run --max-steps 200000000 \
  --allow-effects env,net,io,llm,proc,sql,fs_read,fs_write,time,crypto,random,concurrent,vcs \
  src/web/server.lex serve_loom
```

### With Ollama (native API, fallback)

The native Ollama adapter is used automatically when no cloud keys or `LITELLM_BASE_URL` are set. It uses the Ollama `/api/chat` wire format with an XML-based tool parser — functional but less reliable than LiteLLM for complex tool schemas.

```bash
touch .env
GITHUB_TOKEN=your-token docker build --secret id=github_token,env=GITHUB_TOKEN -t lex-loom .
OLLAMA_URL=http://host.docker.internal:11434 OLLAMA_MODEL=qwen3-coder:30b \
  docker compose up -d
```

---

## Running a company

A **company** is a *persistent goal* that produces a *series of iterating
sprints* (`<company>/iter-N`) instead of a single one-off run. Tightened specs
and agent memory carry forward between iterations, and the loop stops when a
grounded condition holds or `MAX_ITERATIONS` is reached. This is the primary,
recommended way to run loom — a single sprint (below) is the primitive it
iterates, useful on its own mainly for testing one change in isolation.

The fastest path is a declarative manifest — see
[`docs/design/company-manifest.md`](docs/design/company-manifest.md) and the
`create-company` skill:

```bash
bin/bootstrap-company.sh examples/linksnap.company.toml            # scaffold + run
bin/bootstrap-company.sh examples/linksnap.company.toml --no-run   # scaffold only, free
```

Or drive it directly with env vars:

```bash
COMPANY_ID=acme \
MODEL=deepseek-v4-pro \
MAX_ITERATIONS=3 \
STOP_WHEN='verdict-passed' \
GOAL='Write a pure Lex function add(a :: Int, b :: Int) -> Int with an examples block.' \
bin/run-company.sh
```

`STOP_WHEN` uses the company condition DSL (also usable as a node `activate_when`
to gate a sub-loom to specific iterations):

| Condition | True when |
|---|---|
| `iter ge N` / `iter lt N` / `iter eq N` | iteration index bound |
| `verdict-passed` / `verdict-failed` | last iteration's verifier verdict |
| `digest contains "<s>"` | substring in the digest summary |
| `accepted ge N` / `bounced ge N` | node accept/bounce thresholds |
| `spend ge N` | cumulative LLM/infra spend threshold |
| `always` / `never` | constant |
| `<a> or <b>` | disjunction of any atoms above (or event kinds, below) |
| `board_note`, `support_item`, `incident`, `operate_signal`, `research_request`, `content_request`, `webhook` | *(wake_when only)* an unconsumed external event of that kind exists — see "Event wakes" |

Each iteration is recorded in `company_iterations` (with parent lineage) and
stays provable via the four-layer verifier (`verify_sprint_cmd`). See
[`docs/design/agentic-company.md`](docs/design/agentic-company.md) for the full
picture of what a company is beyond the build loop — Distribution, Monetization
(deliberately human-gated), the Operate loop, Strategy, Org, Board, and
Lifecycle.

### The heartbeat (scheduler daemon)

Run one long-lived process per **workspace** (a directory of
`<company-id>/company.db` folders — one SQLite file per company). Each tick
it classifies every company from its own persisted state (run / dormant /
stopped / parked / sunset), runs up to `MAX_RUNS_PER_TICK` of them
**concurrently**, and gives everyone else the between-run monitor sweep
(revenue, liveness, operate signals). Killing and restarting it is always
safe — all state lives in the company DBs.

```bash
LOOM_WORKSPACE=~/loom-companies TICK_MS=60000 EVENT_POLL_MS=2000 \
  MAX_RUNS_PER_TICK=2 bin/loom-scheduler.sh
```

### Event wakes

A dormant company (Maintenance stage) declares which external events wake it
in its manifest — `wake_when board_note or support_item` — and the scheduler
wakes it within seconds of one arriving (bypassing the periodic tick). Events
land in an append-only per-company ledger with one-shot consumption marks:
replaying it is the wake history (`events_cmd`). Writers: board notes, the
operate sweep (incident opened / revenue moved), the A2A capability servers,
and a token-gated generic webhook (`POST /api/events/:company_id`). Event
bodies are data, never instruction — they carry ids, never caller text, and
never reach a prompt.

### Governing (the board surface)

Everything the company owes a human flows through ONE typed queue — blocking
`human <oracle>` gates (which park the company), budget-exhaustion
escalations, allocation proposals, CEO strategy proposals, role-creation
approvals, operate escalation dossiers:

```bash
COMPANY_ID=acme lex run ... src/main.lex board_pending_cmd   # typed, aged queue
COMPANY_ID=acme lex run ... src/main.lex board_report_cmd    # leads with the queue
ATTENTION_ID=<id> VERDICT=approved|rejected|deferred REASON="..." RESOLVER_ID=<contact> \
  lex run ... src/main.lex board_decide_cmd                  # THE one decide path
COMPANY_ID=acme lex run ... src/main.lex board_minutes_cmd   # append-only minutes
```

`RESOLVER_ID` is required and recorded on every decision; when a contact is
registered for an oracle (`add_contact_cmd`), only that contact may decide
(#165). The web API (`/api/board/pending`, `/api/board/decide/:id`) calls the
exact same function. There is no auto-approve path, anywhere, by design.

Budgets: give roles spend envelopes in the manifest (`[budget.envelopes]`) or
via `budget_set_cmd`; a node whose role's envelope is exhausted is refused at
dispatch (never overdrafted), and the exhaustion escalates to the board.

> Against OpenCode Go, leave `OPENCODE_BASE_URL` unset (hit the API directly) —
> the local reasoning-proxy breaks loom's streaming agent loop.

### Optional sandboxing under lex-os

Each sprint phase already carries a role-scoped capability grant
(`src/manifests.lex` — e.g. Design is read-only with no exec, Build is
read-write with sandboxed exec, QA gets sandboxed exec for running tests). That
grant is shaped to run directly as a [lex-os](https://github.com/alpibrusl/lex-os)
manifest, so a company's agents can execute inside lex-os's sealed, disposable
boxes instead of ad hoc Docker isolation. lex-os is optional — loom runs fully
without it today — and the wiring from a generated grant to an actual lex-os
capsule install is still open; see
[`docs/design/lex-os-isolation.md`](docs/design/lex-os-isolation.md) for the
per-role grant table and rollout plan.

---

## Running a single sprint

The server listens on `http://localhost:8880`. Sprint IDs are generated automatically.

```bash
curl -X POST http://localhost:8880/api/sprints \
  -H "Content-Type: application/json" \
  -d '{
    "request": "Build a FastAPI task manager with in-memory storage. Endpoints: POST /tasks, GET /tasks (with ?status= and ?priority= filters), GET /tasks/{id}, PATCH /tasks/{id}, DELETE /tasks/{id}. Each task has id (uuid), title, description, priority (low|medium|high), status (pending|done), created_at, updated_at. Single file: main.py.",
    "model": "gemini-3.5-flash"
  }'
```

Response:

```json
{
  "sprint_id": "sprint-e4bf5f79207e7302",
  "success": true,
  "summary": "Sprint sprint-e4bf5f79207e7302 complete. Demo: ..."
}
```

Inspect the trail, retrieve artifacts, and read the digest:

```bash
SPRINT=sprint-e4bf5f79207e7302

# Phase transitions
curl http://localhost:8880/api/sprints/$SPRINT/status | jq '.transitions'

# Full audit trail
curl http://localhost:8880/api/sprints/$SPRINT/trail | jq '.events[] | {kind: .event_kind, data: .data_json}'

# Get a specific artifact by hash
curl http://localhost:8880/api/sprints/$SPRINT/artifact/<hash> | jq -r '.content'

# Digest: lessons learned + tightened specs + next sprint seed graph
curl http://localhost:8880/api/sprints/$SPRINT/digest | jq .
```

---

## Demo results

### Simple function

**Request:** `"Write a Python function called add(a, b) that returns the sum of two numbers, with a brief docstring."`

**Generated `add` function (QA: PASS):**

```python
def add(a: int | float, b: int | float) -> int | float:
    """Adds two numerical inputs (int or float) and returns their sum.

    Enforces strict runtime type-checking to guarantee thread-safety and
    deterministic behavior within the ArithmeticEngine.

    Args:
        a (int | float): The first term.
        b (int | float): The second term.

    Returns:
        int | float: The sum of a and b.

    Raises:
        TypeError: If either a or b is not an instance of int or float.
    """
    if not isinstance(a, (int, float)) or isinstance(a, bool):
        raise TypeError(f"Argument 'a' must be an int or float, received {type(a).__name__}")
    if not isinstance(b, (int, float)) or isinstance(b, bool):
        raise TypeError(f"Argument 'b' must be an int or float, received {type(b).__name__}")
    return a + b
```

---

### Mini REST API

**Request:** `"Build a FastAPI task manager with in-memory storage. Endpoints: POST /tasks, GET /tasks (with ?status= and ?priority= filters), GET /tasks/{id}, PATCH /tasks/{id}, DELETE /tasks/{id}. Each task has id (uuid), title, description, priority (low|medium|high), status (pending|done), created_at, updated_at. Single file: main.py."`

**Sprint graph produced by Architect:** `arch-spec → build-api → qa-verify → demo-run → scribe-docs`

**Generated `main.py` (QA: PASS):**

```python
from datetime import datetime, timezone
from enum import Enum
from typing import List, Optional
from uuid import UUID, uuid4

import uvicorn
from fastapi import FastAPI, HTTPException, Path, Query, status
from pydantic import BaseModel, Field


class Priority(str, Enum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"


class Status(str, Enum):
    PENDING = "pending"
    DONE = "done"


class TaskCreate(BaseModel):
    title: str = Field(..., min_length=1)
    description: Optional[str] = None
    priority: Priority = Field(default=Priority.MEDIUM)


class TaskUpdate(BaseModel):
    title: Optional[str] = Field(None, min_length=1)
    description: Optional[str] = None
    priority: Optional[Priority] = None
    status: Optional[Status] = None


class Task(BaseModel):
    id: UUID
    title: str
    description: Optional[str] = None
    priority: Priority
    status: Status
    created_at: datetime
    updated_at: datetime


app = FastAPI(title="Task Manager API", version="1.0.0")
tasks_db: dict[UUID, Task] = {}


def get_utc_now() -> datetime:
    return datetime.now(timezone.utc)


@app.post("/tasks", response_model=Task, status_code=status.HTTP_201_CREATED)
def create_task(payload: TaskCreate):
    now = get_utc_now()
    task = Task(id=uuid4(), title=payload.title, description=payload.description,
                priority=payload.priority, status=Status.PENDING, created_at=now, updated_at=now)
    tasks_db[task.id] = task
    return task


@app.get("/tasks", response_model=List[Task])
def list_tasks(
    status_filter: Optional[Status] = Query(None, alias="status"),
    priority_filter: Optional[Priority] = Query(None, alias="priority"),
):
    results = list(tasks_db.values())
    if status_filter is not None:
        results = [t for t in results if t.status == status_filter]
    if priority_filter is not None:
        results = [t for t in results if t.priority == priority_filter]
    return results


@app.get("/tasks/{id}", response_model=Task)
def get_task(id: UUID = Path(...)):
    if id not in tasks_db:
        raise HTTPException(status_code=404, detail="Task not found")
    return tasks_db[id]


@app.patch("/tasks/{id}", response_model=Task)
def update_task(id: UUID = Path(...), payload: TaskUpdate = ...):
    if id not in tasks_db:
        raise HTTPException(status_code=404, detail="Task not found")
    existing = tasks_db[id]
    update_data = payload.model_dump(exclude_unset=True)
    if not update_data:
        return existing
    updated = existing.model_copy(update=update_data)
    updated.updated_at = get_utc_now()
    tasks_db[id] = updated
    return updated


@app.delete("/tasks/{id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_task(id: UUID = Path(...)):
    if id not in tasks_db:
        raise HTTPException(status_code=404, detail="Task not found")
    del tasks_db[id]


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
```

**Scribe digest (excerpt):**

> *"Lessons learned: using timezone-aware datetimes (datetime.now(timezone.utc)) is crucial for consistency. Strict UUID path parameters automatically reject malformed IDs with 422 before hitting application logic. For the next sprint: add thread-safety via threading.Lock and add a persistent SQLite layer."*

---

## HTTP API

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/sprints` | Launch sprint. Body: `{request, model, sprint_id?}` |
| `GET` | `/api/sprints/:id/status` | Phase transitions + trail count |
| `GET` | `/api/sprints/:id/trail` | Full audit trail (all events) |
| `GET` | `/api/sprints/:id/artifact/:hash` | Retrieve content-addressed artifact |
| `GET` | `/api/sprints/:id/digest` | Tightened specs + seed graph flag |
| `GET` | `/api/sprints/:id/graph` | The sprint graph JSON produced by Architect |

Sprint IDs are auto-generated (`sprint-<hex8>`) if not supplied in the request body.

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `VERTEX_ACCESS_TOKEN` | — | GCP OAuth2 access token (`gcloud auth print-access-token`) |
| `VERTEX_PROJECT` | — | GCP project ID |
| `VERTEX_LOCATION` | `eu` | Vertex AI region (`eu`, `us`, `global`, or `europe-west1`) |
| `ANTHROPIC_API_KEY` | — | Anthropic API key |
| `OLLAMA_URL` | `http://localhost:11434` | Ollama base URL |
| `DB_PATH` | `/data/loom.db` | SQLite database path |
| `PORT` | `8880` | HTTP server port |

**Provider selection priority:** Vertex AI (if `VERTEX_ACCESS_TOKEN` + `VERTEX_PROJECT` set) → Anthropic (if `ANTHROPIC_API_KEY` set) → Ollama.

---

## "The Sprint That Fixes Itself" demo

A scripted two-sprint sequence showing the learning loop in action. No LLM required for Build or Scribe — proc_cmd agents make it deterministic and fast.

**Sprint 1** — User Registration API  
Build outputs bad code (no email validation). QA catches it and bounces back to Implementation. Build retries with good code. QA passes. Scribe Digest encodes the lesson as a tightened gate: `spec contains EMAIL_REGEX` for `role=build`.

**Sprint 2** — Team Invite API (different task, same rule)  
Architect reads the tightened spec from Sprint 1's Digest and sets the Build gate before QA runs. Build produces code with `EMAIL_REGEX` on the first attempt — gate fires immediately, QA never needs to catch it.

```bash
export VERTEX_ACCESS_TOKEN=$(gcloud auth print-access-token)
export VERTEX_PROJECT=your-gcp-project
./demo/run.sh
```

The spec is in the substrate. The model did not get smarter. The constraint got earlier.

---

## Offline demo (no LLM)

Exercises graph validation, metaspec rules, phase state machine, and semantic diff — no API key required:

```bash
lex pkg install
lex run --allow-effects fs_write,io,sql,time src/hello.lex hello
```

Expected output:

```
lex-loom hello world
─────────────────────────────────────────
1. Graph validation
  ✓ valid graph passes graph.validate
  ✓ valid graph passes metaspec.check
  ✓ demo without qa rejected by metaspec
─────────────────────────────────────────
2. JSON round-trip
  ✓ serialize → parse round-trip
─────────────────────────────────────────
3. Phase state machine (full Intake → Digest walk)
  ✓ full phase walk completes without error
─────────────────────────────────────────
4. Semantic diff
  ✓ diff detects 1 changed + 1 added node
  nodes to re-run: 3 — build review qa
```

---

## Architecture

Two layers with very different change rates:

| Layer | Authored by | Trusted because |
|---|---|---|
| **SprintGraph** — which agents, which edges, which gates | LLM Architect, re-derived per request | typed value validated against schema + meta-spec before execution |
| **Executor** — how any graph runs, what may flow | written once in Lex | spec gates at both ends, append-only trail |

### Sprint cycle

```
Intake → Design → Implementation → QA → Demo → Retro → Digest ─┐
   ↑                                                            │
   └──────────────── next sprint, seeded by Digest ─────────────┘
```

### Gate DSL

Each node in the sprint graph carries a gate expression evaluated against its output before the next node may proceed:

| Expression | Meaning |
|---|---|
| `spec non-empty` | output must not be empty |
| `spec len-gt N` | output must be longer than N characters |
| `spec contains <str>` | output must contain the literal string `<str>` |
| `spec json` | output must be valid JSON |
| `spec json-field <key>` | output must be JSON containing `<key>` |
| `spec json-verdict-pass` | output must be JSON `{"verdict":"PASS",...}` (use for QA nodes) |
| `human <oracle>` | queued for named human attestation |

### Learning loop

The **Digest** phase reads the sprint trail and emits:
- **Tightened specs** — QA misses become gate preconditions for matching roles next sprint
- **Seed graph** — starting topology for the next sprint, loaded automatically by the Architect

### Agent pool and Cast phase

Between Design and Implementation, a **Cast phase** runs — think HR for agents. It selects the best specialist from the `agent_pool` table for each node in the sprint graph.

**Scoring:** each candidate is ranked by `attestation_count + domain_bonus`. Domain bonus adds +10 for every tag in the agent's `domain_tags_json` that appears in the sprint request. A build agent with tags `["ocpp", "ev", "charging"]` scores +30 on a request mentioning all three.

**Fallback:** if no pool agent exists for a role, the generic default prompt for that role runs.

**Seeded specialists** (`pool_seed.lex`, inserted on first startup with `INSERT OR IGNORE`):

| ID | Role | Domain tags |
|---|---|---|
| `ocpp-build-v1` | build | ocpp, ev, charging, websocket, lex |
| `finance-build-v1` | build | finance, fix, oms, risk, positions, lex |
| `strict-qa-v1` | qa | lex, qa, strict |
| `general-scribe-v1` | scribe | lex, scribe |

**Pool executor types:** `model_name` in the pool drives which executor fires per node:
- Plain model name (e.g. `gemini-3.5-flash`) → LLM executor
- `proc:<cmd>` → shell command; full input piped via stdin, stdout is the artifact
- `a2a:<url>` → remote agent called via A2A JSON-RPC `tasks/send`

**Attestation feedback:** at sprint end, accepted nodes earn `attestation_count + 1`. Denied/bounced nodes lose `attestation_count − 1` and `bounce_count + 1`. Agents that reach `attestation_count ≤ −3` are soft-retired (`retired_at` set) and excluded from future casts. Specialists earn reputation over time; chronically failing agents sink out of contention automatically.

**did:lex portable reputation (#52):** every pool agent carries a `did:lex:agent:<hash-of-pubkey>` identity with a loom-custodied Ed25519 key. When `verify_sprint_cmd` re-derives a sprint's four verdicts (integrity → grounded → authority → operations), each granted agent receives a **signed attestation bundle** binding those verdicts to its did — checkable outside the issuing loom via `identity.verify_attestation(pubkey, bundle, sig)`. Reputation is never stored: it is the count of *verified* attestations per did (`lex run … src/main.lex reputation_cmd` prints the registry), so it accrues only from independently verified runs, and the Cast weighs it above raw local attestations (`+3` per verified run) but below a domain-tag match.

**Improver:** after the Scribe's Digest, an LLM rewrites the system prompt of the best current agent for each role that had a tightened spec. The improved agent is saved to the pool as `<role>-improved-<sprint-id>` with `attestation_count = parent + 2` — it starts two points ahead of its parent, giving it a genuine edge in the next cast while still needing to earn further trust.

This is loom-specific logic — the platform registry (`src/agent/registry.lex`) handles A2A routing for live processes; the pool is about which *prompt* runs for each graph node.

---

## Module map

```
src/
  agent/
    runner.lex       LLM step loop — load state, run lex-llm, save state, trace
    trace.lex        Append-only audit log (traces table)
    state_store.lex  Per-agent JSON state persistence
    registry.lex     Agent registration and discovery
    relationships.lex Directed auth graph between agents
    a2a.lex          Outgoing agent-to-agent HTTP messages

  graph.lex          SprintGraph / Node / Edge ADTs, validate, topo_sort, JSON round-trip
  phase.lex          Phase sum type, evidence-consuming advance(), legal-transition table
  metaspec.lex       6 rules: non-empty, gates, handoffs, DAG, qa-dominates-demo
  gates.lex          Gate DSL evaluator
  diff.lex           Semantic diff — NodeDiff / EdgeDiff, nodes_to_rerun
  migrate.lex        Full DDL (platform tables + loom-specific tables)
  roles.lex          AgentDef constructors: architect / build / qa / demo / scribe
  transport.lex      Four planes: trail, artifact store, A2A send, node-job queue
  orchestrator.lex   run_phase (topo layers, gate at both ends) + run_sprint
  cast.lex           Cast phase — scores agent_pool by attestation + domain tags, builds Roster
  pool_seed.lex      Seeds domain-specialist agents into agent_pool on startup
  improver.lex       Post-Digest prompt rewriter — saves improved agents back into pool at count=0
  digest.lex         Trail reading, Scribe invocation, tightened_spec storage
  tenant.lex         Sprint registration in agent registry
  company.lex        The layer above a single sprint — a company runs a series of them
  company_runner.lex Auto loop-back runner: finishes a sprint, seeds and starts the next
  scheduler.lex      The heartbeat daemon (HB1/HB3): classify, run concurrently, monitor
  events.lex         Append-only external-event ledger + wake grammar (HB2)
  gates.lex          Blocking human gates that park a company (GOV1) + gate DSL
  budget.lex         Per-role spend envelopes, enforced at dispatch (GOV2)
  allocation.lex     Revenue-driven envelope proposals, board-approved, self-grading (GOV3)
  board.lex          The typed board decision surface + append-only minutes (GOV4)
  org.lex            Reporting lines + escalation chains (ORG1)
  delegation.lex     Typed, closed-vocabulary delegation with rework cycles (ORG2)
  manager.lex        Manager review: verdicts → attestations + reports upward (ORG3)
  ceo.lex            Goal origination above the Strategist + mission ledger (ORG4)
  role_registry.lex  Role packs + bounded, board-approved runtime role creation (ORG5)
  sensing.lex        Operate loop: score signals, open incidents (CTL3)
  diagnosis.lex      Operate loop: diagnose incidents (CTL4)
  effects.lex        Operate loop: remediation contracts + verification (CTL5)
  actuation.lex      Operate loop: capability-gated actions behind tiers (CTL6)
  operate_ledger.lex The controller's queryable record (CTL2)
  soft_settlement.lex Revenue readings settled + re-verifiable via lex-soft (SA3)
  soft_register.lex  Mesh registration/discovery on lex-soft (SA2)
  series.lex         Sprint-series statistics for the improvement chart
  verify.lex         Independent re-derivation of a sprint's integrity from the trail
  loom_trail.lex     Sprint trail backed by lex-trail (content-addressed, append-only)
  manifests.lex      Sprint and per-phase trust manifests (lex-os integration)
  identity.lex       did:lex portable agent reputation
  role_tools.lex     Single source of truth for which tools each role may call
  lex_skill.lex      Lex-language skill — ground-truth tools for the agents
  dag_view.lex       Render a sprint graph (and expand-node sub-sprints) for the UI
  cloud.lex          Cloud polling mode for the runner
  debug_model.lex    Diagnose which Ollama models work with lex-llm's provider
  worker.lex         Durable-queue worker process (loom:node queue)
  hello.lex          Offline demo — no LLM, no DB
  main.lex           CLI entry point (init_db / run_sprint_cmd / sprint_status / sprint_trail / sprint_digest)
  web/
    server.lex       HTTP server — POST /api/sprints + status/trail/artifact/digest routes
  server/
    a2a.lex          A2A HTTP front door
    mcp.lex          MCP stdio front door — exposes skills as Claude Code tools
    cx_a2a.lex       Token-gated CX support-triage skill (SA2)
    research_a2a.lex Token-gated web-research skill (SA4)
    content_a2a.lex  Token-gated content-publishing skill (#187)

tests/                49 suites, no LLM required. Core: graph, phase,
                      metaspec, gates, cast, company. Company layer:
                      scheduler, events, concurrency, blocking_gates,
                      budget, allocation, board, org, delegation, manager,
                      ceo, role_registry, soft_settlement. Operate loop:
                      sensing, diagnosis, effects, actuation, operate
                      ledger. Plus identity, improver, verify (+ shell
                      gate), attention, web_auth, and more.
```

---

## Tests

```bash
lex test --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,approval tests
# 49 suites — no LLM, no API key required
```

The fully offline roundtrip demos in `demo/` are the acceptance proofs for
each company-layer pillar (heartbeat, event wakes, concurrency, delegation,
manager review, CEO, roles, budgets, allocation, board surface) — CI runs
them as a smoke job.

---

## MCP front door

Expose sprint controls to Claude Code or Cursor:

```bash
DB_PATH=loom.db \
  lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs \
  src/server/mcp.lex run_mcp_server
```

Tools: `start_sprint` · `sprint_status` · `sprint_trail` · `sprint_digest`.

---

## Cloud runner (BYOK against loom-cloud)

Execute cloud-queued sprints from your own machine — your keys, your models.
`cloud_poll` claims one queued sprint, runs the agent pipeline locally, and
uploads the trail + verdict back to the control plane.

```bash
export LOOM_SERVER=https://loom.lexlang.org
export LOOM_RUNNER_TOKEN=<register a runner in the dashboard / via the CLI>

# Pick a provider:
export VERTEX_PROJECT=my-gcp-project \
       VERTEX_ACCESS_TOKEN="$(gcloud auth print-access-token)"   # Vertex Gemini
# or
export OLLAMA_MODEL=glm-4.7-flash                                # local Ollama

# IMPORTANT: a full 5-agent sprint exceeds the lex VM's default 10M step
# budget, so pass --max-steps (>= 200M). Without it the runner panics
# mid-sprint with "step limit exceeded". (#12)
lex run --max-steps 200000000 \
  --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs \
  src/main.lex cloud_poll
```

Loop it (cron / `while true; do … ; sleep 5; done`) to keep claiming sprints.

---

## Built on

`lex-llm` · `lex-agent` · `lex-spec` · `lex-schema` · `lex-jobs` · `lex-mcp` · `lex-web` · `lex-orm` · `lex-trail` · `lex-log`

Agent runtime (runner, trace, state store, registry, A2A) is vendored directly into `src/agent/` — loom is self-contained with no lex-soft runtime dependency. It does depend on two shared packages that place loom in the wider Lex ecosystem: `lex-ctl` (the Operate loop's mechanism kernel, also consumed independently by [lex-soft](https://github.com/alpibrusl/lex-soft) — loom's cross-org counterpart) and `lex-os-manifest` (the grant type optional [lex-os](https://github.com/alpibrusl/lex-os) sandboxing is built on). For how loom, lex-ctl, lex-soft, and lex-os fit together — what's wired vs. designed vs. not started — see [lex-lang's ecosystem model](https://github.com/alpibrusl/lex-lang/blob/main/docs/design/ecosystem-model.md).

---

## Milestones

| | Status | Description |
|---|---|---|
| M0 | ✓ | Design doc |
| M1 | ✓ | `graph.lex` + `phase.lex` + `metaspec.lex` with full tests |
| M2 | ✓ | `orchestrator.lex` + `transport.lex`, in-process Intake→Demo pass |
| M3 | ✓ | Architect emits real `SprintGraph`s; semantic diff re-planning |
| M4 | ✓ | `digest.lex` — Scribe closes the learning loop |
| M5 | ✓ | Durable queue + multi-tenancy + HTTP API + Vertex AI / Anthropic / Ollama |
| M5+ | ✓ | Pool fitness loop — bounce penalty, agent retirement, proc/a2a executors, "Sprint That Fixes Itself" demo |
| M6 | ✓ | `lex-vcs` — artifacts by content hash on a branch per sprint |
| Company | ✓ | Company layer complete (epic #212): heartbeat HB1–3, org structure ORG1–5, board governance GOV1–4 — plus Operate loop v1 (#118) and soft/os-aware agents (#177) |

---

## License

EUPL-1.2 — matches the rest of the lex ecosystem.

---

Built under the principles of [Trust Without Comprehension](https://lexlang.org/manifesto).
