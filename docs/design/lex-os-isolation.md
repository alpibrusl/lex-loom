# Issue — run loom worker agents inside lex-os capsules (replace Docker isolation)

Status: open, design only. Filed 2026-06-22.

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
- **Phase 0 (now): simulated.** Write one manifest per role under
  `manifests/`. Wire the proc executor so a node's worker is spawned as
  `lex-os run --simulated --agent guest --manifest manifests/<role>.json`.
  Zero kernel overhead; gives us the grant declarations as ground truth and
  audit trails locally. `qa` gets `filesystem: ReadOnly, exec: None`; `build`
  gets `filesystem: ReadWrite, network: Allowlist [litellm host], exec: Sandboxed`.
- **Phase 1 (Linux/CI/prod): real Firecracker.** Same manifests, drop
  `--simulated`, requires `/dev/kvm`. Docker for per-agent isolation goes away
  entirely; the loom service itself just needs `lex run src/main.lex`.

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
