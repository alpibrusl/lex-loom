# Native trace & replay (#7)

lex-loom sprints can be recorded with lex-lang's **native** trace store and then
inspected, replayed (with effect overrides), and diffed using the standard
`lex trace` / `lex replay` / `lex diff` tooling — turning post-mortem debugging
from "grep the SQLite trail" into a structured, tool-supported workflow.

This is **in addition to** the loom trail (the `traces` table + lex-trail log),
which remains the human-facing audit record. The native trace is the canonical
*executable* record: every effect and call under `run_sprint_cmd` is captured as
a `NodeId`-addressed tree.

## Recording a traced sprint

Use the wrapper — it runs the sprint under `lex run --trace` and links the
sprint to the native `run_id`:

```sh
SPRINT_ID=my-sprint REQUEST='Build …' MODEL=qwen3.8:27b-mlx bin/loom-traced.sh
```

Under the hood:

1. `lex run --trace --allow-effects … src/main.lex run_sprint_cmd`
   records the full effect/call tree to `~/.lex/store/traces/<run_id>` and prints
   `trace saved: <run_id>` to stderr.
2. The wrapper captures that `run_id` and calls `link_native_run`, which inserts
   a row into the `sprint_runs` table (`sprint_id → run_id`). A sprint can be
   traced more than once; the latest row by `created_at` is canonical.

## Inspecting

```sh
# Find the run_id for a sprint (latest):
SPRINT_ID=my-sprint lex run --allow-effects … src/main.lex sprint_run

# Print the full native trace tree as JSON:
lex trace <run_id>

# Each node: { node_id, kind, target, input, output, children, started_at, ended_at }
```

## Replaying with an override

`lex replay` re-executes the program but substitutes a recorded node's output
instead of performing the effect — so you can re-run a sprint as if a specific
node had produced different output, without calling the model/tool again.

```sh
# Replay the latest run for a sprint unchanged:
SPRINT_ID=my-sprint bin/loom-replay.sh

# Override one node's effect output (find NodeIds via `lex trace <run_id>`):
SPRINT_ID=my-sprint bin/loom-replay.sh \
  --override n_0.1.2='{"$variant":"Ok","args":["<substitute output>"]}'
```

The override JSON is the node's `output` shape as shown by `lex trace` — for a
`Result`-returning effect that is `{"$variant":"Ok","args":[…]}` /
`{"$variant":"Err","args":[…]}`.

## Diffing two runs

```sh
lex diff <run_a> <run_b>   # first NodeId where the two traces diverge
```

Useful for "why did this sprint go differently the second time?" — point it at
two `run_id`s from `sprint_runs` for the same (or related) sprints.

## Schema

`sprint_runs(id PK = run_id, sprint_id, run_id, created_at)` — added in
`src/migrate.lex`. `id = run_id` makes re-linking the same native run idempotent;
a genuine re-run produces a new `run_id` and therefore a new row.

## Commands added (`src/main.lex`)

- `link_native_run` — env `SPRINT_ID` + `RUN_ID` → insert into `sprint_runs`.
- `sprint_run` — env `SPRINT_ID` → print the latest `run_id` (blank if none).

Both are effect-checked whole-program, so invoke them with the full effect row
(`env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc`); the
wrapper scripts already do this.
