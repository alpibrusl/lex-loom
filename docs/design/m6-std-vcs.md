# M6.1 design — `std.vcs` effect + the lex-store blob it needs

Design for #5 / M6.1 (branch-per-sprint artifact store). Written after M6.0
(content-addressed artifacts in SQLite) landed. Grounded in the lex-lang
`lex-store`/`lex-vcs`/runtime source as of 0.9.10.

## The central finding (changes the issue's premise)

Issue #5 says "store each node artifact as a file on a branch; use the git blob
SHA." **lex-store is not a git-like generic object store.** Every public API is
`Stage`-oriented — a `Stage` is a *typed Lex AST* object, content-addressed by
`stage_id` (a hash of the AST), persisted as `<stage_id>.ast.json` under a
per-signature dir with delta encoding, metadata, lifecycle and Ed25519 sigs
(`store.rs: publish/get_ast/...`). There is **no `put_blob`/`get_blob`** for
opaque bytes.

Loom artifacts are arbitrary text (Python, JSON, prose) — not Lex ASTs. So they
cannot be stored in lex-store today. **M6.1 is therefore bigger than "wrap
lex-vcs as `std.vcs`": it first requires adding a generic content-addressed blob
object to lex-store.**

Second finding — the diff caveat: `lex diff`/`ast-diff` (`lex_vcs::compute_diff`)
operates on `FnDecl` ASTs. It gives nothing for opaque artifact text. So M6.2's
"AST-level cross-sprint diff" only delivers when the artifact *is* Lex code; for
Python/JSON artifacts, any cross-sprint diff is textual, not AST. Call this out
to whoever owns §III expectations.

Third finding — adding an effect is a known 3-touch pattern (no central
registry): type signatures + effect label in `crates/lex-types/src/builtins.rs`,
runtime dispatch arms in `crates/lex-runtime/src/handler.rs`, and the effect
name granted in `Policy.allow_effects` (effect names are open strings, gated at
`handler.rs:168`). A new `vcs` effect slots into this cleanly.

## Layered design

### Layer 1 — lex-store: generic blob object (Rust, lex-lang)
Add a content-addressed blob store alongside stages:
- `put_blob(&self, bytes: &[u8]) -> Result<String, StoreError>` — SHA-256 of the
  bytes is the id; write to an `objects/<sha>` CAS dir; idempotent.
- `get_blob(&self, sha: &str) -> Result<Vec<u8>, StoreError>`.
- Branch attachment reuses the existing namespace: `branch_head(name) ->
  BTreeMap<String,String>` already maps name→id. A sprint branch
  `loom/sprint-{id}` maps `node_id → blob_sha`. Use `create_branch(name, from)`
  to fork, and a new `branch_set(name, key, id)` (or extend the merge/commit
  path) to bind `node_id → sha` on it.

Smallest viable version: just `put_blob`/`get_blob` + `create_branch` +
`branch_set`/`branch_head`. Merge/diff of blob branches can come later.

### Layer 2 — `std.vcs` effect (Rust, lex-lang)
Builtins (signatures in `builtins.rs`, all carrying `EffectSet::singleton("vcs")`,
plus `fs_write`/`fs_read` where they touch the store root):
- `vcs.put_blob(content :: Str) -> [vcs, fs_write] Result[Str, Str]`  (returns sha)
- `vcs.get_blob(sha :: Str)     -> [vcs, fs_read]  Result[Str, Str]`
- `vcs.branch_create(name :: Str, from :: Str) -> [vcs, fs_write] Result[Unit, Str]`
- `vcs.branch_set(branch :: Str, key :: Str, sha :: Str) -> [vcs, fs_write] Result[Unit, Str]`
- `vcs.branch_get(branch :: Str, key :: Str) -> [vcs, fs_read] Result[Str, Str]`  (key→sha)
- (later) `vcs.ast_diff(stage_a :: Str, stage_b :: Str) -> [vcs] Str`  — Lex stages only

Dispatch arms in `handler.rs` open the store (`Store::open(default_store_root())`)
and call Layer 1. Gate on `vcs` like `sql`/`fs_write`. Concurrency note (#6): the
parallel layers mean concurrent `vcs.*` calls; the store must tolerate concurrent
writers (file CAS with atomic rename is fine for `put_blob`; `branch_set` needs a
lock or atomic head update).

### Layer 3 — loom transport (Lex, lex-loom)
- `transport.artifact_put`: when a vcs handle/flag is present, `vcs.put_blob` the
  content, `vcs.branch_set("loom/sprint-{id}", node_id, sha)`, return the sha.
  Fall back to the M6.0 SQLite path (already content-addressed by the same SHA!)
  when vcs is unavailable — so the SHA is identical across both backends.
- `transport.artifact_get`: try `vcs.get_blob`, fall back to SQLite.
- `diff.lex` (M6.2): add an artifact-diff entry point that calls `vcs.ast_diff`
  for Lex artifacts; keep the existing graph-field diff as the offline default.

Because M6.0 already keys SQLite artifacts by `crypto.sha256_str(content)`, the
SHA is the *same* whether stored in SQLite or the blob CAS — the two backends are
interchangeable by id, which makes the fallback seamless.

## Phasing
- **M6.1a** — lex-store `put_blob`/`get_blob` + `branch_create`/`branch_set`/
  `branch_get` (+ Rust tests). Pure lex-lang; no loom change yet.
- **M6.1b** — `std.vcs` builtins + handler dispatch + policy; a tiny `.lex`
  round-trip test (put→branch_set→branch_get→get).
- **M6.1c** — loom `transport` writes/reads via vcs with SQLite fallback;
  verify with the proc-agent harness that artifacts land on `loom/sprint-{id}`.
- **M6.2** — `vcs.ast_diff` + `diff.lex` wiring (Lex artifacts only).

## Effort / risk
- Spans three layers across two repos; M6.1a (Rust store) is the critical path
  and the riskiest (touches the store's on-disk layout and branch semantics).
- The ast-diff caveat means the headline §III "cross-sprint AST diff" payoff is
  partial unless loom emits Lex artifacts.
- Concurrent `branch_set` under #6 parallelism needs a real concurrency story in
  the store.

## Honest recommendation
M6.0 already delivers *true content-addressing + dedup* for artifacts — the
practical core of "content-hash artifacts." The remaining M6.1/M6.2 value is
**branch-per-sprint organization** and **cross-sprint diff**, and the latter is
caveated (AST diff only for Lex code). Given the cost (a store-level blob
feature + a new language effect), recommend confirming the concrete consumer
need before building Layer 1: who diffs sprint branches, and are the artifacts
Lex? If the answer is "operators want to browse/compare sprint outputs," a
cheaper alternative is a read-only export (artifacts → files under
`loom/sprint-{id}/` on disk) without the full lex-store object integration.
Build M6.1 only if branch-native storage + store-backed audit is genuinely
required over the existing content-addressed SQLite.
