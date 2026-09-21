# Grounded Lex guidelines for build agents

Lex is not in any model's training data, so build agents learn it from tools
(`lex_guidelines`, `lex_check`, `lex_run`). The failure mode is **stale guidance**:
hand-written API notes drift from the real toolchain and the agent dutifully
emits non-compiling code (this happened with `std.sql` — the old notes invented
`sql.str()`/`VStr`, which don't exist).

## The contract

Every `*.lex` file in this directory is a **worked, COMPILING example** that
`lex_guidelines` serves verbatim to the build agent (read at call time). Because
these are real source files, **CI `lex check`s them** (the `find src … | lex check`
step), so the guidance can **never drift from compiling code** — if an example
goes stale against a toolchain bump, CI goes red.

This makes the agent's awareness of the **language**, **lex tools**, and **lex
packages** self-correcting: the examples exercise real package APIs, and the
compiler is the source of truth.

## Adding awareness of a new package/topic

1. Write `mytopic_example.lex` here — a minimal but complete program using the
   real package API. Run `lex check` until it passes.
2. In `src/lex_skill.lex`, make `guide_mytopic()` `io.read` this file and append
   it (see `guide_sql`).
3. CI now guarantees it stays correct.

Prefer this over hand-typed API prose. For the canonical full language reference,
`lex agent-guidelines` emits the toolchain's 20 KB authoring contract; `lex docs
--for-agent` emits machine-readable package signatures — either can seed a new
example.
