# Agentic Company — conceptual design

Status as of 2026-07-06. Extends #53 (Company epic), #62 (lifecycle design), and
#82 (board layer) — all closed. This is the next layer: what a Company needs to
be an actual *business*, not just a loop that keeps building features. Written
after two live end-to-end runs (`dataforge`, a Gumroad-sold CLI; `linksnap`, a
hosted API) surfaced the same structural gap from two different angles.

---

## The core problem this document addresses

`dataforge` shipped: JSON/YAML/TOML conversion, schema validation, a Gumroad
license-key gate, `pyproject.toml` packaging — every feature the Strategist
queued, it built, QA'd, and shipped. `linksnap` shipped a working URL-shortener
API with a real `launch`-node boot. Both runs are proof the **build loop**
works end to end.

Neither product has a single real user. Nobody paid. No support ticket has
ever been read. The Strategist's every decision — `continue` / `revise` /
`add` / `stop` — was made by an LLM reading another LLM's QA verdict and
digest summary. The company never once received a signal from outside its own
sandbox. That is the difference between a software factory and a company, and
it is the one gap that matters most.

---

## Three loops, not one

A Company today is really one loop wearing three hats. Splitting it out makes
the missing piece visible:

| Loop | Question it answers | loom status |
|---|---|---|
| **Build** | Can we make it? | **Have it.** Sprint → Digest → Improve (C1–C6), dynamic extension, cross-sprint memory. Proven twice this session. |
| **Operate** | Is it working, for real people? | **Missing entirely** *(when written — v0 landed since: #84/#85; the v1 controller design is `operate-loop.md`, epic #118)*. No uptime signal, no usage signal, no support-message ingestion. Nothing external ever enters the system. |
| **Strategy** | What should we do next? | **Have a primitive version.** The Strategist (C8, #75) decides continue/revise/add/stop — but its only inputs are internal: mission text, shipped list, last QA verdict, digest summary, board notes. No revenue, no usage, no cost. |

The Strategist cannot make a real business decision because it is never given
a real business signal. Today "the mission is achieved" is judged entirely by
an LLM re-reading its own prior work.

---

## Layer inventory — what a Company needs, and what exists

Ordered roughly bottom-up, product → business:

1. **Product** (the build loop) — ✅ have it (C1–C6, dynamic DAGs #41).
2. **Distribution** — marketing/launch surface: landing copy, SEO, positioning.
   ⚠️ Roles are *speced but not built*: Brand Strategist (#14), Content Creator
   (#15), Copywriter (#16), SEO Specialist (#17) are all still pending in the
   role catalogue. A company today cannot get *anyone* to its product.
3. **Monetization** — payment processing, pricing, license/billing.
   ⚠️ `dataforge` proved the *pattern* (a license-key gate module, correctly
   fail-closed) but the actual money-moving integration (a real Gumroad
   product, a real Stripe account) has never been wired, and per the
   attestation-ladder philosophy (`roles.lex`), it should **never be
   autonomous** — this is the one place a human must always sign.
4. **Operate** — uptime, error rates, usage counts, support inbox.
   ❌ **Does not exist at all.** This is the primary gap this document exists
   to name. *(Update: v0 shipped — liveness #85, error-log scan, cost ledger
   #94, Strategist grounding #86. The full layer — sensing → incidents →
   gated actuation → effect verification — is designed in
   [`operate-loop.md`](operate-loop.md), epic #118, on the
   [`lex-ctl`](https://github.com/alpibrusl/lex-ctl) kernel.)*
5. **Strategy** — decide what to build/kill next.
   ⚠️ Exists (C8) but only sees internal signals. Needs augmenting with
   Operate-loop output.
6. **Board / human oversight** — advisory, non-blocking notes from a human.
   ✅ Have it (#82, this session). One real gap found in use: notes are
   one-shot-consumed on the *first* decision after being queued, even if
   their own stated condition ("once X ships, do Y") isn't true yet — a
   conditional note can be silently discarded before it ever applies.
7. **Portfolio** — one company, N concurrent product lines.
   ✅ Have it (C7, #78, `portfolio_tracks`).
8. **Cost / budget discipline** — is this company spending more than it could
   ever earn?
   ❌ **Does not exist.** Nothing in the Strategist's context today reflects
   LLM/infra spend. This session alone burned dozens of iterations across
   `dataforge` and `linksnap` for $0 combined revenue — a real company would
   have killed at least one of those lines on cost grounds alone.
9. **Lifecycle** (Ideation → Validation → Growth → Maintenance → Sunset) and
   **dormancy/resume** — ✅ have both (`company.lex` stage FSM, C10).
10. **Project coherence** (one real, inspectable codebase per company) —
    ✅ **fixed this session** (`sync_project_dir`, `extract_fenced.py` heading
    lookback) after `dataforge`'s extraction turned out to be scattered across
    incoherent scratch directories.

---

## What "done" looks like for the missing pieces

**Operate loop.** A new role (or a small set of them) whose job is to *read
the real world* on a schedule, independent of any sprint: poll a usage/error
metric, poll a support inbox, poll a payment ledger. Each read becomes a
grounded fact (like a QA verdict is a grounded fact today) that the Strategist
can cite. This needs its own effect surface (`net` calls to whatever the real
integration is — Stripe, a helpdesk, an analytics endpoint) and its own DB
table (real-world observations, timestamped, sourced) — not folded into
`traces`, which is sprint-internal.

**Strategist augmentation.** Extend `decide_next`'s prompt (`company_runner.lex`)
and the `IterCtx`/board-notes-style inputs with an "OPERATE SIGNALS" section —
revenue-to-date, active users, open support items, cumulative LLM spend — the
same way "BOARD NOTES" was added this session. The Strategist's rules
(`strategist_system_prompt`) need a new consideration: a shipped, QA-passed
feature nobody uses is not evidence to keep going.

**Cost ledger.** A running total of LLM API cost (and eventually infra cost)
per company, checked the same way `stop_when`/`wake_when` conditions are
checked today (C2's condition DSL already has the right shape — `accepted ge
N`, `iter ge N` — this just needs a `spend ge N` term and a company-level
running total to compare it against, likely fed by loom's own cost-tracking
if it has one, or a manual per-call estimate).

**Monetization, for real.** Wiring an actual Gumroad/Stripe product — a
`human <oracle>` gate, per the attestation ladder, since this is legal/money
territory. Not autonomous by design.

**Distribution roles.** Activate the four pending marketing roles (#14–#17) —
they're already speced in the task backlog, just never built.

**Heartbeat** *(landed since — HB1, #213)*. `src/scheduler.lex` +
`bin/loom-scheduler.sh`: a long-lived daemon that owns every company in
`$LOOM_WORKSPACE` — per tick it classifies each company from its own DB
(run / dormant / stopped / sunset / max_iterations, trail-recorded as
`scheduler_decision`), starts at most `MAX_RUNS_PER_TICK` runs through the
same `run_company` path a manual invocation uses, and gives every company it
did NOT run the between-run revenue/liveness monitor sweep so a dormant
company's `wake_when` has fresh signals to fire against. A company stopped by
`stop_when` is never resurrected autonomously — only a pending board note
runs it once more. All scheduler state lives in the company DBs, so
kill/restart is always safe. This closes "nothing ever wakes a dormant
company"; event-driven wakes are HB2 (#214), true concurrency HB3 (#215).

**Blocking human gates** *(landed since — GOV1, #221)*. `human <oracle>
blocking` (optional trailing `<N>h` timeout) parks the gate node and its
dependent subtree until the oracle resolves the attention item — independent
tracks continue in the same pass, and parked is not failure. Approve seals
the node from the human-attested artifact (no re-run, no duplicate item);
reject cancels the subtree with the board's reason ledgered (`node_cancelled`);
a declared timeout escalates once (`gate_escalated`) and stays parked — there
is no auto-approve path anywhere. A parked iteration finishes as `"parked"`,
the scheduler holds the company (`scheduler_decision: parked`) until every
gate item is resolved, then re-enters the SAME iteration; `board_report`
leads with a PARKED banner. Plain `human <oracle>` gates stay advisory —
existing manifests are unchanged.

**Reporting lines** *(landed since — ORG1, #216)*. `company.toml` gains an
`[org]` table (`role = "manager"`) that flattens through bootstrap into
`ORG_EDGES` and is validated at launch — a malformed spec, duplicate child,
cycle, or unknown leaf role REFUSES to start the company (never a
half-loaded org). Edges live in `relationships.lex` under the `org:` role
prefix with a derived decision-rights contract
(`reports_to`/`may_assign`/`reviews`/`escalates_to` — ORG2/ORG3 consume the
middle two). Wired in today: every casting trail-records whose authority it
ran under (`node_cast` with `authority`), the GOV1 gate-timeout escalation
walks the chain upward (`legal -> eng_manager -> founder`) before landing on
the oracle, and `board_report` renders the chart. A company with no `[org]`
is exactly what it was: flat, oracle-direct.

**Delegation** *(landed since — ORG2, #217)*. A role hands a TYPED subtask
to a direct report, under three hard rules. (1) *Structural gate*: writing
an assignment requires the ORG1 `may_assign` edge, checked against the DB
org chart at write time — never against anything the LLM said; refusals
land on the trail (`delegation_refused`). (2) *Closed vocabulary*: a task
is a `kind` from `delegation.known_kinds()` (`build_feature`, `write_tests`,
`write_docs`, `review_artifact`) rendered through that kind's fixed prompt
template — no free-form command synthesis. (3) *Normal execution*: an
accepted assignment materializes as an ordinary sprint node
(`company_runner.drain_assignments`, at the top of every iteration) — cast
from the pool under the delegator's recorded authority, gated, attested,
trail-recorded; the artifact lands back on the `assignments` row, and a
failed one is `returned` with the ORG1 escalation chain on the trail. The
`delegate` tool follows the runner's op-call pattern: its effect row is
`[net, io, proc]` (no sql), so an agent can only *request* — the request
file is flushed through the gated `offer` after the loop, which is where
authorization lives. Managing roles (org-chart parents) get the tool
injected automatically; leaf roles never see it.

**Manager roles** *(landed since — ORG3, #218)*. A manager's judgment enters
the system at exactly two auditable points. (1) *Review*: every `done`
assignment whose to_role has a manager is put in front of that manager as
an ordinary sprint node (cast, gated, trail-recorded); the manager's
"artifact" is a verdict — accept, or return-with-notes — parsed
mechanically, and an unparseable review changes nothing. (2) *Attestation*:
an accept is a positive attestation on the worker's pool agent, a return is
a bounce — manager judgment drives the SAME promotion/demotion ledger
mechanical outcomes already feed (a repeatedly-returned worker retires per
`cast.lex`'s existing ≤ −3 rule). Returns are bounded
(`delegation.max_rework_rounds()`): a returned assignment goes back through
the drain as a rework round carrying the manager's notes; past the cap it
is finally `returned` and escalates up the reporting lines. The manager
also reports upward: `manager_report` trail events aggregate its subtree,
and the Strategist's prompt consumes that summary section — raw artifacts
are reviewed by the manager, not re-read at the top. A flat company is
untouched: no manager, no review, `done` stays final.

**The CEO** *(landed since — ORG4, #219)*. Goal origination above the
Strategist, on the HB1 heartbeat (scheduler tick), not per-sprint. Whether
the CEO is even consulted is decided by a *mechanical* gate over grounded
signals — ≥ 2 consecutive failed iterations AND a non-growing
settlement-recorded revenue trend — so a healthy company never invokes it
(no proposal churn, no spend), with hysteresis on top (one proposal per
iteration index, never while one is pending). When consulted, the CEO —
an ordinary cast node, role `ceo` — must answer in EXACTLY one JSON
proposal object (`none` / `pivot` + new_goal / `sunset`); no prose
fallback for a mission change. A proposal is **advisory until approved**:
it parks before the board through the same attention queue as every other
human decision (oracle `board`, evidence artifact attached, RESOLVER_ID
recorded on resolve). An approved pivot revises `companies.goal` *and* the
resume-goal pointer — the Strategist executes the new mission from the
next iteration — and appends a `mission_ledger` row naming the proposal
and the approver (row 1 is always the founding mission, by the founder).
An approved sunset winds the company down; a rejection changes nothing but
the trail. Explicit non-goal, enforced by construction: the CEO has no
spend/payment authority anywhere in this path — it proposes, the board
disposes.

**Data-driven roster** *(landed since — ORG5, #220)*. The 26-role if-chain
in `roles.lex` is now a data list (`builtin_specs`) dispatched generically —
behavior-identical, proven by the whole suite plus a vocabulary-coverage
test. `[roles].packs` in `company.toml` is parsed and validated against a
closed pack registry (core / web / content / finance / governance /
research / security — a partition of the builtin vocabulary); an unknown
pack REFUSES the launch, and declared packs shape `castable_kinds`
(core + declared; no declaration keeps every builtin castable). Runtime
role creation is **bounded**: an agent may propose a new role (prompt +
tool profile + grant preset), but the tool profile must borrow an existing
role's tool budget, the grant preset must be WITHIN the company's grant
ceiling (`manifests.grant_within` over the real preset dims — installing
never widens, so an agent-authored role can never carry a grant its
company doesn't already hold), and the board must approve through the
same attention queue as every other human decision. The `role_defs` row is
the ledger: who proposed, what grants, who approved. Approved roles cast
through the same `cast.cast_node` path as builtins (`loom-dyn-<kind>`) —
no side channel.

**Budget authority** *(landed since — GOV2, #222)*. Budget stops being one
global kill switch: an envelope is *authority to spend up to X* (integer
cents, always), declared per scope — `total`, or `role:<kind>` — in
`[budget.envelopes]` (validated at launch, refuse-on-invalid) or by the
board's `budget_set_cmd` (RESOLVER_ID required; every change trailed with
its actor — no agent code path can raise its own cap). Enforcement is at
dispatch: an exhausted role envelope refuses that role's nodes (the
subtree stops; unrelated roles in the same phase continue) and an
exhausted `total` refuses to start the next iteration
(`stopped_by: "budget"`) — both escalate ONCE into the board's attention
queue with the ORG1 chain on the trail. Charges are atomic increments
using the cost ledger's own estimate, so utilization is the exact sum of
charges and can never go negative; 80% trails a `budget_warning` once and
the board report renders per-envelope utilization with WARNING/EXHAUSTED
flags. ORG3 managers see their reports' roles' remaining balances inline.
Refuse, don't downgrade: there is no overdraft anywhere in this path.

**The allocation loop** *(landed since — GOV3, #223)*. Revenue stops being
information-only: on the scheduler heartbeat, when the company has declared
envelopes AND a settlement-verified revenue reading, the finance function
(an ordinary cast node, role `finance`) is consulted and may PROPOSE the
next period's envelope allocation — strictly parsed JSON, every change a
valid scope with positive integer cents, and always carrying a
**falsifiable prediction** ("verified revenue ≥ X by iteration K", #118's
effect-contract discipline; an unfalsifiable proposal is refused).
Proposals are **board decisions**: they park in the attention queue with
evidence attached, envelopes change only via an APPROVED attention row,
and the applied caps run as the approving board member (GOV2's
`budget_envelope_set` trail names them). Rejection = current envelopes
stand, disposition ledgered. Once the predicted iteration is reached, the
applied allocation is **graded** hit/miss against the current verified
reading — trailed, stored on the `allocations` row — and the company's
allocation hit rate is part of the evidence the finance agent and the
board both see on the next proposal. The invariant stays absolute: loom
never moves real money; allocation governs internal spend authority only
(#89's human gate untouched).

**Board interface v2** *(landed since — GOV4, #224)*. Everything the
company owes the board already flowed through GOV1's attention queue —
blocking gates, budget escalations (GOV2), allocation proposals (GOV3),
strategy proposals (ORG4), role approvals (ORG5), and now operate
escalate-tier dossiers (queued from the heartbeat). GOV4 adds the
*surface*: every pending item classifies into a decision **type** derived
from its queue address, with its **age**; `loom board pending` /
`GET /api/board/pending/*company` list them; `board_report` **leads** with
the pending count and the oldest age, so a parked company is unmissable.
`board.decide` is the ONE authorized write — RESOLVER_ID required and
recorded, #165's registered-contact rule enforced, approve/reject/**defer**
(a deferral is a recorded act that leaves the item pending, age still
counting) — and the CLI command and the web API both call this exact
function, upgrading #204's "same check in both paths" from mirrored code
to literally one function. An already-resolved decision cannot be
re-decided; the decision history read from resolved rows plus deferral
trail events *is* the board minutes, append-only by construction.

**Event-driven wakes** *(landed since — HB2, #214)*. Real-world events stop
waiting for the next tick to be noticed. An append-only `company_events`
ledger (`src/events.lex`; named to avoid lex-trail's own `events` table)
records a **closed vocabulary** of kinds — board_note, operate_signal,
incident, support_item, research_request, content_request, webhook — with
unknown kinds *refused, never stored*. Writers: `add_board_note` itself
(the one ingestion point), operate sync bridges run from the scheduler's
monitor pass (an open incident and a *moved* revenue reading each event
exactly once, keyed on the underlying row), the three A2A skill servers
when configured with `LOOM_EVENTS_DB`/`LOOM_EVENTS_COMPANY`, and a
token-gated generic webhook `POST /api/events/:company_id`. The `wake_when`
grammar becomes a disjunction of atoms joined by ` or `, where an atom is
an existing grounded-ctx predicate **or a bare event kind** — so
`wake_when board_note or support_item` is manifest-declared wake policy,
and an event of an undeclared kind is recorded but wakes nothing (opt-in,
proven live: the non-opted company holds the same event and stays dormant).
The scheduler classifies a dormant company with an unconsumed declared-kind
event as `event_wake`, and between full ticks a cheap `EVENT_POLL_MS`
scan (default 2s) cuts the tick sleep short — a board note wakes a dormant
company in ~1s against a 60s tick in the demo. The runner's own dormancy
gate is event-aware too, and events are consumed only *after* the run
returns, each getting its one-shot `consumed_at`/`consumed_by` mark naming
the run that absorbed it — replaying the table is the wake history
(`loom events_cmd`). Events are **data, never instruction**: ledger rows
carry ids and indexes (a note's index, an item's id), never caller text,
and nothing from an event body is ever spliced into a prompt (#118 §2.7).

**True concurrency** *(landed since — HB3, #215)*. The last artificial
serialization points are gone. **Multi-worker**: the #197 refusal in
`run-company.sh` is lifted — loom is SQLite-only, where lex-jobs'
single-statement claim (`UPDATE ... WHERE id=(SELECT ...) RETURNING`) is
atomic under the database write lock, so two workers can never own the
same job (the race its README warns about is Postgres-specific; if a
Postgres path ever lands, re-gate). Loom-side: a claim error is now
treated as transient (back off one poll, keep serving — it used to
silently end the worker loop), and every execution is trail-recorded as
`worker_node_executed` with the worker's `WORKER_ID`, so "each node ran
exactly once, and by whom" is auditable from the trail. **Scheduler**:
a tick is now plan → run → monitor — classification and governance
heartbeats stay sequential, then the first `MAX_RUNS_PER_TICK`
run-classified companies fan out **concurrently** via `list.par_map`
(each company is its own SQLite file; nothing shared), making the cap a
true concurrency cap; everyone else gets the monitor sweep as before.
**Money under contention**: `budget.charge` and the cost ledger were
already single-statement relative UPDATEs — `tests/test_concurrency.lex`
proves it: 8 parallel writers land an exact total, 12 parallel claimers
on 6 jobs produce zero double-claims, and an envelope charged past its
cap by racing writers still trips `Exhausted` on the true integer-cents
sum. Live proof (`demo/hb3-concurrency-roundtrip.sh`): two real worker
processes complete a 6-node sprint with a 3/3 split and zero duplicated
executions; a 3-company workspace runs all three inside one tick, with
`run_cap_reached` enforced at cap 2 and no cross-company trail bleed.

---

## Smaller, already-diagnosed rough edges (not new, but worth closing)

Found live in `dataforge`/`linksnap` this session, not yet fixed:

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

Out of scope, by design not omission: any code that calls a real payment API
with real credentials autonomously. If that's ever wanted, it needs its own
explicit, separately-reviewed decision — not a natural extension of this
work.

---

## Recommended sequencing

1. **Operate loop v0** — a single, simple signal source (even something as
   basic as "does the launched server still respond, checked once between
   iterations" — reusing the existing `launch` node's live-check machinery)
   proves the wiring before reaching for a real Stripe/support integration.
2. **Strategist augmentation** — thread that v0 signal into `decide_next`'s
   prompt. This is the smallest change that makes the Strategist's decisions
   actually grounded in something outside its own sandbox.
3. **Cost ledger** — cheap to add (a running total + a condition-DSL term),
   high value (this session's actual token spend is the best available
   evidence it's needed).
4. **Distribution roles** — activate #14–#17; they're already speced.
5. **Real monetization wiring** — deliberately last, deliberately human-gated.
   Done (#89): see "Monetization boundary" above.
6. **Rough-edge cleanups** — low-risk, can land anytime, don't block the above.
