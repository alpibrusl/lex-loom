# Consortium first run — freeze document (DRAFT for agreement)

Status: draft, 2026-09-08. This is the Phase 0 document the strategy requires
before the first consortium implementation grows further: one page fixing
the companies, capital, capabilities, contract schemas, success and failure
criteria, maximum spend and termination. Items marked **DECISION** are the
founder's to settle; everything else is a proposal grounded in what runs today.

Once agreed, no scope growth during the first implementation.

---

## 1. Objective (from the strategy, unchanged)

Identify, build, validate and publish one genuinely useful open-source
micro-product while respecting a fixed simulated operating budget. The run
succeeds only if the full loop works: research → contract → build →
independent verification → settlement → strategy adaptation.

## 2. Companies

First run is **two companies**, not three. MarketCo joins in the second run
once contracting between two works end to end.

| Company | Mission | Path / roles | Sells | Buys |
|---|---|---|---|---|
| **SoftwareCo** | Turn an opportunity report into a working, tested, launched micro-API | `python-fastapi`, packs `core` (proven: 4 of 5 finished runs on 2026-09-08) | `software-delivery/v1` | `opportunity-research/v1` |
| **ResearchCo** | Find one technically feasible micro-product opportunity and document it with evidence | prose roles: researcher, analyst, verifier (`core` + `research` pack, judge-gated) | `opportunity-research/v1` | nothing in run 1 |

Both companies run on the same model (`qwen3.8:27b-mlx` through LiteLLM) and
the same machine, one at a time. Wall-clock: a SoftwareCo iteration is about
50 minutes; a ResearchCo iteration is unmeasured (**risk**: prose roles are
the most-denied nodes in every run so far).

## 3. Capital (simulated cents)

| | Starting balance | Policy cap per commitment |
|---|---|---|
| SoftwareCo | 200 000 (€2.00) | 60 000 |
| ResearchCo | 100 000 (€1.00) | 20 000 |
| Consortium `max_spend` | 300 000 (€3.00) total inference-equivalent | — |

Rail: `Simulated` (treasury moves cents between companies; no x402, no real
money). Loom's per-company spend estimate keeps counting tokens as today.

**DECISION 1:** the amounts above, or different ones. They only need to make
one contract affordable and two unaffordable.

## 4. Capabilities (versioned, machine-discoverable)

```
opportunity-research/v1
  inputs:  problem_space, market_scope
  outputs: opportunity_report (markdown), evidence_bundle
  sla:     max 90 minutes

software-delivery/v1
  inputs:  opportunity_report, product_spec
  outputs: sealed_artifact (work dir), evidence_bundle (tests, launch, acceptance)
  sla:     max 180 minutes
```

## 5. Contract schema (lex-economy `contract.lex` as built, plus the request)

`Contract = {id, buyer, supplier, price :: Money{cents, currency}, state}` with
the state machine `Awarded → InProgress → Delivered → Verified(Verdict) →
Settled`, plus `Disputed` and `Cancelled`.

Acceptance criteria live on the **WorkRequest** (lex-economy issue #1), each
tagged so the machine never fills in the human's half:

```
Criterion = Checkable(spec) | AskHuman(question) | Mixed(spec, question)
```

First contract: **Opportunity Research** (buyer SoftwareCo, supplier ResearchCo,
price 40 000 cents, deadline 90 minutes).

Criteria:

- Checkable: report present, ≥ 3 alternatives in a comparison table, a named
  target user, a problem statement, an implementation estimate in hours, a
  dependency list, a confidence figure between 0 and 100, every cited source
  resolvable (HTTP 200) — all mechanical (`spec sh` gates over the report).
- AskHuman: "Is the recommended opportunity one you would fund?" — answered by
  the founder; until then the verdict is `Ambiguous`.

Settlement rule: 100% on `Fulfilled`, 50% on `PartiallyFulfilled`, 0% on
`Rejected`; `Ambiguous` holds the commitment until the human answers.
Failure rule: release funds. Dispute rule: **DECISION 2** — the founder as
arbiter (proposed) or a second verifier company (adds a third company).

Second contract (same run): **Software Delivery** — SoftwareCo executes
internally (build, not buy); the contract exists so the artifact goes through
the same evidence → verdict → settlement path with SoftwareCo as both parties.
Verifier: loom's acceptance (re-execute the sealed artifact, run its suite,
derived values, launch answers). Price 60 000 cents, deadline 180 minutes.

## 6. Success and failure criteria for the run

Success (all required):

1. ResearchCo delivers an opportunity report that passes every `Checkable`
   criterion mechanically.
2. The founder answers the `AskHuman` item; the verdict becomes `Fulfilled` or
   `PartiallyFulfilled`; settlement moves the ruled percentage.
3. SoftwareCo builds the product from the report; loom's acceptance passes;
   the software-delivery contract settles.
4. Total spend ≤ `max_spend`; every treasury invariant holds throughout;
   the whole run is reconstructible from the trail.

Failure (any):

- A verdict that cannot be reproduced from the evidence bundle.
- A settlement not preceded by a verdict.
- A company committing beyond its balance or its policy cap.
- `max_spend` exceeded, or the deadline of either contract missed.

Neither outcome is a failure of the *run* if the machinery behaved: a
`Rejected` research report that releases funds is a valid consortium round.

## 7. Termination

The run ends when any holds: both contracts terminal; `max_spend` reached;
6 hours of wall-clock; or the founder stops it. `consortium.should_terminate`
is pure and testable on those four conditions.

## 8. What is deliberately out of scope for run 1

MarketCo; negotiation; real money (x402); reputation thresholds
(`min_trust` = 0, every company starts empty — **DECISION 3**: confirm);
lex-code behind a capability boundary; deploy to a host; publishing.

## 9. Open decisions

1. Capital amounts (§3).
2. Dispute arbiter: founder or second verifier company (§5).
3. `min_trust` = 0 for run 1 (§8).
4. The problem space handed to ResearchCo for the first request (one sentence;
   something other than timestamps, to avoid re-solving tzconvert).
