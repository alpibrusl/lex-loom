# OA2 — mediating the LLM executor's tool calls (design review)

Status: **reviewed, approved, and implemented** (`lex-loom#183`, part of
epic `lex-loom#177`, depends on OA1 `lex-loom#182`, done). Per #183's own
scope note, this was the riskiest, highest-blast-radius piece of the
epic — it touches the tool-calling hot path every real sprint runs
through — so this section was written up and reviewed *before*
implementation started, per the issue's own requirement. Implementation:
`src/tool_grant.lex` (the table + comparison logic), `src/agent/runner.lex`
(the filter, wired into the LLM branch; `lex_os_exec_step` switched to the
override-aware grant too), `tests/test_tool_grant.lex`,
`demo/oa2-tool-filter-roundtrip.sh` — all following the "Recommended
design" section below exactly as reviewed.

## Recap: what's mediated today, what isn't

Phase 0 (`docs/design/lex-os-isolation.md`, `lex-loom#176`) wired exactly one
executor: `proc_cmd` nodes. `src/agent/runner.lex`'s `lex_os_exec_step`
(triggered when `LEX_OS_ISOLATION` is set) shells out to the real `lex-os`
binary — `lex-os --output json exec --simulated --manifest <path> -- bash -c
<cmd>` — which mediates through `lex-os`'s `CommandRegistry`, gated on
exactly one registered command, `proc.exec` (`crates/lex-os/src/exec.rs`).
lex-os's own doc comment there is explicit about why: *"the grant either
allows arbitrary exec at all or it doesn't — there's no per-binary vocabulary
to gate on."* That's the right call for an opaque shell command.

The much more common path — an LLM agent (build/qa/etc.) calling a
**named, developer-authored tool** (`lex_check`, `run_code`,
`deploy_hetzner`, `publish_content`, …) — is today **completely
unmediated**. `runner.lex`'s LLM branch (`step()`, non-`proc_cmd`/`a2a_url`
case) builds every tool the role owns (`roles.tools_of_role`, driven by
`role_tools.tools_for`'s hardcoded role→tool-name table) and hands the full
list to `lex-llm`'s `AgentLoop` with `permission_spec: None` — no grant is
consulted at all. `manifests.lex`'s Grant/preset machinery (including OA1's
new `[policy.isolation]` overrides) is entirely unread on this path.

## Why "just reuse the proc_cmd pattern" doesn't fit as-is

The natural first instinct — shell out to `lex-os` per tool call, the same
way `lex_os_exec_step` does per node — runs into two real problems:

1. **lex-os has no named-command vocabulary to reuse.** `CommandRegistry`
   supports arbitrary named commands in principle (`Command { name,
   dimension, required_level, reversibility, money_cents, api_calls }`,
   `crates/lex-os-supervisor/src/command.rs`), but today exactly one is ever
   registered (`proc.exec`). Registering loom's ~11 tool names would be new
   lex-os-side surface — either hardcoded in the Rust binary (which then has
   to know about loom's tool vocabulary, a layering inversion) or via a new
   data-driven registry-construction path lex-os doesn't have yet. That's a
   second repo's worth of new design, not something to fold into a single
   PR silently.
2. **A tool call isn't a subprocess.** Every loom tool runs as a plain Lex
   effect *inside loom's own process* — an HTTP fetch, a `proc.run` shelling
   the `lex` CLI, a DB read. There is no separate sandboxed box for an
   individual tool call the way `lex-os exec --simulated` spins up (even
   simulated) for a shell command. Mediating "for real" — kernel-level,
   audited, budget-charged, one round-trip per call — would mean either (a)
   shelling out to the `lex-os` binary once per tool call (real added
   latency inside every LLM turn, for every sprint), or (b) linking
   `lex-os-supervisor` directly into loom's Lex runtime, which doesn't
   exist and is a much bigger integration than OA2's promotion criterion
   asks for.

Both are real future directions (see **Non-goals**, below) but neither is
proportionate to what OA2 actually needs to prove.

## What the promotion criterion actually requires

> A QA-shaped grant denies a tool call it shouldn't have, end to end, with
> the LLM loop still completing the sprint via its remaining permitted
> tools — proven first under `--simulated`.

Read literally: a role's tool list, filtered by its grant, must be
*strictly narrower* than its tool list unfiltered by grant — and the LLM
loop must degrade gracefully (not crash) when a tool it would otherwise
have is missing. It does **not** require kernel-level sandboxing of
individual tool calls, a lex-os audit-chain entry per call, or budget
charged in lex-os's ledger per call. Those are real properties worth
having eventually (flagged as non-goals below), but they're not what #183
asks OA2 to prove.

## Recommended design: a Lex-side, Grant-derived tool filter

Reuse the **exact same Grant** loom already computes today
(`manifests.manifest_json_for_kind_with_overrides`, OA1) as the sole
authority — no second, independently-derived policy — but evaluate it
**in loom's own Lex code**, the same way `lex-os-check` already evaluates
the identical grant statically, separately from the runtime supervisor
(per lex-os's own CLAUDE.md: *"Same grant as the runtime gates — one
declaration, two enforcement points"*). OA2 adds a third enforcement point
on the same declaration, not a competing one.

Concretely:

1. **A small, hand-maintained table** (mirroring `role_tools.lex`'s own
   style — explicit, auditable, never inferred) mapping each of the ~11
   tool names to the `(Dimension, Level)` it actually requires, based on
   what the tool's implementation does (`src/roles.lex`'s `make_*_tool`
   functions):

   | Tool | Dimension | Required level | Why |
   |---|---|---|---|
   | `lex_guidelines` | — | none | pure text lookup |
   | `lex_check` | Exec | Sandboxed | writes a file + shells `lex check` |
   | `lex_run` | Exec | Sandboxed | writes a file + shells `lex run` |
   | `py_check` | Exec | Sandboxed | writes a file + shells `py_compile` |
   | `run_code` | Exec | Sandboxed | writes + shells `python3` |
   | `security_scan` | Exec | Sandboxed | shells `bash -c` (grep-only, read paths) |
   | `run_server` | Exec | Sandboxed | launches a background subprocess |
   | `deploy_hetzner` | Exec | Full | rsync/ssh to a real external server |
   | `publish_content` | Network | Full | a real write to the live product's site |
   | `fetch_support_items` | Network | Allowlist | read-only GET |
   | `web_search` | Network | Allowlist | read-only GET (DuckDuckGo) |

   (First pass — worth a second look during implementation, but the
   directional split — exec-shelling tools need `Exec:Sandboxed`+, a real
   external write needs `Full`, read-only network needs only `Allowlist` —
   is the part that matters for review.)

2. **A pure comparison function**, `tool_allowed_under_grant(tool_name,
   grant) -> Bool`, using `Level`'s existing total order (`None < ReadOnly/
   Sandboxed/Loopback < ReadWrite/Allowlist < Full`, mirrored from
   `lex_types::trust::Level`) — no lex-os call, no subprocess, pure Lex.

3. **`runner.lex`'s LLM branch filters `def.tools` through this before
   constructing `llm_def`** — a tool the grant doesn't cover is never
   offered to the model at all (not just spec-denied at dispatch time).
   This is deliberately the simpler of `lex-llm`'s two already-built
   gating mechanisms (construction-time filtering vs. `permission_spec`'s
   dispatch-time `Spec` re-check) — construction-time filtering needs zero
   new `lex-llm` surface, and `dispatch_one`'s existing `t.find_by_name =>
   None` fallback already produces a graceful "unknown tool" turn result if
   the model somehow still names a filtered-out tool, which is exactly the
   "loop still completes via its remaining tools" behavior the promotion
   criterion asks for. `permission_spec` stays unset — no need for a second
   mechanism doing the same job.
4. **The grant driving the filter is `manifest_json_for_kind_with_overrides`**
   (OA1), not the unconditional `manifest_json_for_kind` — so this is also
   where OA1's `[policy.isolation]` overrides start actually changing
   behavior for the first time (OA1's own scope note: *"wiring an override
   into what actually gets mediated is OA2"*). `lex_os_exec_step` gets the
   same swap for consistency (today it still calls the unconditional
   function).

### Why this reading of "one declaration, two enforcement points" holds

This is *not* a second independent source of authority in the sense
lex-os's CLAUDE.md warns against (*"if you find yourself letting the agent
set its own limits, stop"*) — the agent never sets anything; the table in
step 1 is developer-authored and static, same posture as `role_tools.lex`.
The Grant itself still comes from exactly one place
(`manifest_json_for_kind_with_overrides`), same as every other consumer.
What's being added is a second *evaluator* of that one Grant — precisely
the pattern lex-os itself already uses (`lex-os-check`'s static wall vs.
`lex-os-supervisor`'s runtime gate, both reading the same `Grant`).

### Demonstrating the promotion criterion honestly

Worth flagging up front: the 5 built-in presets (`manifests.lex`) all grant
`Network: Allowlist` uniformly, and each role's own default preset is
already harmonious with its own `role_tools.lex` tool list (that's how the
presets were designed) — so under a role's *own default* preset, nothing
actually gets filtered; there's nothing to deny. The real demonstration
needs a **`[policy.isolation]` override** to a stricter preset — e.g.
override `build`'s Implementation (`Exec: Sandboxed`) down to `Demo`
(`Exec: None`), which denies `lex_check` (needs `Exec:Sandboxed`) while
`lex_guidelines` (needs nothing) survives, so the loop still completes with
its one remaining tool. This is a clean, honest demo, and a nice proof that
OA1 and OA2 actually compose — but it means the demo script exercises OA1's
override machinery too, not just OA2 in isolation. Flagging this now so
it's not a surprise later, not a hidden implementation trick.

## Non-goals (this phase)

- **Real kernel-level sandboxing of individual tool calls.** Tools run
  in-process; there's no per-call box to mediate at a `Perimeter` level.
  Giving each tool call a real isolated execution environment is a much
  larger change (arguably beyond OA3) than this phase's promotion
  criterion asks for.
- **lex-os audit-chain / budget-ledger entries per tool call.** The
  Grant-derived filter is a pure Lex authorization check, not a mediated
  request lex-os logs or charges against. `proc_cmd`'s existing per-node
  mediation (which *does* go through the real audited path) is unchanged.
  A future phase could register loom's tool vocabulary as real
  `CommandRegistry` entries and mediate per call/per node through the
  actual `Mediator` — closer in shape to the already-shipped
  `AgentAction::RunSkill`/`mediate_skill` precedent — but that's new
  lex-os-side surface, out of scope here.
- **`lex-llm`'s `permission_spec`/`Tool.precondition` machinery.** Left
  unused for now (see step 3) — construction-time filtering is simpler and
  sufficient; revisit only if a real need for per-turn dynamic
  allow/deny (not just per-node-static) shows up.
- **OA3** (real KVM/Firecracker validation) — proven under `--simulated`
  only, as `#183` itself scopes.

## Open questions for review — resolved

1. **Resolved: Lex-side Grant-derived filter, no new lex-os surface.**
   Reviewed and approved before implementation started. The heavier
   real-`CommandRegistry`-per-tool design remains a documented future
   direction (see Non-goals) if a real audited/budget-charged per-tool
   mediation is ever needed.
2. **Resolved: the table shipped as drafted** (`src/tool_grant.lex`'s
   `tool_required_dimension`) — no changes requested during review.
3. **Resolved: the promotion-criterion demo uses an OA1
   `[policy.isolation]` override**, exactly as proposed —
   `demo/oa2-tool-filter-roundtrip.sh` overrides `build` to `Demo`.
