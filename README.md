# lex-loom

Multi-agent **sprint cycles** for the Lex ecosystem — take a project request and drive it end-to-end through Intake → Design → Implementation → QA → Demo → Retro → Digest, with a dynamic agent graph derived per request and a learning loop that tightens specs across sprints.

> **Status: M5 complete.** All milestones implemented and tested. `lex ci` passes; full sprint runs against Ollama (`qwen3-coder:30b`) and Anthropic Claude.

Built under the principles of [Trust Without Comprehension](https://alpibru.com/manifesto).

---

## The idea in one line

> *"the substrate carries the constraints; the model fills the bodies; the type system verifies the result."* — §VI

The **interaction graph is data** — a typed, content-addressed `SprintGraph` produced by an Architect agent, validated before execution. The **executor is a fixed, effect-typed interpreter** of that graph. No agent trusts another by reading its output — it trusts a typed handoff, a spec gate evaluated at both ends, an honest effect row, and a hash-chained attestation.

---

## Quick start

### Offline demo (no LLM needed)

Exercises graph validation, metaspec rules, phase state machine, and semantic diff:

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

### Live sprint (Ollama)

Requires [Ollama](https://ollama.com) running locally with a compatible model pulled.

```bash
OLLAMA_MODEL=qwen3-coder:30b \
SPRINT_ID=sprint-1 \
REQUEST="Write a Lex function that reverses a list of strings." \
  lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc \
  src/main.lex run_sprint_cmd
```

The Digest at end of sprint writes tightened specs to the DB. Sprint-2 automatically inherits them:

```bash
SPRINT_ID=sprint-2 REQUEST="..." lex run ... src/main.lex run_sprint_cmd
```

### Live sprint (Anthropic)

```bash
export ANTHROPIC_API_KEY=sk-ant-...
SPRINT_ID=sprint-1 REQUEST="..." \
  lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc \
  src/main.lex run_sprint_cmd
```

### Tests

```bash
lex test tests/
# 3 passed, 0 failed  (graph · phase · metaspec — no LLM required)
```

### CI

```bash
lex ci
# pkg install → check --strict → fmt --check → test — all green
```

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `DB_PATH` | `loom.db` | SQLite database path |
| `MODEL` / `OLLAMA_MODEL` | `gemma4:latest` | LLM model name |
| `SPRINT_ID` | `sprint-1` | Sprint identifier (also tenant key) |
| `REQUEST` | built-in toy | Project request text |
| `LOOM_BASE_URL` | `http://localhost:9100` | Base URL for A2A AgentCard |
| `POLL_MS` | `500` | Queue poll interval for distributed workers |

**Provider selection:** if `ANTHROPIC_API_KEY` is set and non-empty → Anthropic. Otherwise → `ollama_local()` (requires Ollama at `http://localhost:11434`).

**Compatible Ollama models:** `qwen3-coder:30b`, `gemma4:26b`, `gemma4:latest`.

---

## Architecture

Two layers with very different change rates:

| Layer | Authored by | Trusted because |
|---|---|---|
| **SprintGraph** — which agents, which edges, which gates | LLM Architect, re-derived per request | typed value validated against schema + meta-spec before execution |
| **Executor** — how any graph runs, what may flow | written once in Lex | effect rows, spec gates at both ends, append-only trail |

### Sprint cycle

```
Intake → Design → Implementation → QA → Demo → Retro → Digest ─┐
   ↑                                                            │
   └──────────────── next sprint, seeded by Digest ─────────────┘
```

### Four communication planes

| Plane | Substrate | Used for |
|---|---|---|
| Control/work | `lex-jobs` queue | phase fan-out, node-job enqueue/await |
| Inter-agent | A2A (`lex-agent`) | typed capability calls between roles |
| Artifacts | SQLite content-hash store | node output stored by hash ref, never payload |
| Trail/audit | `lex-soft/trace` | every event appended, tamper-evident |

### Learning loop

The **Digest** phase reads the sprint trail and emits:
- **Tightened specs** — QA misses become gate preconditions for matching roles next sprint
- **Seed graph** — starting topology for the next sprint, loaded automatically by the Architect

*Learning is encoded into the substrate's constraints, not stuffed into a prompt.*

---

## Module map

```
src/
  graph.lex         SprintGraph / Node / Edge ADTs, validate, topo_sort, JSON round-trip
  phase.lex         Phase sum type, evidence-consuming advance(), legal-transition table
  metaspec.lex      6 rules: non-empty, gates, handoffs, DAG, qa-dominates-demo
  diff.lex          Semantic diff — NodeDiff / EdgeDiff, nodes_to_rerun
  migrate.lex       DDL — extends lex-soft schema (sprint_graphs, artifacts, digests, …)
  roles.lex         AgentConfig for architect / build / qa / demo / scribe
  transport.lex     Four planes: trail, artifact_put/get, A2A send, node-job queue
  orchestrator.lex  run_phase (topo layers, gate at both ends) + run_sprint
  digest.lex        Trail reading, Scribe invocation, tightened_spec storage
  tenant.lex        Sprint registration in lex-soft registry
  worker.lex        Durable-queue worker process (loom:node queue)
  hello.lex         Offline demo — no LLM, no DB
  main.lex          CLI entry point (run_sprint_cmd)
  server/
    a2a.lex         A2A HTTP front door (start / status / trail / digest)
    mcp.lex         MCP stdio front door — exposes skills as Claude Code tools

tests/
  test_graph.lex    13 tests: validation, topo sort, JSON round-trip
  test_phase.lex    20 tests: legal transitions, wrong evidence, illegal moves
  test_metaspec.lex 11 tests: rule acceptance/rejection, multiple violations
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

## Distributed worker mode

```bash
# Terminal 1 — orchestrator
SPRINT_ID=sprint-1 REQUEST="..." lex run ... src/main.lex run_sprint_cmd

# Terminal 2+ — workers
DB_PATH=loom.db lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc \
  src/worker.lex run_worker
```

---

## Built on

`lex-soft` · `lex-llm` · `lex-agent` · `lex-spec` · `lex-schema` · `lex-jobs` · `lex-mcp`

lex-loom is a domain application of **lex-soft** — the multi-agent platform providing registry, outbox, runner, trace, and state store. See [§17 of the design doc](docs/design/sprint-cycles.md) for the full lineage map.

---

## Milestones

| | Status | Description |
|---|---|---|
| M0 | ✓ | Design doc |
| M1 | ✓ | `graph.lex` + `phase.lex` + `metaspec.lex` with full tests |
| M2 | ✓ | `orchestrator.lex` + `transport.lex`, in-process Intake→Demo pass |
| M3 | ✓ | Architect emits real `SprintGraph`s; semantic diff re-planning |
| M4 | ✓ | `digest.lex` — Scribe closes the learning loop |
| M5 | ✓ | Durable queue + multi-tenancy + MCP/A2A front door |
| M6 | — | `lex-vcs` — artifacts by content hash on a branch per sprint |

---

Built under the principles of [Trust Without Comprehension](https://alpibru.com/manifesto).
