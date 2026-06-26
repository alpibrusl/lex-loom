# Dev↔QA loop + conversation memory (done) and what's next

Status: implemented 2026-06-22. All changes in `src/orchestrator.lex` and
`src/agent/runner.lex`; verified by running sprints against local
qwen3-coder:30b (no Docker, no lex-os).

## What shipped

### 1. The QA→Implementation bounce loop now actually fires (bug fix)
`run_qa_with_bounce` computed `qa_passed` as "is *any* outcome attested." Because
`run_phase` runs the whole graph (the phase arg is only a label), a passing
build/pm node masked a denied qa node → `qa_passed=true` while the sprint failed,
so the loop never engaged (`phase_bounced=0`). Fixed to `qa_passed :=
qa_result.success`. Same task that FAILED before now SUCCEEDS.

### 2. Loop limits raised
- `max_node_retries()` 1 → 3 (within-node repair attempts)
- `max_qa_bounces()` 2 → 4 (QA↔Implementation round-trips)

### 3. Conversation memory across bounces
Before: on a bounce the prior code was flattened into a single `UserMsg`
(`prior_code + "\n\nQA feedback: …"`) — the model saw it as pasted text, not its
own attempt. Now the orchestrator emits a **bounce envelope**
`{"__bounce__":true,"task","prior_code","qa_feedback"}` and
`runner.conv_from_msg` (build kind only) rebuilds it into proper roles:
`[UserMsg(task), AssistantMsg(prior_code), UserMsg(critique)]`. The model edits
its own previous code with the QA critique as the next turn — true iterative
refinement, which materially helps local models on Lex.

No lex-lang change; uses the existing `msg_json` artifact channel, so no deep
threading through `run_phase`/`run_layer`/`invoke_node`.

## Known limitations / follow-ups

- **Whole-graph re-run on bounce.** When the architect's graph already contains
  qa/demo nodes, `qa_demo_graph := sprint_graph`, so a bounce re-runs the ENTIRE
  graph (pm, architect, build, qa, demo) rather than just build→qa. Wasteful, not
  incorrect. Fix: scope the bounce to the Implementation+QA sub-graph. Medium effort.
- **Tool-call trajectory not preserved.** The build agent re-fetches
  `lex_guidelines` and re-discovers the same `lex_check` compiler errors each
  bounce, because lex-llm `Message`/`ToolCall` have no JSON serializer — we
  reconstruct the conversation from artifacts (code) but not the full step log.
  True resume needs serialization in lex-llm itself. Larger, cross-repo.
- **QA feedback is QA's prose verdict**, not the raw compiler error. The build
  agent re-runs `lex_check` itself so it recovers, but feeding the exact error
  into the critique would tighten the loop further. Small effort.

## First real parallel benchmark — portfolio-s1 (both languages, 2026-06-22)

Ran portfolio-sprint-1 (`target: both`) on local qwen3-coder:30b, Docker-free,
300-call budget. Result: **sprint FAILED**, but the failure is informative.

| Stage | Lex | Python |
|-------|-----|--------|
| build gate | ✅ accepted — 716 chars of real fenced Lex (`import "std.net"`, `type Request = {…}`) | ✅ accepted — but only a 636-char **markdown design plan**, no actual `.py` |
| QA | retried 3× (cut off when sprint hit max bounces) | ❌ FAIL ("verdict is 'FAIL', expected 'PASS'") — correctly caught the non-code |

**Key finding — the Lex tooling produced *more rigorous* output than Python.**
Both nodes hit `[max_steps reached]`, but the Lex build still emitted compilable
code because the `lex_check` tool loop + guidelines force concrete file-writing.
The Python build node has **no equivalent compile/run gate**, so a prose plan
("Let's start with the Python implementation:") slipped past the build gate and
was only caught at py_qa. So the headline isn't "Lex lost" — it's "qwen3-coder
can write passing Lex (a language it never trained on), and Python's weaker build
gate let junk through."

**Whole-graph-rerun confirmed costly.** Of 41 node retries, **23 were the PM
node** — because every QA bounce re-runs the entire graph (pm→architect→build→
py_build→qa→py_qa), not just build→qa. This both wastes budget and inflates
unrelated nodes' retries. The "scope the bounce" follow-up is now the top fix.

Conversation-memory bounce envelopes fired (3 created), so that path is live.

### Next-step priorities revised by this data
1. **Add a real Python build gate** (`py_compile` / `python -c` / file-exists),
   mirroring `lex_check`. The single biggest correctness gap — Python currently
   has no compile wall, so the comparison is apples-to-oranges.
2. **Scope the QA bounce to the Implementation+QA sub-graph** (stop re-running
   pm/architect). Was already a follow-up; the 23 wasted PM retries make it urgent.
3. **Raise per-node step budget** or split build into smaller nodes — both
   builders hit `[max_steps reached]` on a 3-page site.

## Python build gate added + re-benchmark (portfolio-s1b, 2026-06-23)

Added `py_check` (lex_skill.lex), symmetric with `lex_check`: writes the agent's
code and runs `python3 -m py_compile`, repairing until ok. Wired into `py_build`
(was `tools: []`), strengthened its prompt ("a prose plan is a failure"), and
gave Python its own work dir (`/tmp/loom-py-work`) so parallel Lex/Python builds
never clobber each other (runner.work_dir_for / is_build_kind).

Re-ran portfolio-sprint-1 (`both`). The comparison is now **fair** — both
languages compile — and the result **flipped** from the first run:

| | Lex | Python |
|---|---|---|
| build | ✅ real fenced Lex, every attempt | ✅ **real Python now** (was a prose plan) |
| QA | ❌ FAIL every bounce (compiles via lex_check, fails QA's `lex_run`) | ✅ **PASS** — real Flask server, "Running on http://0.0.0.0:8080", exit 0 |

So with the gate fixed, the local model (qwen3-coder:30b) takes a 3-page HTTP
site **end-to-end in Python** but, for Lex, produces code that type-checks yet
doesn't satisfy QA's runtime check. The sprint still FAILED overall because both
QA nodes must pass in the same bounce and Lex QA never did (hit max 4 bounces).
Retry load also rebalanced onto the builders (build 10, py_build 9) instead of
the PM node — healthy.

**This is the real "how far can local models go with Lex" signal:** the bottleneck
is now Lex HTTP/`std.net` codegen + the Lex QA `lex_run` loop, NOT the build gate
or Python. Next work should target that, plus the still-open whole-graph-rerun.

## Build-compile gate + the quadratic-JSON-parser bug it surfaced (2026-06-23)

Debugged why Lex QA fails where Python passes. Replayed the QA tools on a real
agent-generated artifact: `server.lex` compiled fine, but `test.lex` didn't even
parse (agent wrote `let x =` not `:=`, `else if`, missing `std.list` import,
`fn ... = expr`). Fixing only the syntax → `lex check` ok and `run_all` returns 0.
**So it's the code, not the QA agent — QA was correctly failing a broken test
file that the BUILD node had wrongly accepted.**

Fix: **build-compile gate** (`runner.verify_build_compiles`) — before a build
node is accepted, compile EVERY file it wrote (`lex check` / `py_compile`), and
fail if output is prose with no source. Denied builds retry with the compiler
error fed back. Wired into orchestrator's accept path. Proven firing
(`build does not compile → compile-fail` retries in the trail).

### Two quadratic-JSON blowups this surfaced (VM 10M-step `par_map` panics)
lex-schema's `json_value` parser is O(n²) (char_at scan). Richer build output +
more iterations pushed two call sites over the 10M-step limit:
1. **My bounce envelope** used JSON → switched to a linear delimiter format
   (`<<<LOOM_BOUNCE>>>…<<<LOOM_SEP>>>…`), parsed with `str.split`. Fixed.
2. **`gates.evaluate("spec json-verdict-pass", qa_output)`** ran `jv.parse` on the
   QA agent's output, which embeds large `lex_check`/`lex_run` tool results →
   replaced with a linear `extract_verdict` (`str.split` on `"verdict"`). Fixed.

**Root cause is lex-schema (quadratic parser); these are loom-side mitigations.**
Proper fix = make lex-schema's parser linear (cross-repo follow-up). Until then,
avoid `jv.parse` on large/agent-produced strings in hot paths.

## Cross-sprint memory (separate idea — NOT this change)
`runner.step` already loads `mem.load_state`/`mem.recall_all` into the system
prompt but never writes them. Persisting per-agent lessons (e.g. "Lex http
handler signature is X") would make future sprints start smarter. This overlaps
with the existing digest→improver loop (which already tightens specs and improves
agents between sprints), so it's complementary, not urgent. File as its own issue.
