# Agentic Company — architecture and status

Status as of 2026-08-15, re-baselined after epic #212 (org structure,
heartbeat, board governance) closed. Extends #53 (Company epic), #62
(lifecycle design), #82 (board layer), #84/#118 (Operate loop), #177
(soft/os-aware agents), and #212 — all closed. The original July version of
this document named the gap between a software factory and a company; this
version records the architecture that closed it. For what remains, see the
post-#212 audit epic (#239).

---

## The core problem (as originally diagnosed — kept for context)

`dataforge` shipped: JSON/YAML/TOML conversion, schema validation, a Gumroad
license-key gate, `pyproject.toml` packaging — every feature the Strategist
queued, it built, QA'd, and shipped. `linksnap` shipped a working URL-shortener
API with a real `launch`-node boot. Both runs proved the **build loop** worked
end to end — and neither product had a single real user. The Strategist's
every decision was an LLM reading another LLM's QA verdict. The company never
once received a signal from outside its own sandbox. That was the difference
between a software factory and a company, and everything below exists to
close it.

---

## Three loops

| Loop | Question it answers | Status |
|---|---|---|
| **Build** | Can we make it? | ✅ Sprint → Digest → Improve (C1–C6), dynamic DAGs, cross-sprint memory, pool fitness. |
| **Operate** | Is it working, for real people? | ✅ v1 (#118, on the [`lex-ctl`](https://github.com/alpibrusl/lex-ctl) kernel): sensing → incidents → diagnosis → capability-gated actuation → effect verification, behind an auto-tier circuit breaker. Revenue readings can settle through lex-soft (#177/SA3) for independent re-verification. |
| **Strategy** | What should we do next? | ✅ Grounded: the Strategist reads operate signals, real-economics (revenue vs spend), manager reports (ORG3), budget utilization (GOV2); above it a CEO (ORG4) proposes pivots/sunset from grounded distress signals, board-approved with an append-only mission ledger. |

---

## Layer inventory — what a Company needs, and what exists

Ordered roughly bottom-up. Every layer's proof is a fully offline demo in
`demo/` plus unit tests; CI runs the suites.

1. **Product** (the build loop) — ✅ C1–C6, dynamic DAGs (#41).
   `orchestrator.lex`, `graph.lex`, `digest.lex`, `improver.lex`.
2. **Distribution** — ✅ shipped as real, token-gated capability servers:
   customer support triage (`server/cx_a2a.lex`), web research
   (`server/research_a2a.lex`, SA4), self-hosted content publishing
   (`server/content_a2a.lex`, #187), all discoverable on the lex-soft mesh
   (SA2). Content roles live in the `content` role pack (ORG5).
3. **Monetization** — ✅ *as a pattern*, permanently human-gated (#89): the
   company builds license-check code and a handoff checklist; a human holds
   the account and credentials, always. See "Monetization boundary" below.
4. **Operate** — ✅ v1 (#118): `sensing.lex`, `diagnosis.lex`, `effects.lex`,
   `actuation.lex`, `operate_ledger.lex`; escalate-tier dossiers flow to the
   board decision surface (GOV4).
5. **Strategy** — ✅ grounded (see table above). `company_runner.lex`
   (Strategist), `ceo.lex` + mission ledger (ORG4).
6. **Board / human oversight** — ✅ upgraded from advisory notes (#82) to a
   full decision surface: blocking `human <oracle>` gates that park a company
   (GOV1), and ONE typed queue of everything the company owes the board —
   gates, budget escalations, allocation proposals, strategy proposals, role
   approvals, operate dossiers — with `board.decide` as the single authorized
   write (RESOLVER_ID required + recorded, registered-contact enforcement
   #165, approve/reject/defer) and append-only minutes (GOV4). `board.lex`,
   `gates.lex`; CLI `board_pending/decide/minutes_cmd`, API
   `/api/board/*`.
7. **Org structure** — ✅ ORG1–5: reporting lines + escalation chains
   (`org.lex`), typed closed-vocabulary delegation with rework cycles
   (`delegation.lex`), manager review feeding attestations and Strategist
   reports (`manager.lex`), a CEO above the Strategist (`ceo.lex`), and a
   data-driven role roster with bounded, board-approved runtime role creation
   (`roles.lex`, `role_registry.lex` — grant-narrowed via `manifests.lex`
   presets, never exceeding the company's own ceiling).
8. **Cost / budget discipline** — ✅ GOV2/GOV3: per-role spend envelopes
   enforced at node dispatch (refuse, don't overdraft), 80% warnings,
   exhaustion escalations to the board; a finance role proposes envelope
   revisions from revenue, board-approved, with self-grading predictions
   (`budget.lex`, `allocation.lex`). ✅ Charges are REAL since #94:
   `pricing.lex` prices every recorded `llm_usage` reading per model
   (input/output split, milli-cent rates, local models honestly free);
   envelopes charge the priced delta of each node's own usage
   (`<sprint>#<node>` owners), the iteration ledger books the same, and
   the artifact-size estimate survives only as the fallback for providers
   that report no usage. Queue-mode workers pass the same budget wall as
   inline nodes (they used to bypass it entirely).
9. **Lifecycle + dormancy** — ✅ stage FSM (C10) plus a real heartbeat:
   a scheduler daemon owns every company in a workspace (HB1), external
   events wake dormant companies within seconds through an append-only
   `company_events` ledger with manifest-declared opt-in (HB2), and runs are
   truly concurrent — multi-worker queues and a parallel tick under a
   concurrency cap (HB3). `scheduler.lex`, `events.lex`, `worker.lex`.
10. **Portfolio** — ✅ have it (C7, `portfolio_tracks`), but the
    workspace-of-companies model (one DB per company under the scheduler,
    with per-company governance and HB3 concurrency) is strictly stronger and
    is the recommended way to run N product lines. Deprecation of the older
    track mechanism is tracked in #242.
11. **Project coherence** — ✅ (`sync_project_dir`).
12. **Isolation** — ✅ per-phase role-scoped grants (`manifests.lex`) shaped
    as lex-os manifests (OA1/OA2); tool-call mediation per role
    (`role_tools.lex`, `tool_grant.lex`).

## Implementation index (what landed where)

| Capability | Issues | PR | Modules | Offline demo |
|---|---|---|---|---|
| Heartbeat daemon | HB1 #213 | #226 | `scheduler.lex`, `bin/loom-scheduler.sh` | `hb1-scheduler-roundtrip.sh` |
| Event-driven wakes | HB2 #214 | #236 | `events.lex` (+ writers in `company.lex`, A2A servers, webhook) | `hb2-event-wake-roundtrip.sh` |
| True concurrency | HB3 #215 | #238 | `worker.lex`, `scheduler.lex` | `hb3-concurrency-roundtrip.sh` |
| Reporting lines | ORG1 #216 | #228 | `org.lex` | `org1-org-roundtrip.sh` |
| Typed delegation | ORG2 #217 | #229 | `delegation.lex` | `org2-delegation-roundtrip.sh` |
| Manager review | ORG3 #218 | #230 | `manager.lex` | `org3-manager-review-roundtrip.sh` |
| CEO + mission ledger | ORG4 #219 | #231 | `ceo.lex` | `org4-ceo-pivot-roundtrip.sh` |
| Data-driven roster | ORG5 #220 | #232 | `roles.lex`, `role_registry.lex` | `org5-role-registry-roundtrip.sh` |
| Blocking gates | GOV1 #221 | #227 | `gates.lex` | `gov1-blocking-gate-roundtrip.sh` |
| Budget envelopes | GOV2 #222 | #233 | `budget.lex` | `gov2-budget-envelope-roundtrip.sh` |
| Allocation loop | GOV3 #223 | #234 | `allocation.lex` | `gov3-allocation-roundtrip.sh` |
| Board surface v2 | GOV4 #224 | #235 | `board.lex` | `gov4-board-surface-roundtrip.sh` |

Design decisions worth knowing when reading the code:

- **One queue, one decide path.** Every governance producer writes to GOV1's
  attention queue at a per-company address (`<cid>/allocation`, `/ceo`,
  `/roles`, `/budget`, `/operate`, `/scheduler`); GOV4 types the queue by
  address and makes `board.decide` the only write — CLI and web API call
  literally the same function.
- **Events are data, never instruction.** The `company_events` ledger stores
  ids and indexes, never caller text; nothing from an event body reaches a
  prompt (#118 §2.7). Wake policy lives only in the manifest's `wake_when`
  (a disjunction of grounded predicates and event kinds).
- **Refuse, don't downgrade.** Unknown event kinds, unknown role packs,
  grant-exceeding role proposals, and exhausted budgets are refusals with
  loud escalation — never silent weakening.
- **Money is integer cents**, charged by single-statement relative UPDATEs —
  exact under contention (`tests/test_concurrency.lex`).
- **SQLite-only, one DB per company.** Cross-company concurrency shares
  nothing; multi-worker safety within one DB rests on SQLite's
  single-statement atomicity (re-gate if a Postgres path ever lands).

---

## Smaller, already-diagnosed rough edges (still open)

Found live in `dataforge`/`linksnap`, not yet fixed:

- **One-shot board notes fire too early.** A note queued with a conditional
  ask ("once core X ships, do Y") is consumed at the very next decision point
  — which may be *before* X ships — and is then gone. It should persist until
  a decision cites it, or until an explicit expiry.
- **Redundant re-verification after "add."** The Strategist's `add` decision
  intentionally doesn't change `current_goal` (so as not to interrupt
  in-progress work) — but this means the *same, already-passing* goal gets
  re-run and re-verified one extra iteration before the next `stop`/`revise`
  actually moves on. Minor cost, but avoidable.
- **Stale `running` iteration rows.** A process kill (session teardown, `kill`)
  leaves a `company_iterations` row permanently at `status='running'`.
  Harmless functionally (`resume_point` only reads the highest-idx row) but
  cosmetically wrong in the board report.
- **Backlog items never marked `done`.** `graduate_backlog` marks the *next*
  item `active` but never marks the *previous* one `done` once its goal is
  fully shipped — it just stays `active` forever, which is confusing in
  `board_report`'s backlog section even though it's functionally inert.

---

## Monetization boundary (#89)

`dataforge` built a real Gumroad license-key verification module (fail-closed,
cached, correct API shape) — but it was never wired to an actual Gumroad
product, because no real product/account exists. This is deliberate, not a
gap to close by giving the company real credentials.

**What the company automates:**
- Pricing tiers and unit-economics sketch (`finance` role) — grounded, flags
  every non-tracked-spend figure as an assumption.
- Landing/positioning copy (`copywriter`, `brand_strategist`).
- The license-check code itself (build/py_build) — this can and should be
  real, tested code; verifying a license key is a technical problem with a
  correct answer.
- A human-facing handoff checklist (`monetization_handoff` role) naming the
  exact manual steps: create the product, set the price, wire the webhook,
  point the already-built license-check module at the real product/API key.

**What a human must do — always, no exception:**
- Actually create the Gumroad/Stripe product and hold the account.
- Enter real credentials anywhere (the company never sees or handles them).
- Attest that a real product exists and is live before monetization is
  considered "shipped."

**How it's enforced, not just documented:** `monetization_handoff`'s gate
must be `human <oracle>` (e.g. `human founder`) — metaspec rejects the graph
outright if the Architect ever assigns it an autonomous gate (`spec judge`,
`spec compiles`, anything else), because a model must never self-certify
this milestone. A `human <oracle>` node is *attested* immediately (the
sprint can proceed) but stays *unsealed* — `sprint_status`'s `fully_sealed`
flag stays false — until a person actually resolves it:

```sh
# see everything awaiting a human, including the full handoff checklist text
lex run --allow-effects env,io,sql,fs_read,fs_write,vcs src/main.lex attention_list_cmd

# after actually creating the product and confirming it's live
# RESOLVER_ID is required and always recorded (lex-loom#165) — if the
# company has registered a relationships.lex contact for this oracle
# (`add_contact_cmd`/`add_pool_contact_cmd`), only that contact's id is
# authorized; an unconfigured oracle stays open to any RESOLVER_ID.
ATTENTION_ID=<id> VERDICT=approved REASON="created gumroad product, tested one purchase" RESOLVER_ID=<your-registered-contact-id> \
  lex run --allow-effects env,io,sql,fs_read,fs_write,time src/main.lex attention_resolve_cmd
```

Since GOV4, `attention_resolve_cmd` (and the web API) route through
`board.decide` — same identity rules, same append-only minutes.

Out of scope, by design not omission: any code that calls a real payment API
with real credentials autonomously. If that's ever wanted, it needs its own
explicit, separately-reviewed decision — not a natural extension of this
work.

---

## What's next

The post-#212 audit epic (#239) is nearly complete: the truth pass (#240),
CI demo coverage (#241), legacy consolidation (#242), and real
provider-token cost accounting (#94) have all landed. Remaining: E
(re-scoping the delivered epics). Beyond the audit, the live follow-ups
are deploy automation (#188), cx URL scoping (#194) — and the real
milestone all of this serves: running a company end-to-end for days under
the scheduler, governed purely through the board surface.
