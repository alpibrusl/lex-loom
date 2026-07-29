# Operate loop v1 — the agentic control surface

Status as of 2026-07-29. Epic: #118. Extends #84 (Operate v0: liveness #85,
error-log scan, cost ledger #94, Strategist grounding #86) and fills the
layer-4 gap named in `agentic-company.md`. Lex-native port of the source
design *"The Agentic Control Surface"* (full original embedded in #118); the
original's Python stack section is superseded by the mapping in § 6 here.

The shared mechanism kernel lives in
[`lex-ctl`](https://github.com/alpibrusl/lex-ctl) (#126); this document is
the authoritative statement of how loom composes it into a controller.

---

## 1. Thesis

A dashboard is a cached, lossy projection of a database, with the projection
chosen in advance by someone who will not be present at read time. Both
constraints it exists to serve — expensive human attention, slow human
querying — disappear when the reader is an agent.

The replacement is not "monitoring with an LLM bolted on." It is a
**controller**: a closed loop in which every action carries a falsifiable
prediction with a deadline, and the sensing layer is what falsifies it.

> If a human would still read it faster than the agent can query the source,
> it is a dashboard.
> If an action can be taken without a checkable prediction attached, it is
> not a controller.

Operate v0 gave loom its first outside signals; v0's Strategist reads them as
prose. v1 closes the loop: signals open incidents, incidents propose actions,
actions carry effect contracts, a verifier falsifies them, and the measured
record — not anyone's confidence — decides how much autonomy each action
class gets.

### What this is not

| Not this | Because |
|---|---|
| Alert → LLM → runbook lookup | Frozen judgment moved from a threshold into a prompt |
| Agent with shell access and a system prompt | Authority must be structural, not instructional |
| Chat interface over metrics | The human read path is a *verification* surface, not a query surface |
| Anomaly detection with auto-remediation | Remediation without effect verification is an oscillator |

---

## 2. Architecture

```
   ┌──────────────┐  residuals   ┌───────────────┐
   │  SENSING     ├─────────────▶│  INCIDENT     │◀──── evidence (budgeted,
   │  (baselines) │              │  OBJECT       │       closed read-tool set)
   └──────▲───────┘              └───────┬───────┘
          │                              │ proposed action
          │ observed effect              ▼
          │                      ┌───────────────┐
          │                      │ CAPABILITY    │  reversibility × blast × dwell
          │                      │ GATE          │  → auto | propose | escalate
          │                      └───────┬───────┘
          │                              │
   ┌──────┴───────┐   predicted   ┌──────▼────────┐
   │  EFFECT      │◀──────────────┤   ACTUATION   │
   │  VERIFIER    │   effect      │  (typed)      │
   └──────┬───────┘               └───────────────┘
          │
          ▼
   ┌──────────────┐
   │  LEDGER      │  lex-trail events + std.sql tables → board report (#82)
   └──────────────┘
```

The kernel/host split (see § 4): the boxes' *types and invariants* are
`lex-ctl`; the *wiring, signals, actions, and thresholds* are loom.

### 2.1 Sensing — residuals, not thresholds (CTL3, #121)

Each series in `company_operate_signals` (liveness latency, error-log match
counts, usage counts as `[monitoring].checks` grows, per-iteration cost from
#94) gets a cheap baseline predictor — EWMA or seasonal-naive, written as
pure Lex functions over the signal history. What reaches the controller is
the **standardised residual against the baseline**, not the level, stored in
integer milli-units (a residual of 1.234 is `1234`). One currency across
heterogeneous signals; thresholds never give you that.

Correlated firings collapse by (company × time window) before anything wakes
the controller — loom's dependency graph is one company's few services, so
full graph topology can wait. One incident opens, not N signals.

v0's known blind spot is the motivating case: `check_liveness` counts any
response as up, so a degraded-but-responding server is invisible. A latency
or error-rate residual catches exactly that.

Keep exactly **one** hard threshold: the safety interlock that bypasses the
controller entirely. In loom that already exists — the spend cap
(`[policy].budget_eur` → `STOP_WHEN`). Everything else defers judgment to
read time.

### 2.2 State — a mutable incident object, not a stream (CTL4, #122)

The controller never re-reads the firehose. It reads and writes one
structured object — `lex-ctl/incident`:

```lex
type Hypothesis = { cause :: Str, p_pct :: Int, evidence_for :: List[Str], evidence_against :: List[Str] }
type Evidence   = { query :: Str, cost_milli :: Int, result_ref :: Str, ts_ms :: Int }
type Budget     = { spent_milli :: Int, cap_milli :: Int }
type Incident   = { id :: Str, opened_at_ms :: Int, symptoms :: List[Str],
                    hypotheses :: List[Hypothesis], evidence :: List[Evidence],
                    budget :: Budget, actions :: List[Str],
                    pending_effects :: List[Str], status :: Status }
```

This *is* the context-budget mechanism: the incident object is the working
set; everything else is queried on demand. Hypotheses carry explicit numeric
posteriors (integer percent) so a wrong diagnosis is measurable rather than
deniable. The status FSM (`Triage → Acting → Verifying → Resolved`, with
`Escalated` reachable from any live state) is exhaustive — `incident.advance`
rejects illegal moves; nothing may rebuild a record with a different status,
the same rule as lex-agent's task lifecycle.

### 2.3 Evidence acquisition — budgeted, closed tool set (CTL4, #122)

Read tools form a closed set, each annotated with a cost and a hand-assigned
discrimination matrix over hypothesis kinds — loom's set is roughly: recent
error-log scan, health probe, last-deploy diff, cost-ledger query, operate
signal history. No learned value-of-information model; a coarse matrix beats
nothing by a wide margin at this scale.

Stopping rule (`incident.confident`): the max posterior clears `p*`, or the
budget is exhausted, or no remaining query is worth its cost. Budget
exhaustion without confidence → escalate with the dossier, and record a
**sensing gap** — which is a defect of the sensing layer, not of the agent,
and is the highest-value input to the next CTL3 iteration. `incident.spend`
refuses overruns structurally; the log-grep spiral cannot happen.

### 2.4 Actuation — typed effects behind structural gates (CTL6, #124)

Every action class is classified on three axes and given a structural
ceiling — `lex-ctl/tier`:

```lex
type Reversibility = Idempotent | Compensatable | Irreversible
type Blast         = Instance | Service | SharedDep | Global
type Tier          = Auto | Propose | Escalate
type ActionClass   = { key :: Str, reversibility :: Reversibility, blast :: Blast, dwell_ms :: Int }
```

`tier.ceiling` consults the classification alone: irreversible or global →
`Escalate`; compensatable or shared-dependency → at most `Propose`; only
idempotent + blast ≤ service can ever earn `Auto`. `tier.effective` then
demotes below the ceiling on insufficient samples, low hit rate, or a
tripped breaker — promotion comes only from the measured record, per class,
never from another class's performance.

Loom's action vocabulary is a closed enum the kernel never sees: restart the
launched server, redeploy last-good, rollback release — whatever the deploy
tooling (#101) actually supports, with typed parameters. No free-form command
synthesis, ever.

Two non-negotiables:

1. **Preconditions re-check at execution time**, not decision time. The
   executor takes a precondition predicate plus an expected-state hash
   (`std.crypto` over the observed state); mismatch aborts. The world moved
   while the agent was reasoning.
2. **The gate is structural.** The executor holds a capability token scoped
   to the action class — the lex-agent `cap.gate` pattern (`Inconclusive` =
   deny) — and the effect type system bounds what the actuation code *can*
   do. A prompt-level restriction is a suggestion to a text generator; a
   capability check is an invariant. `tier` outcomes route accordingly:
   `Propose` emits a board-layer proposal (#82) with a timeout that
   auto-expires — never auto-escalates to execute; `Escalate` goes to a
   human with the dossier.

### 2.5 Effect contracts — the core mechanism (CTL5, #123)

Every action carries a falsifiable prediction — `lex-ctl/contract`:

```lex
type Predicate      = { signal :: Str, cmp :: Comparator, threshold_milli :: Int }
type EffectContract = { id :: Str, action_id :: Str, class_key :: Str, subsystem :: Str,
                        predicate :: Predicate, deadline_ms :: Int,
                        confidence_pct :: Int, on_falsify :: OnFalsify }
```

The predicate is typed, never free text — a contract whose predicate cannot
be evaluated from ledger signals is rejected at creation, which makes the
confabulator failure mode structurally impossible. The contract `id` is the
SHA-256 of its canonical content, so the same prediction has the same id
wherever it is materialised.

The verifier is a scheduled job in the company runner — deliberately not the
agent. Its pure judgement is `lex-ctl/verify.judge`:

- **Materialised** → record a hit for the class (`tier.record`).
- **Falsified** → execute `on_falsify` (rollback / hold / escalate),
  downgrade the motivating hypothesis, return to evidence acquisition with
  the falsification as new evidence. A signal that has gone unobservable is
  a falsification too.
- **Ambiguous** (another action was in flight on the same subsystem) →
  **counts as falsified.** Ambiguity is a scheduling bug; it must never
  inflate a hit rate.

This one mechanism buys rollback policy, hypothesis updating, and a real
competence metric — hit rate per action class — with no extra machinery, and
that metric is what `tier.effective` consumes: the system earns its own
authority from measured evidence.

### 2.6 Stability — the controller is inside the loop it observes (CTL6, #124)

Oscillation is the default failure mode, not the exotic one. Four hard
constraints, all in `lex-ctl/stability` and all consulted by the same
structural `can_act` check:

- **Dwell locks.** No new action on a subsystem while a prior effect there is
  pending — also what keeps attribution identifiable for the verifier.
- **Hysteresis.** Entry and exit thresholds differ (`enter > exit` is
  enforced by construction). Never symmetric.
- **Global concurrency cap.** Bounded in-flight actions system-wide,
  independent of how many incidents are open. Phase 4 runs with cap = 1.
- **Circuit breaker on the controller itself.** N consecutive falsified
  contracts in a class → the class drops to `Propose`. The kernel never
  self-resets a breaker; recovery is a human decision or shadow-mode
  re-qualification.

An undamped controller with write access to production is strictly worse
than no controller at all.

### 2.7 Trust boundary — ingested content is data, never instruction

Production log lines, error messages containing user-supplied strings,
upstream API error bodies: all attacker-influenceable. Rules, consistent
with loom's existing handling of the error-log scan and board notes:

- Retrieved content enters as **typed `Evidence` records** — structured and
  truncated at ingestion, referenced by `result_ref`, never spliced as free
  text into the reasoning channel.
- **No retrieved content can widen a capability.** The gate consults the
  action classification and the capability token; it never consults the
  incident narrative.
- Actions come from the closed enum with typed parameters (§ 2.4).

Given a system that can act on production, this is the actual security
boundary. Everything else is hygiene.

### 2.8 The ledger — the human's dashboard (CTL2, #120)

Two layers, one record:

- **`std.sql` tables** — `operate_signals` (extends #85's
  `company_operate_signals`), `operate_incidents`, `operate_actions`,
  `operate_effects`, `operate_evidence` — the queryable projection.
- **lex-trail events** (new operate kinds) — every row's content hash lands
  on the hash-chained, content-addressed trail, same substrate as sprint
  traces, so the record is tamper-evident and an audit is a hash comparison.

The chain per incident reads:

```
observation → hypothesis(+posterior) → authority invoked → action(+params)
            → predicted effect → observed effect → disposition
```

The human read path is the board report (#82), extended to render exactly
this: what the controller did, under what authority, on what evidence, what
it predicted, whether it was right, what it cost. A **verification surface**,
not a metrics surface — legible without reconstructing the reasoning.

---

## 3. Kernel / host split

| Concern | `lex-ctl` (mechanism) | loom (policy + wiring) |
|---|---|---|
| Contract + predicate types, content-addressed ids | ✅ | — |
| Verifier judgement (ambiguous = falsified) | ✅ | scheduler slot in company runner |
| Tier ceilings, hit-rate promotion, breaker | ✅ | thresholds (`Policy`), breaker recovery decision |
| Dwell locks, hysteresis, concurrency cap | ✅ | subsystem keys, cap value, dwell durations |
| Incident object, budget, status FSM | ✅ | evidence tools, costs, discrimination matrix, `p*` |
| Baselines / residual scoring | — | ✅ (pure Lex over signal history) |
| Action vocabulary + executors | — | ✅ (closed enum over deploy tooling #101) |
| Ledger tables + trail event kinds | — | ✅ (CTL2; trail kinds upstreamed later) |
| Strategist metric feed | — | ✅ (CTL7, extends #86) |

lex-soft consumes the same kernel for domain-pack actions (lex-soft#106);
that second consumer is what keeps the kernel API honest — co-validate
before freezing it (#126).

---

## 4. Build strategy

Phased; each phase produces standalone value and a measured promotion
criterion for the next. **Do not build phases 1–4 and then turn it on.**

| Phase | Issue | Deliverable | Promotion criterion |
|---|---|---|---|
| 0 — Ledger + replay corpus | #120 | tables populated from run history (`dataforge`, `linksnap`, later runs); replay queries | corpus exists; a known incident replays end to end |
| 1 — Sensing standalone | #121 | residual scoring + incident grouping, no agent | recall ≥ v0 binary check; degraded-but-up caught; volume down |
| 2 — Shadow diagnosis | #122 | incident objects + hypotheses over replay; no actions | top-1 root cause ≥ 60 %; calibration sane (miscalibration poisons tier promotion — it consumes these numbers) |
| 3 — Shadow contracts | #123 | contracts proposed on live incidents; nothing executes; verifier scores counterfactually | hit rate ≥ 70 % in ≥ 1 class with ≥ 30 samples |
| 4 — First auto class | #124 | most boring qualifying class (restart launched server); breaker armed; global cap = 1 | one month watched for **oscillation, not accuracy** — accuracy was phase 3's job |
| 5 — Expansion | — | one class at a time, each on its own record | per-class hit rate only; sensing gaps feed phase 1 |
| 6 — Multi-agent | — | only if one evidence budget genuinely cannot cover the domain | do not do this for elegance |

Phase 3 is where the design gets tested: writing a falsifiable prediction is
much harder than writing a plausible remediation, and that gap is exactly
the gap between a controller and a suggestion engine.

The Strategist feed (CTL7, #125) starts consuming ledger metrics from phase
0 onward and gets richer with each phase — closing #84's core finding that
the Strategist is never given a real business signal.

---

## 5. Metrics

The system must be scoreable, or the autonomy tiers have nothing to consume.

| Metric | Definition | Use |
|---|---|---|
| **Effect hit rate** | contracts satisfied by deadline, per action class | tier promotion (`tier.effective`) |
| **Calibration** | stated confidence vs. observed frequency | trust in posteriors; phase-2 gate |
| **Diagnosis top-1** | root cause correct on replay | phase-2 gate |
| **Evidence efficiency** | budget spent per incident resolved | cost control (ties into #94) |
| **Oscillation rate** | actions reversed within 2× dwell | stability alarm; phase-4 watch |
| **Escalation precision** | escalations a human agreed needed escalating | over/under-caution |
| **Sensing gap rate** | budget exhausted without confidence | phase-1 backlog |

---

## 6. Stack

The original design proposed Dagster (orchestration), DuckDB (ledger), and
statsmodels (baselines) for a solo Python developer. All three are
superseded — the Lex ecosystem already ships the load-bearing pieces:

| Concern | Original proposal | Lex-native |
|---|---|---|
| Effect contracts, tiers, stability, incident | (custom Python) | **lex-ctl** |
| Ledger + audit | DuckDB | **`std.sql`** tables + **lex-trail** (content-addressed, tamper-evident, replayable) |
| Capability gates | capability tokens in executor | **lex-agent `cap.gate`** + the Lex **effect type system** — the boundary an effects-typed runtime exists to enforce |
| Verification scheduling | Dagster sensor | company runner's between-iteration slot (where OP1 already runs) |
| Baselines | statsmodels / Kalman | pure Lex EWMA / seasonal-naive; integer milli-unit residuals |
| Hypothesis scoring | plain Bayes over a hand matrix | same idea, integer-percent posteriors in the incident object |

Deliberate omissions carried over: no vector store (the incident object is
the memory), no fine-tuning (leverage lives in the contracts and gate
taxonomy), no graph database (the dependency graph is an adjacency list at
loom's scale).

---

## 7. Failure modes to design against

1. **The oscillator** — acts, observes noise, acts again → dwell locks,
   hysteresis, concurrency cap (§ 2.6).
2. **The confabulator** — plausible narrative, no falsifiable claim →
   contracts mandatory; untyped predicates unrepresentable (§ 2.5).
3. **The context glutton** — ingests logs until the window collapses →
   incident object as working set; `spend` refuses overruns (§ 2.2–2.3).
4. **The over-escalator** — every incident to a human; a slower pager →
   track escalation precision; budget exhaustion is a *sensing* defect.
5. **The confounded verifier** — two actions in flight, effect
   unattributable → dwell locks; ambiguous = falsified.
6. **The injected actuator** — log content steers action selection → closed
   action enum, typed params, gate blind to narrative (§ 2.7).
7. **The frozen gate** — tiers set once, never revisited → promotion *and*
   demotion from the rolling record; breaker never self-resets.
