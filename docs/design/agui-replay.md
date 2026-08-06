# AG-UI replay for sprint nodes

Status: done. Sparked by two new sibling packages,
[`lex-ag-ui`](https://github.com/alpibrusl/lex-ag-ui) and
[`lex-a2ui`](https://github.com/alpibrusl/lex-a2ui) — the ecosystem's
Lex implementations of [AG-UI](https://docs.ag-ui.com) (Agent-User
Interaction Protocol) and [A2UI](https://a2ui.org) (Agent to UI Protocol).
`lex-ag-ui` is a zero-server-change bridge for any plain
`lex-agent`-mounted A2A server (confirmed: loom's `cx_a2a.lex` and
`research_a2a.lex` are already AG-UI-streamable today, from any external
consumer, with no code changes needed here) — this doc is about the
*other* half: giving a human operator visibility into loom's own
multi-turn sprint-node agents (`build`, `qa`, …), which don't have an A2A
server sitting in front of them at all.

## What this is not

Genuine mid-generation streaming — AG-UI text/tool-call deltas arriving
as the model actually generates them — is **not achievable from
lex-loom alone**. Traced directly: `lex-llm/src/agent.lex`'s
`run_steps` eagerly drains the whole provider response, one full
`iter.to_list` per tool-calling round, *before* `run_loop` ever returns
anything. By the time `src/agent/runner.lex`'s `step()` sees an
`Iter[d.Step]` at all, every delta that iterator will ever produce has
already happened — there's no live moment left to stream. That's a real
blocker upstream in `lex-llm`, not something this repo can route around.

`lex-ag-ui/src/bridge.lex`'s own `from_llm_steps` is *also* not lazy
(it does its own `iter.to_list` drain, documented in its own header
comment) — but confirmed by reading both eagerly-draining functions
side by side, that second drain isn't where liveness is lost either; the
data was never incrementally available in the first place.

## What this is

A **replay burst**: a node's already-finished LLM turn, encoded as a
real AG-UI event sequence (`RUN_STARTED`, `TEXT_MESSAGE_START/CONTENT/
END`, `TOOL_CALL_*`, `RUN_FINISHED`) and served over SSE right after
that turn completes — real, structured, protocol-correct events, just
delivered as one burst instead of trickling in live. Weaker than "watch
it think," genuinely useful as "see what this node's turn actually
produced, structured the same way a live stream would have been."

## How it works

- **`src/agui_store.lex`** (new) — `persist_agui_events(db, run_id,
  sprint_id, agent_id, steps)` encodes a finished turn's `List[d.Step]`
  via `lex-ag-ui/src/bridge.lex::from_llm_steps` and writes one row to a
  new `node_agui_events` table, keyed by `run_id` — the same id
  `runner.lex`'s own `trace.record` calls already use to correlate one
  `step()` call, so nothing new to generate or thread through.
  `load_latest_agui_events(db, sprint_id)` reads the newest row for a
  sprint.
- **`src/agent/runner.lex`** — the LLM branch calls
  `agui_store.persist_agui_events` right after computing `steps` (the
  same list `record_usage`/`extract_answer` already consume — reading it
  a third time isn't a drain, `List` isn't a single-use iterator).
  Unconditional, same posture as the trace/usage writes already there —
  no new opt-in toggle.
- **`src/web/server.lex`** — a new `GET /api/sprint-agui/*id` route,
  registered via `router.route_stream` (lex-web's existing SSE
  primitive, previously unused anywhere in this file) instead of
  `route_effectful`. `serve_loom`'s `net.serve_fn` bridge now matches
  `router.dispatch_outcome`'s `DPlain`/`DStream` instead of calling the
  plain `router.dispatch`, mirroring `lex-web/examples/streaming_api.lex`'s
  own bridge exactly. Looks up the sprint's latest recorded turn and
  re-emits each stored event as its own SSE `data:` frame — a clean
  `{"error":"no agui events recorded yet for this sprint"}` frame if
  nothing's been recorded yet, never a hard failure.

This works uniformly across `exec_mode: "inline"` and `exec_mode:
"queue"` — a `worker.lex` process writes the same `node_agui_events`
row a `run_layer`-driven inline call would, so `server.lex`'s read side
doesn't need to know or care which mode produced it. That's *why* this
is DB-backed rather than an in-request observer callback threaded down
`run_sprint → run_phase → run_layer → invoke_node_for_layer →
invoke_node → invoke_node_attempt → runner.step` (the latter would also
be fundamentally blocked for `exec_mode: "queue"` sprints, where the
node executes in a completely separate OS process the web server never
touches).

## Deliberately out of scope

- **Real mid-generation streaming.** Needs `lex-llm/src/agent.lex`'s
  `run_steps` to stop eagerly draining `provider.chat` per round —
  upstream work, a different repo's decision.
- **Auth on the new route.** `src/web/server.lex` has zero auth on
  *any* route today — a pre-existing, broader gap, tracked separately
  (`lex-loom#190`), deliberately not folded into this feature.
- **`content_a2a.lex`'s own AG-UI readiness.** A related, smaller find
  during this work: the token-gated route built for `#187` only ever
  called `dispatch_request`, silently dropping `tasks/sendSubscribe`
  support `cx_a2a.lex`/`research_a2a.lex` get for free from plain
  `mount()` — fixed alongside this (see commit history), not part of
  the replay-burst feature itself.

## Verification

- `tests/test_agui_store.lex` — persist/load round-trip, unknown-sprint
  returns `None`, latest-row-wins ordering. No real LLM call needed — a
  hand-built `List[d.Step]` (matching a real `StepDelta(TextChunk)` →
  `StepDone` sequence) exercises the exact same code path.
- `demo/agui-replay-roundtrip.sh` — live, against the real production
  `src/web/server.lex::serve_loom` entry point (not a reimplementation):
  seeds a real replay row via the real `agui_store.persist_agui_events`,
  starts the real server, and confirms `GET /api/sprint-agui/<id>`
  returns real `RUN_STARTED`/`TEXT_MESSAGE_*`/`RUN_FINISHED` SSE frames
  with `content-type: text/event-stream`, plus the clean "no events yet"
  path for an unrecorded sprint. Run twice from a clean state, both
  green. Caught one real bug live on the first run: `agui_error_stream`
  and the replay handler were double-wrapping SSE frames (`data: data:
  {...}`) because `stream.event_stream` already wraps every item —
  fixed before this shipped.
