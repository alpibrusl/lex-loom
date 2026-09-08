# Packages needed for the first consortium

Status: request to the lex-code team. Written 2026-09-08 from the Lex Consortium
Strategy document (sections 7, 8, 12, 16, 18, 19) and from what the repositories
contain today. Scope is the "killer first case": three companies (ResearchCo,
SoftwareCo, MarketCo) contracting with each other to ship one micro-product under
a fixed budget.

The short answer: **one new repository, `lex-economy`, with seven small modules,
plus a bounded set of changes inside `lex-loom`.** Most primitives the strategy
names already exist in `lex-soft`, `lex-guard`, `lex-x402` and `lex-trail`;
`lex-economy` must compose them, not re-implement them.

---

## 1. What already exists (do not rebuild)

| Need (strategy §7) | Exists in | Surface |
|---|---|---|
| Company identity, signing key | `lex-soft/src/identity.lex`, `trust.lex` | org identity, key handling, trust records |
| Ledger, spend, metering | `lex-soft/src/ledger.lex`, `spend.lex`, `metering.lex` | `record_spend`, `record_chargeback`, per-agent ledger |
| Spend policy and gating | `lex-guard` | `spend`, `spend_gated`, `spend_reviewed`, `check_stateless(policy, intent)`, `authorize_spend_cap` |
| Capability offers and matching | `lex-soft/src/matchmaking.lex`, `registry.lex` | `Offer {id, attrs}`, `Query`, `offer_satisfies(o, q)`, `OrgCaps` |
| Evidence-gated settlement | `lex-soft/src/settlement.lex`, `verdict.lex`, `evidence.lex` | `authorize_spend_gated`, `verify_pass`, `record_outcome`, `Verdict {intact, linked, legal, verified, spec_applied, score, reason}` |
| Real payment rail | `lex-x402` | `charge(facilitator, payment_header, requirements)`, `verify`, `settle`, mock facilitator |
| Tamper-evident event log | `lex-trail` | `append`, `append_actor`, `chain`, `anchor`, `verify(log, anchor)`, `export` |
| Attestation for non-Lex adopters | `lex-attest` (HTTP sidecar) | anchors, "what stops you rewriting it" |
| Inter-company relationships | `lex-soft/src/relationships.lex`; loom `relationships` table | `{from_agent, to_agent, role, contract_json, active}` |
| Per-company budgets | loom `budget_envelopes {scope, cap_cents, spent_cents}`, `allocations`, `mission_ledger` | envelope checks refuse an iteration on exhaustion (proven live) |
| Verified software delivery | `lex-loom` | grounded verdict ladder: gates on disk, executed pins, acceptance re-executes the artifact (three finished company runs on 2026-09-08) |

What is **missing** is the layer that turns these into a market with contracts:
a typed canonical `Contract`, `WorkRequest`/`Bid`, a `Treasury` with commitments
across companies, deterministic verifiers per contract type, a reputation
projection from contract outcomes, and the controller that runs several
companies against one objective.

---

## 2. Repository: `lex-economy` (new)

Rules that apply to the whole package:

- **Mechanism, not policy.** `lex-economy` never imports `lex-loom` and never
  names a product or a company. `lex-loom` imports `lex-economy`. (Same rule
  `lex-soft` already follows; grep for product names before merge.)
- **Pure core, effectful edges.** Every module has a pure part (types,
  validation, state transitions) in its own file so that a consumer importing
  the pure part does not inherit `sql`/`net`/`proc` effects. Lex effects are
  per-program; one shared effectful module widens every caller.
- **Storage** through `lex-orm` with the same dialect layer loom uses
  (SQLite locally, Postgres via `DB_PATH=postgres://`; `?` placeholders,
  `BIGINT`, `ON CONFLICT`).
- **Every state change appends a `lex-trail` event** with a fixed `kind`
  string listed in this document. Verdicts and settlements must be
  reconstructible from the trail alone.
- **Tests must be able to fail.** Each module ships positive tests, negative
  controls, and at least one "sabotage" test documented in the test file
  (disable the invariant → the test fails). CI runs `lex ci`; comments go
  above functions, never inside bodies (`lex fmt` deletes them).
- Toolchain: lex 0.10.18. Dependencies unpinned; ship `deps.lock` and the
  drift guard as in `lex-loom/bin/check-dep-drift.sh`.

### 2.1 `identity` — CompanyId and keys

Thin wrapper over `lex-soft/identity`.

```lex
type CompanyId = { id :: Str, public_key_b64 :: Str }
type Company = { id :: CompanyId, mission :: Str, status :: CompanyStatus, capabilities :: List[Capability], policy :: guard.Policy }
type CompanyStatus = Incorporated | Active | Restructuring | Liquidated

fn incorporate(name :: Str, mission :: Str, key :: KeyPair) -> Company
fn sign(company :: Company, payload :: Str) -> Str
fn verify_signature(id :: CompanyId, payload :: Str, sig :: Str) -> Bool
```

Trail kinds: `company_incorporated`, `company_status_changed`.

Invariant: a company id is the hash of its public key; two companies cannot
share a key.

### 2.2 `treasury` — balances and commitments (strategy Phase 1)

The one piece of accounting the market needs and nothing has today: a
**commitment** that reserves funds when a bid is accepted and releases or
settles them on a verdict.

```lex
type Money = { cents :: Int, currency :: Str }              # integer cents only
type Treasury = { company :: Str, balance :: Money, committed :: Money }
type Commitment = { id :: Str, company :: Str, contract_id :: Str, amount :: Money, state :: CommitmentState }
type CommitmentState = Reserved | Settled | Released

fn open(db, company :: Str, initial :: Money) -> Result[Treasury, EconError]
fn balance(db, company :: Str) -> Result[Treasury, EconError]
fn commit(db, log, company :: Str, contract_id :: Str, amount :: Money, policy :: guard.Policy) -> Result[Commitment, EconError]
fn settle(db, log, commitment_id :: Str, pay :: Money, to :: Str) -> Result[Unit, EconError]   # pay <= reserved; remainder released
fn release(db, log, commitment_id :: Str) -> Result[Unit, EconError]
fn credit(db, log, company :: Str, amount :: Money, ref :: Str) -> Result[Unit, EconError]
```

Invariants (each with a test and a sabotage test):

- `balance - committed >= 0` at all times; `commit` fails with
  `InsufficientFunds` rather than overdrawing.
- `commit` must pass `lex-guard.check_stateless(policy, intent)`; a company
  cannot commit more than its policy allows even when it has the cash.
- `settle` pays at most the reserved amount; the difference is released.
- Money is integer cents; no floats anywhere in the package.

Trail kinds: `treasury_opened`, `funds_committed`, `funds_settled`,
`funds_released`, `funds_credited`. Amounts are recorded as `{cents, currency}`.

Storage: `treasuries(company, balance_cents, committed_cents, currency)`,
`commitments(id, company, contract_id, amount_cents, currency, state, created_at, updated_at)`.

### 2.3 `capability` — declare and discover (Phase 2, first half)

Reuse `lex-soft/matchmaking` for storage and matching; add the typed shape
the strategy specifies.

```lex
type Capability = { name :: Str, version :: Str, inputs :: List[Str], outputs :: List[Str], sla_max_minutes :: Int, evidence_schema :: Str }
type CapabilityOffer = { company :: Str, capability :: Capability, base_price :: Money, expected_minutes :: Int }

fn register(db, log, offer :: CapabilityOffer) -> Result[Unit, EconError]
fn discover(db, name :: Str, version :: Str, min_trust :: Int) -> Result[List[CapabilityOffer], EconError]
fn to_soft_offer(o :: CapabilityOffer) -> soft.Offer      # bridge to lex-soft matchmaking
```

Trail kinds: `capability_registered`, `capability_withdrawn`.

No negotiation: discovery returns offers; the buyer picks. Versioned by
string; `discover` matches exact name and version only.

### 2.4 `request` and `bid` — one offer, one acceptance (Phase 2, second half)

```lex
type WorkRequest = { id :: Str, buyer :: Str, capability :: Str, version :: Str, input :: Json, budget_ceiling :: Money, deadline_ms :: Int, acceptance_criteria :: List[Criterion], required_evidence :: List[Str], min_trust :: Int }
type Bid = { id :: Str, request_id :: Str, supplier :: Str, price :: Money, eta_minutes :: Int, confidence :: Int, scope :: Str, exceptions :: List[Str], required_inputs :: List[Str] }

fn publish_request(db, log, r :: WorkRequest) -> Result[Unit, EconError]
fn submit_bid(db, log, b :: Bid) -> Result[Unit, EconError]        # rejects price > budget_ceiling, unknown request, expired deadline
fn select_bid(db, log, request_id :: Str, bid_id :: Str) -> Result[Contract, EconError]   # creates the Contract and the buyer's Commitment atomically
```

`Criterion` is shared with `verdict` (below): every acceptance criterion is
tagged `Checkable(spec)`, `AskHuman(question)` or `Mixed(spec, question)` at
request time. This is the rule from the prompt-to books applied to
contracts: the machine never fills in the human's half.

Trail kinds: `request_published`, `bid_submitted`, `bid_selected`,
`bid_rejected`.

### 2.5 `contract` — the canonical object (Phase 3)

One `Contract` type for the whole ecosystem; packs may not invent their own.

```lex
type Contract = { id :: Str, buyer :: Str, supplier :: Str, capability :: Str, version :: Str, price :: Money, deadline_ms :: Int, acceptance_criteria :: List[Criterion], evidence_requirements :: List[Str], settlement_rule :: SettlementRule, failure_rule :: FailureRule, dispute_rule :: DisputeRule, state :: ContractState, commitment_id :: Str }
type SettlementRule = { fulfilled_pct :: Int, partially_fulfilled_pct :: Int, rejected_pct :: Int }   # e.g. 100 / 50 / 0
type FailureRule = ReleaseFunds | PenaltyPct(Int)
type DisputeRule = HumanArbiter(Str) | SecondVerifier
type ContractState = Awarded | InProgress | Delivered | Verified(Verdict) | Settled | Disputed | Cancelled

fn transition(c :: Contract, event :: ContractEvent) -> Result[Contract, EconError]   # pure state machine
fn is_terminal(c :: Contract) -> Bool
fn save(db, log, c :: Contract) -> Result[Unit, EconError]
```

Invariants: every transition is total and logged; `Settled` is reachable
only from `Verified`; `Disputed` is reachable only from `Verified` or
`Delivered`; a contract's `price` never exceeds the request's
`budget_ceiling`. The state machine is pure and property-tested.

Trail kinds: `contract_awarded`, `contract_started`, `contract_delivered`,
`contract_verified`, `contract_settled`, `contract_disputed`,
`contract_cancelled`.

### 2.6 `evidence` and `verdict` — deterministic verification (Phase 4)

```lex
type EvidenceBundle = { contract_id :: Str, artifact_hash :: Str, trail_anchor :: trail.Anchor, files :: List[{ path :: Str, sha256 :: Str }], claims :: List[Claim] }
type Verdict = Fulfilled | PartiallyFulfilled(List[Str]) | Rejected(List[Str]) | Ambiguous(List[Str])

fn verify(bundle :: EvidenceBundle, c :: Contract, verifier :: Verifier) -> Result[Verdict, EconError]
```

`Verifier` is a per-capability strategy:

- **software-delivery** — delegates to what `lex-loom` already does:
  re-execute the sealed artifact in a clean directory, run its test suite,
  require derived expected values, require a launch that answered. The
  bundle's `artifact_hash` must match the re-executed tree.
- **research-report** (opportunity research, competitive analysis) — the
  mechanical half only: sources present and resolvable, alternatives count
  ≥ N, required sections present, confidence stated, word bounds. The
  judgement half is emitted as `AskHuman` items and never auto-filled;
  `Ambiguous` is the verdict when the mechanical half passes and the human
  half is unanswered.
- **market-validation** — same shape as research-report.

Rules: prefer a mechanical check to an LLM judge everywhere a criterion is
`Checkable`; an LLM may only rank or summarise, never produce the verdict.
`verify` must be reproducible: same bundle, same contract, same verdict.

Trail kinds: `evidence_submitted`, `verdict_issued`, `verdict_disputed`.

### 2.7 `settlement` — pay only after a verdict (Phase 4)

Binds `treasury.settle` to the contract's `SettlementRule`:

```lex
fn settle_contract(db, log, c :: Contract, v :: Verdict, rail :: Rail) -> Result[Contract, EconError]
type Rail = Simulated | X402(x402.Facilitator)
```

`Simulated` moves cents between treasuries; `X402` charges through
`lex-x402` (mock facilitator in tests). Reuse `lex-soft/settlement.lex`'s
`authorize_spend_gated` so the same evidence gate that governs agent spend
governs contract payment. A `Rejected` verdict releases the commitment; a
`PartiallyFulfilled` verdict pays the rule's percentage.

### 2.8 `reputation` — a projection, not a score (strategy §8)

No star ratings. A pure function over trail events:

```lex
type Reputation = { company :: Str, contracts_completed :: Int, contracts_failed :: Int, contracts_disputed :: Int, verification_pass_rate_bp :: Int, median_delivery_delay_min :: Int, median_cost_variance_bp :: Int, repeat_customer_rate_bp :: Int }
fn project(events :: List[trail.Event], company :: Str) -> Reputation
```

Rates in basis points (integers). `discover` uses `min_trust` against
`verification_pass_rate_bp`. Test: the projection of a replayed trail equals
the projection of the live one.

### 2.9 `consortium` — the controller (Phase 7)

Only what the strategy allows: create companies, allocate starting capital,
set a shared objective, observe.

```lex
type Consortium = { id :: Str, objective :: Str, companies :: List[Str], max_spend :: Money, termination :: TerminationRule }
fn create(db, log, spec :: ConsortiumSpec) -> Result[Consortium, EconError]
fn observe(db, id :: Str) -> Result[PortfolioView, EconError]    # treasuries, open contracts, verdicts, spend vs max_spend
fn should_terminate(view :: PortfolioView, rule :: TerminationRule) -> Bool   # pure
```

Termination is pure and testable: objective met, max spend reached, deadline
passed, or no open contracts and no capital to start new ones.

---

## 3. Changes inside `lex-loom` (not a package)

1. **Company ↔ economy binding.** `CompanyCfg` gains `company_id` and a
   treasury; `budget_envelopes` become a view over the treasury for the
   company's own spend. The envelope refusal stays (it works).
2. **Capabilities from role packs.** A company declares capabilities from
   its staffed packs (`core` + `python-fastapi` → `software-delivery/v1`;
   research packs → `opportunity-research/v1`) and registers them at start.
3. **Contract-driven sprint.** A won contract becomes a sprint: the request's
   `input` is the goal, the contract's `acceptance_criteria` are the PM's
   criteria (tagged `Checkable`/`AskHuman`), the sealed artifact plus its
   trail anchor become the `EvidenceBundle`. Acceptance already re-executes
   the disk; it just needs to emit the bundle.
4. **Procurement loop (Phase 5).** Before the architect plans, a
   `procurement` step asks: internal capability available? external offer
   discoverable? estimated internal cost (from the role evals' time and
   token baselines) versus best bid? → `Build | Buy(bid) | Defer`. Decision
   and estimates are trail events (`procurement_decided`). First version:
   deterministic rule on cost and trust, no LLM.
5. **Strategist boundary.** Goals and criteria describe behaviour, never
   layout, ports, commands or pipeline gates (already enforced in prompts;
   the contract's `Criterion` tagging makes it structural).

---

## 4. What not to build in the first version

- No negotiation loop (one offer, one acceptance).
- No star ratings, no single trust score.
- No real money on the first runs: `Rail = Simulated`; `X402` behind a
  human-approved grant, as deploy and publishing are today.
- No new LLM judges. Where a criterion cannot be checked mechanically it is
  an `AskHuman` item, and the verdict is `Ambiguous` until a human answers.
- No `lex-code` exposure to the market (Phase 6 is explicitly later).

---

## 5. Sequence and exit criteria

| Step | Deliverable | Exit criterion |
|---|---|---|
| 0 | Freeze document (companies, capital, capabilities, contract schemas, success/failure, max spend, termination) | One page, agreed, no scope growth afterwards |
| 1 | `identity` + `treasury` | Invariant tests pass; sabotage tests fail; a company cannot commit beyond policy or balance |
| 2 | `capability` + `request`/`bid` | Two in-process companies: one publishes, one bids, selection creates a contract and a commitment atomically |
| 3 | `contract` state machine | Property tests over every transition; replay from trail reproduces state |
| 4 | `evidence` + `verdict` + `settlement` | A loom software delivery settles `Simulated` funds after re-execution; a broken delivery is `Rejected` and releases funds |
| 5 | `reputation` + `consortium.observe` | Projection equals replay; controller reports spend against max |
| 6 | loom procurement loop | A company chooses Buy when an offer is cheaper than its own eval-derived estimate, Build otherwise, with the decision in the trail |
| 7 | Two-company dry run | SoftwareCo (tzconvert company) buys `opportunity-research/v1` from ResearchCo; verdict `Ambiguous` until the human half is answered; settlement follows the rule |

Wall-clock note: one GPU serialises companies at roughly fifty minutes per
iteration on the local 27B model. A three-company round is hours. Plan the
dry run overnight or on a second machine.

---

## 6. Open questions for the freeze document

- Who arbitrates a `Disputed` contract in the first run: a named human, or a
  second verifier company?
- Starting capital per company and the consortium `max_spend`, in cents,
  simulated.
- The first three capability schemas' `evidence_schema` fields
  (research-report, market-validation, software-delivery).
- Whether `min_trust` applies on the first run at all (every company starts
  with an empty reputation).
