# Issue — run loom worker agents inside lex-os capsules (replace Docker isolation)

Status: Phase 0 wiring started 2026-08-03. Filed 2026-06-22.

## Motivation
loom worker agents (build, py_build, qa, py_qa, devops, docs, security, scribe,
demo) currently run unisolated in the loom process / host Docker container. There
is no enforced boundary on what a worker can read, write, or reach over the
network — only convention. `../lex-os` (latest pull: +`actuation.rs`,
`supervisor/skill.rs`) provides exactly the boundary we want, with the same
`Grant` declaration enforced both statically (Lex type-check) and at runtime
(supervisor / perimeter).

## What lex-os gives us
Three walls, one `Grant` declaration:
1. **Type-check wall** — `lex-os check --grant manifest.json program.lex` rejects
   a program statically if it calls effects (net/fs/exec) outside its grant.
2. **Perimeter wall** — Firecracker microVM + iptables enforce the `egress`
   allowlist at the kernel level. `--simulated` = in-process policy enforcement,
   no KVM, portable (this is our starting point).
3. **Narrowing wall** — a child grant can only narrow the parent's, never widen;
   logged as `NarrowingBlocked` in a hash-chained, tamper-proof audit trail.

Grant dimensions: `filesystem` (None|ReadOnly|ReadWrite), `network`
(None|Loopback|Allowlist|Full + `egress` host list), `exec` (None|Sandboxed|Full).
Budgets: `wall_clock_secs`, `max_commands`, `max_money_cents`, `max_api_calls`.

## Plan
- **Phase 0 (started): simulated.** Manifests live in `src/manifests.lex`
  (`manifest_json_for_kind`), not the originally-sketched `manifests/`
  directory — one JSON grant generated per role, verified wire-compatible
  with lex-os's real `Manifest::from_json`. The proc executor
  (`src/agent/runner.lex`) is wired, but not via `lex-os run --agent guest`
  as first sketched: that command drives its own LLM reasoning loop, which
  would replace loom's tuned per-role prompts rather than just sandbox them.
  Instead it routes through
  [`lex-os exec`](https://github.com/alpibrusl/lex-os#mediate-one-external-command-exec)
  (added for this), a smaller primitive built specifically for "run this
  exact external command, mediated" — the command construction stays
  byte-for-byte what `proc_step` already built, only the launcher changes.
  Gated behind `LEX_OS_ISOLATION` (opt-in, off by default) so unset behavior
  is unchanged. `qa` gets `filesystem: ReadOnly, exec: Sandboxed`; `build`
  gets `filesystem: ReadWrite, network: Allowlist, exec: Sandboxed` (see
  `manifest_json_for_kind` for the full per-role table — it's a superset of
  the sketch below, covering every `kind` `proc_cmd` can appear on, with an
  unmapped role defaulting to no exec authority rather than failing open).
  Not yet done: the LLM and A2A executors stay unmediated (only `proc_cmd`
  nodes route through lex-os today), and there's no live end-to-end test in
  loom's own CI (it doesn't install the `lex-os` binary yet) — only a
  dependency-free unit test on the grant-generation side
  (`tests/test_manifest_for_kind.lex`).
- **Phase 1 (Linux/CI/prod): real Firecracker.** `lex-os exec` itself already
  supports the real backend (same selection as `lex-os run`: real by
  default on a KVM host, `--simulated` an explicit opt-in) — it boots
  `lex-os-guest` in a one-shot mode and the command runs genuinely inside
  the microVM, not just behind a swapped-out policy check. What's still
  loom-side work: `lex_os_exec_step` (`runner.lex`) hardcodes `--simulated`
  today, and loom's own CI has no KVM runner to exercise the real path —
  dropping the flag and adding that coverage is what Phase 1 actually is.
  Docker for per-agent isolation goes away entirely; the loom service itself
  just needs `lex run src/main.lex`.

## Per-role grant sketch
| role      | fs        | net               | exec      | notes |
|-----------|-----------|-------------------|-----------|-------|
| build     | ReadWrite | Allowlist[litellm]| Sandboxed | writes code, calls model |
| py_build  | ReadWrite | Allowlist[litellm]| Sandboxed | same |
| qa        | ReadOnly  | Allowlist[litellm]| None      | reads + judges, no writes |
| py_qa     | ReadOnly  | Allowlist[litellm]| None      | same |
| scribe    | ReadWrite | None              | None      | writes digest, no net |
| pm        | ReadOnly  | Allowlist[litellm]| None      | produces PRD |
| architect | ReadOnly  | Allowlist[litellm]| None      | produces design |

## Verification
Reuse the deterministic proc-agent harness. Assert a `qa` worker given a write
attempt is denied at the grant boundary (audit shows the denial), and that
`build` cannot reach any host other than the litellm proxy.

## Cost
~1 week to author manifests + wire the proc executor. `--simulated` is no-op
overhead. Real Firecracker needs a KVM Linux host.
