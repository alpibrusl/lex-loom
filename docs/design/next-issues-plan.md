# Implementation plans — #7 (trace/replay) and #5 (M6: lex-vcs artifacts)

Status as of 2026-06-16. Written after #6 (parallel layers) and #8 (sprint_status CLI)
landed. No code committed for these two yet — this is the design.

---

## Issue #7 — hook the trail into native trace/replay

### Current state
- `loom_trail.lex` is a complete lex-trail wrapper: SHA-256 content-addressed,
  parent-pointer chain, helpers for the full lifecycle
  (`sprint_started`, `phase_advanced`, `graph_validated`, `graph_rejected`,
  `node_started`, `node_accepted`, `node_denied`, `phase_bounced`,
  `digest_produced`, `sprint_complete`).
- `orchestrator.lex` only wires **3** of them: `sprint_started` (L405),
  `graph_validated` (L429), `sprint_complete` (L516). All per-node events go
  only to the lex-soft `traces` table via `tr.trail`, never to lex-trail.
- The per-sprint lex-trail DB is `<sprint_id>-trail.db` (the `*-trail.db` files
  in the repo root). It has `events` + `attestations` tables.
- lex-trail's `replay.lex` provides `replay.task` (LIKE search) and
  `replay.walk_chain` (walk parent pointers) — **not** override-re-execution.

### The work splits in two

**Slice A — per-node trail wiring (tractable, ships independently).**
Emit the already-defined per-node events from the orchestrator so the lex-trail
log becomes the authoritative per-node record, matching `loom_trail.lex`'s stated
design ("traces is a secondary index; lex-trail is authoritative").

Files:
- `orchestrator.lex` — thread the `tlog.Log` (already opened in `run_sprint`)
  down through `run_phase` → `run_layer` → `invoke_node_for_layer` →
  `invoke_node`. At each node decision point, append the matching event
  (`node_started`, then `node_accepted` | `node_denied`). Also wire
  `phase_advanced`/`phase_bounced` in `run_qa_with_bounce` and the phase loop,
  and `digest_produced` from `digest.lex`.
- `digest.lex` — emit `digest_produced` after tightened specs are stored.

**Parent-chain under concurrency (the real design point, caused by #6).**
`run_layer` now runs nodes via `list.par_map`. The current chain threads the
parent by reading `ltrail.latest_id(log)` (the log head) before each append —
that races under parallelism (N workers read the same head, or interleave).
Design: capture the layer's entry event id **once** before the par_map, and have
every node in the layer append with that fixed parent. The chain then fans out
cleanly (layer-entry → {nodeA, nodeB} → …). `walk_chain` walks child→parent, so
a fan-out is still fully walkable from any leaf. After the layer barrier, append
a synthetic `layer_sealed` event whose parent is the layer-entry id; that becomes
the next layer's entry parent. This keeps a connected DAG without a linear-order
race. No change to `NodeOutcome` shape needed (parent is passed in, not returned).

Verification: reuse the deterministic proc-agent diamond harness from #6. After a
run, assert the trail DB contains `node_started`/`node_accepted` for all four
nodes and that `walk_chain` from `sprint_complete` reaches `sprint_started`
through the B/C fan-out. No LLM required.

**Slice B — native `lex replay <run_id> --override` (research-heavy, defer).**
The headline feature. Blockers/unknowns:
- lex-trail does not do override-re-execution; this is a lex-lang-native
  trace-store feature (`lex trace`/`lex replay --override NODE=JSON` exist as CLI
  commands).
- It's unclear how `lex run` populates the native trace store — no obvious
  `--trace`/`--record` flag on `lex run`. Need to read `crates/lex-cli` run/replay
  to learn how a run_id is produced and how NodeIds map to call sites.
- For `--override node_id=<json>` to re-run a sprint node, `invoke_node` calls
  must correspond to addressable NodeIds in the native trace. That likely means
  the sprint must be *run under* the native tracer, and a `sprint_id → run_id`
  mapping persisted (new column on the sprint record / a row in `traces`).
- Recommend a spike: instrument a trivial 2-node lex program, run it, and see
  whether `lex trace <run_id>` shows per-call nodes and whether `lex replay
  --override` can substitute one. Decide feasibility before committing.

### Recommended order
Ship Slice A as its own PR (closes the bulk of #7's "every node is a traceable
event"). Keep #7 open with a scoped follow-up for Slice B after the spike.

---

## Issue #5 — M6: artifacts via lex-vcs (content-hash, branch per sprint)

### Current state
- `transport.artifact_put` (L53) stores blobs in the `artifacts` SQLite table
  with a **random** hash: `crypto.random_str_hex(16)` — not content-addressed.
  `artifact_get` (L63) reads by that hash.
- `diff.lex` diffs `SprintGraph` nodes/edges by field comparison
  (`NodeDiff`/`EdgeDiff`/`GraphDiff`, `nodes_to_rerun`) — not artifact content.

### Hard blocker discovered
**lex-vcs is not callable from Lex.** There is no `lex-vcs` package in
`~/.lex/packages` and no `std.vcs`/`std.store` module. lex-vcs is a Rust crate in
lex-lang exposed only through the `lex` CLI (`lex branch`, `lex publish
--branch`, `lex diff`, `lex ast-diff`, `lex store-merge`).

Note (correction): an in-language content hash **is** available —
`crypto.sha256_str` is a pure `std.crypto` op (it's what lex-trail's `event.lex`
uses for event ids). So content-addressing artifacts needs no lex-lang change;
only the branch-per-sprint store does.

So M6 needs one of three foundations, in increasing order of cleanliness/effort:

1. **proc shim (no lex-lang change).** `transport.artifact_put` shells out via
   `proc.spawn` to `lex branch`/`publish` to write the artifact to branch
   `loom/sprint-{id}` and parse the returned blob SHA; `artifact_get` reads it
   back. Fastest, but brittle (CLI parsing, per-call subprocess cost, and the
   parallel layers from #6 mean concurrent `lex` invocations against the same
   store — needs the store to tolerate concurrent writers or a mutex).
2. **content-address in SQLite (lex-loom only).** Switch `artifact_put` from
   `crypto.random_str_hex(16)` to `crypto.sha256_str(content)` and key the
   `artifacts` table by that SHA (dedup via INSERT OR IGNORE, stable ids) —
   delivers "true content-addressing" + cross-run dedup **without** lex-vcs and
   **without** a lex-lang change. Branch-per-sprint + `lex diff` come later.
   This is the best *first slice* of M6: high value, low risk, no CLI shelling.
3. **`std.vcs`/`std.store` effect module (larger lex-lang change).** Expose
   lex-vcs operations (open store, put blob, branch, diff) as a first-class Lex
   effect. Cleanest end state; biggest upfront cost. This is what fully realizes
   §III/§4 (branch per sprint, AST-level cross-sprint diff via `lex diff`).

### Proposed phasing for #5
- **M6.0** — option 2: switch `artifact_put` to `crypto.sha256_str` content
  addressing in SQLite, keep `artifact_get` by SHA. Update `graph.lex`'s "once
  content-addressing lands" comment. lex-loom only, verifiable offline, shippable.
- **M6.1** — decide between proc shim (1) and std module (3) for the lex-vcs
  branch-per-sprint store. Recommend (3) if we're willing to touch lex-lang,
  since (1)'s concurrent-CLI-writer problem fights the #6 parallelism.
- **M6.2** — rewire `diff.lex` to call `lex diff`/`ast-diff` between
  `loom/sprint-{a}` and `loom/sprint-{b}` for artifact-level (AST) diffing,
  keeping the existing graph-field diff as the offline fallback.
- Keep the SQLite path as the offline/single-process fallback throughout
  (the issue requires it).

### Risk summary
- Both deepest slices (#7 Slice B, #5 M6.1/M6.2) require lex-lang work, not just
  lex-loom. Scope those as cross-repo.
- #6's parallelism interacts with both: trail parent-chaining (handled in #7
  Slice A) and concurrent store writers (a constraint on #5 M6.1).

### Recommended global sequence
1. #7 Slice A (per-node trail wiring + concurrency-safe chain) — lex-loom only.
2. #5 M6.0 (`crypto.sha256_str` content-addressed SQLite) — lex-loom only.
3. Spike #7 Slice B (native replay feasibility).
4. #5 M6.1/M6.2 (lex-vcs store + `lex diff`) — the milestone proper.
