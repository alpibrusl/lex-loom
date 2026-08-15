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
