# Soft-aware and os-aware loom agents

Status: design, epic filed. Written 2026-08-04, following the ecosystem
model in `lex-lang/docs/design/ecosystem-model.md` (loom = a company,
soft = interactions between companies, os = optional sandboxed runtime —
two peer axes plus one orthogonal one) and the Phase 0 lex-os wiring
already shipped (`docs/design/lex-os-isolation.md`).

## Motivation

Two axes of "awareness" loom's agents don't have yet:

1. **Soft-aware.** A company's outward-facing roles (Distribution, CX,
   monetization handoff, the Operate loop's external signals) already
   reach outside the company boundary today — via ad hoc HTTP calls
   (`[finance].revenue_url`, hand-rolled distribution integrations). Every
   one of those integrations is a bespoke, per-company, per-counterparty
   thing. lex-soft's mesh (identity, discovery, trust, evidence-gated
   settlement) is the generalized version of exactly that — but nothing
   in loom talks to it yet.
2. **Os-aware.** `LEX_OS_ISOLATION` (shipped) mediates exactly one
   executor — `proc_cmd`, the *least* consequential path (deterministic
   demo scripts). The LLM executor — real model calls with real tool
   access, where the actual blast radius lives — is completely unmediated
   by lex-os today, and isolation is decided deep inside `runner.lex`
   rather than something a company can declare policy about up front.

Neither gap is hypothetical: both are places loom already crosses a trust
boundary (org boundary for soft, tool-execution boundary for os) without
the machinery built for exactly that crossing.

## The border between loom and soft

loom owns everything *inside* one company: sprint graph, roles, Cast,
memory, the Operate loop's own signals. soft owns everything that
*crosses* an org boundary: identity, discovery, trust, evidence,
settlement. The border sits precisely where loom's company already
reaches outward — Distribution roles, monetization handoff, deploy/launch,
the Operate loop's external signals — and the wire format that already
bridges the two sides is A2A, which loom already speaks in both
directions (`src/agent/a2a.lex` outbound, `src/server/a2a.lex` inbound)
and soft speaks natively (`mesh`, `registry`, `external_agent.lex`).

**Naming collision to resolve early, cheaply:** both repos have an
`identity.lex`. loom's is internal agent-pool reputation (`did:lex`,
scoring within one company's Cast); soft's is verified cross-org identity.
Different scopes, same name — worth an explicit doc note (or a rename)
before this work makes the collision load-bearing.

## Why this design fits the existing shape

| Concern | Existing home |
|---|---|
| Cross-org discovery, trust, identity | **lex-soft** `mesh`/`registry`/`identity`/`federation` — unchanged, loom becomes a consumer |
| Cross-org messaging | **A2A** — loom already speaks it (`src/agent/a2a.lex`, `src/server/a2a.lex`); soft already speaks it (`external_agent.lex`) |
| Evidence-gated settlement | **lex-soft** `verdict`/`settlement`/`ledger` — replaces loom's ad hoc `revenue_url` polling |
| Per-role capability grant | **lex-os-manifest** `Grant` — `manifests.lex` already generates one per phase; just not consulted before role assignment |
| Mediated command execution | **lex-os exec** — already routes `proc_cmd`; needs the same treatment for the LLM executor's tool calls |
| Declarative company policy | **`company.toml`** `[policy]` — already exists for `max_iterations`/`budget_eur`; extend, don't replace |

## Non-negotiables

- **soft is the only path to another company.** No new bespoke
  per-counterparty integration gets added to loom once this lands — if a
  role needs to reach outside the company, it goes through soft's mesh.
- **A grant is declared before a role runs, not decided inline inside the
  executor.** `manifests.lex`'s per-phase `Grant` becomes something
  `cast.lex` can read before assigning a role, not just something
  `runner.lex`'s `proc_cmd` branch happens to consult.
- **Money and identity claims settle through soft's evidence-gated path,
  never a bare HTTP GET a company operator points at their own rail.**
  `revenue_url` stays as a fallback for operators without a soft node;
  it's superseded, not required to disappear on day one.
- **Every phase below has its own promotion criterion.** Don't build
  SA1–SA4 or OA1–OA3 and then turn them all on at once — each phase ships
  standalone value and is judged before the next starts.

## Plan — Track SA (soft-aware)

- **SA1 — `[soft]` in `company.toml` + resolve the `identity.lex` naming
  collision.** Schema only: mesh URL, org identity, which roles opt in.
  Parsed by `bin/bootstrap-company.sh`, no runtime behavior yet — this is
  the declarative surface the rest of the track builds on, the same way
  `[finance]`/`[policy]` already work. Cheap, low-risk, unblocks
  everything else.
  *Promotion criterion:* a company.toml with `[soft]` round-trips through
  bootstrap and the field is visible in `board_report`.
- **SA2 — register one outward-facing role in soft's mesh.** Pick the
  single lowest-risk candidate (monetization-handoff — already
  `human <oracle>`-gated, or CX — already real and tested) and register it
  via soft's `mesh.mount`-shaped API, discoverable and reachable over A2A
  from a real soft node.
  *Promotion criterion:* a second, independent soft node discovers and
  successfully A2A-messages the registered role end to end.
- **SA3 — evidence-gated settlement for one real money signal.** Route the
  Operate loop's revenue tracking through soft's `verdict`/`settlement`
  instead of polling `revenue_url` directly, for one company.
  *Promotion criterion:* a settlement event soft produced is the one
  `board_report` cites, and it survives an independent re-verification
  (soft's own evidence re-derivation).
- **SA4 — expand to the rest of Distribution.** Only after SA2/SA3 are
  proven: research, content publishing, and any future distribution role
  register the same way by default.

## Plan — Track OA (os-aware)

- **OA1 — `[policy]` grant declaration in `company.toml`.** Extend the
  existing `[policy]` table so a company can declare (or accept
  `manifest_json_for_kind`'s defaults for) per-role isolation up front;
  `cast.lex` reads it at role-assignment time. Additive only — no
  enforcement change, `LEX_OS_ISOLATION`'s existing behavior is untouched.
  *Promotion criterion:* `cast.lex` can report, for a given roster, which
  roles would run under which grant, without anything executing
  differently yet.
- **OA2 — mediate the LLM executor's tool calls, not just `proc_cmd`.**
  The consequential path: build/qa agents calling a real model with real
  tool access. Needs its own careful design (a separate doc section or
  follow-up design doc before implementation — this is the riskiest,
  highest-blast-radius piece of the whole epic, touching the tool-calling
  hot path every real sprint runs through).
  *Promotion criterion:* a QA-shaped grant denies a tool call it shouldn't
  have, end to end, with the LLM loop still completing the sprint via its
  remaining permitted tools — proven first under `--simulated`.
- **OA3 — drop the hardcoded `--simulated` in `lex_os_exec_step`,
  validate on real KVM.** Tracked as open since the Phase 0 PR
  (`docs/design/lex-os-isolation.md`); needs a KVM CI runner, which loom
  doesn't have yet.
  *Promotion criterion:* the same QA-deny/Build-allow proof from Phase 0,
  reproduced against lex-os's real Firecracker backend, not the
  simulated one.

## Verification

Each phase's promotion criterion above is the gate — no phase starts
before the previous one's criterion is met and recorded (a trail event or
a comment on the phase's issue is enough; this doesn't need new
infrastructure). SA and OA are independent tracks and can run in
parallel; nothing in one blocks the other.

## Cost

SA1/OA1 are schema-and-plumbing, cheap (~days each). SA2 needs a real
second soft node to test against — coordinate with whoever runs one.
OA2 is the one piece here worth treating as its own mini-design effort
before writing code, given the blast radius of getting tool-call mediation
wrong. Everything else is comparable in size to the Phase 0 lex-os work
already shipped.
