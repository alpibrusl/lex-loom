# lex-loom

[![CI](https://github.com/alpibrusl/lex-loom/actions/workflows/ci.yml/badge.svg)](https://github.com/alpibrusl/lex-loom/actions/workflows/ci.yml)

**Part of the [Lex](https://lexlang.org) project** — Agents · [Manifesto](https://lexlang.org/manifesto) · [All packages](https://lexlang.org)

Multi-agent **sprint cycles** — give it a task, watch a pipeline of specialised agents design, build, verify, document, and learn from the result.

Every phase transition is evidence-gated. Every artifact is content-addressed. The audit trail is append-only. The system learns: the Digest phase tightens specs and seeds the next sprint's graph from lessons in the current trail.

> **Status: M5 complete + pool fitness loop.** Full sprint pipeline (Intake → Design → Implementation → QA → Demo → Retro → Digest) with learning loop, agent pool scoring, bounce penalties, and retirement running on Vertex AI / Anthropic / Ollama.

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

### With Ollama (local, no API key)

```bash
# Requires Ollama running at localhost:11434 with a model pulled
# (qwen3-coder:30b and gemma4:latest work well)
touch .env
GITHUB_TOKEN=your-token docker build --secret id=github_token,env=GITHUB_TOKEN -t lex-loom .
docker compose up -d
```

---

## Running a sprint

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
lex run --allow-effects io src/hello.lex hello
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
  worker.lex         Durable-queue worker process (loom:node queue)
  hello.lex          Offline demo — no LLM, no DB
  main.lex           CLI entry point (init_db / run_sprint_cmd / sprint_status / sprint_trail / sprint_digest)
  web/
    server.lex       HTTP server — POST /api/sprints + status/trail/artifact/digest routes
  server/
    a2a.lex          A2A HTTP front door
    mcp.lex          MCP stdio front door — exposes skills as Claude Code tools

tests/
  test_graph.lex     13 tests: validation, topo sort, JSON round-trip
  test_phase.lex     20 tests: legal transitions, wrong evidence, illegal moves
  test_metaspec.lex  11 tests: rule acceptance/rejection, multiple violations
```

---

## Tests

```bash
lex test tests/
# 3 passed, 0 failed  (graph · phase · metaspec — no LLM required)
```

---

## MCP front door

Expose sprint controls to Claude Code or Cursor:

```bash
DB_PATH=loom.db \
  lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc \
  src/server/mcp.lex run_mcp_server
```

Tools: `start_sprint` · `sprint_status` · `sprint_trail` · `sprint_digest`.

---

## Cloud runner (BYOK against loom-cloud)

Execute cloud-queued sprints from your own machine — your keys, your models.
`cloud_poll` claims one queued sprint, runs the agent pipeline locally, and
uploads the trail + verdict back to the control plane.

```bash
export LOOM_SERVER=https://loom.alpibru.com
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
  --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc \
  src/main.lex cloud_poll
```

Loop it (cron / `while true; do … ; sleep 5; done`) to keep claiming sprints.

---

## Built on

`lex-llm` · `lex-agent` · `lex-spec` · `lex-schema` · `lex-jobs` · `lex-mcp` · `lex-web`

Agent runtime (runner, trace, state store, registry, A2A) is vendored directly into `src/agent/` — loom is self-contained with no lex-soft dependency.

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
| M6 | — | `lex-vcs` — artifacts by content hash on a branch per sprint |

---

Built under the principles of [Trust Without Comprehension](https://alpibru.com/manifesto).
