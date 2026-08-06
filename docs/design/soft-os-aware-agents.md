# Soft-aware and os-aware loom agents

Status: design, epic filed (`lex-loom#177`); SA1 done (`lex-loom#178`), SA2
done (`lex-loom#179`), SA3 done (`lex-loom#180`), SA4 done (`lex-loom#181`
read-only roles + follow-up `lex-loom#187` for `content_creator`'s write),
OA1 done (`lex-loom#182`), OA2 done (`lex-loom#183`), OA3 partial
(`lex-loom#184`, mechanical change shipped, real-KVM validation blocked on
infrastructure, left open). Written 2026-08-04, following the ecosystem
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
- **SA2 — register one outward-facing role in soft's mesh. Done.** Picked
  CX (real, tested tool; monetization-handoff has no tool at all and
  nothing external would meaningfully call it over A2A). There is no
  literal `mesh.mount` in lex-soft — the real self-onboard surface is
  `POST /peers` on a `federation.mount_federation`-mounted node, which
  ships no runnable binary either; `lex-soft` gained one
  (`src/federation_node.lex`) so "a real soft node" has something to
  stand up against. loom's own A2A server was likewise never mounted over
  real HTTP before this (only exposed via MCP stdio) — `src/server/cx_a2a.lex`
  wraps CX's existing `fetch_support_items` tool (factored out of
  `roles.lex`, same tested logic, not a smarter one) as a real A2A
  `Skill`, mounted with `lex-agent/src/mount.lex`. `src/soft_register.lex`
  reads a company's `[soft]` config (SA1) and POSTs the registration;
  unknown roles / missing config are clean errors before any network call.
  *Promotion criterion:* a second, independent soft node discovers and
  successfully A2A-messages the registered role end to end. **Verified
  live** — `demo/sa2-mesh-roundtrip.sh` stands up a fresh federation node,
  registers CX into it, confirms discovery via that node's own `GET
  /peers`, and sends real `tasks/send` JSON-RPC requests straight to the
  registered `inbox_url`, both the happy path (a real fetched item) and
  the clean-error path (product unreachable) — reproduced from a clean
  state, not a one-off.
- **SA3 — evidence-gated settlement for one real money signal. Done.**
  lex-soft's `verdict`/`settlement`/`ledger` turned out to be a
  library-level Lex API with no deployed write/verify HTTP surface (the
  only mounted settlement route anywhere is a read-only `GET /trails/:id`)
  — so `lex-soft` became a real `lex.toml` package dependency of this repo
  rather than something reached over HTTP the way SA2's mesh registration
  is. `[soft].settlement = true` routes a company's per-iteration
  `REVENUE_URL` reading through `src/soft_settlement.lex`: the claim is
  recorded as a hash-chained trail event (in this company's own db — no
  second database or network hop) and immediately re-derived via
  `verdict.verify` against a real legality spec ("claimed revenue must be
  non-negative"), not trusted at face value. `revenue_url` stays the data
  source either way, exactly as scoped — this changes what happens to the
  reading after it's fetched, not where it comes from.
  *Promotion criterion:* a settlement event soft produced is the one
  `board_report` cites, and it survives an independent re-verification
  (soft's own evidence re-derivation). **Verified live** —
  `demo/sa3-settlement-roundtrip.sh` seeds a company, checks a real
  fetched revenue reading through the settlement path, shows
  `board_report` citing the resulting `trail_id` + `verified` status,
  independently re-derives the same verdict from a freshly opened trail
  handle (verified=true), then tampers with the underlying event and
  re-derives again — correctly flipping to verified=false — reproduced
  from a clean state.
- **SA4 — expand to the rest of Distribution. Partially done.** `research`
  (`web_search`) registers the same way `cx` did in SA2 —
  `src/server/research_a2a.lex` mirrors `src/server/cx_a2a.lex` field for
  field, `soft_register.lex`'s `known_capabilities` gained one entry, and
  it's proven live the same way (`demo/sa4-research-roundtrip.sh`). That
  confirms SA2's pattern actually generalizes, which was SA4's real
  question.
  **`content_creator`'s `publish_content` was deliberately NOT wired
  here** — split out to `lex-loom#187`, now done (see below).
  *Promotion criterion (for the roles covered here — `cx`, `research`):*
  every one is discoverable and reachable through soft's mesh; no bespoke
  per-role integration code remains for them. **Met.**
- **SA4 follow-up (`lex-loom#187`) — authorization for
  `content_creator`'s `publish_content`. Done.** Unlike every role
  registered above, `publish_content` is a real write — it POSTs a blog
  post to the product's live site — so wrapping it the same way SA4 did
  for `cx`/`research` would let any mesh peer who discovers the
  registration trigger a real publish, with no authorization on that path
  (`POST /peers` self-registration is itself unauthenticated). Went with a
  shared-secret bearer-token gate (`src/server/content_a2a.lex`): since
  `lex-agent/src/mount.lex`'s `mount()` never threads HTTP headers down
  into a `Skill.handle` (only the parsed A2A message body reaches it), the
  gate sits one layer up, in a custom `POST /` route that checks
  `Authorization: Bearer <CONTENT_PUBLISH_TOKEN>` via
  `crypto.constant_time_eq` (the same primitive `lex-web`'s own
  `auth_basic.lex`/`auth_apikey.lex` already use) *before* ever calling
  `srv.dispatch_request` — an unauthorized caller never reaches
  `publish_content_core` (factored out of `make_publish_content_tool`, the
  same discipline SA2/SA4 used for `fetch_support_items`/`web_search`), so
  it can never reach the live site. `CONTENT_PUBLISH_TOKEN` unset refuses
  to serve at all — never fail-open into an unauthenticated write.
  Considered and deferred: routing the write through SA3-style
  record+verify settlement — a real complementary idea, but the auth gate
  alone already satisfies the promotion criterion, and settlement-routing
  needs its own sequencing design (gating the live POST on a verdict, not
  just recording after the fact) — noted as a documented future
  enhancement, not built now.
  *Promotion criterion:* `content_creator` registers into soft's mesh and
  is reachable over A2A the same way `cx`/`research` are, AND a mesh peer
  without the authorization this issue adds cannot trigger
  `publish_content` end-to-end (a real negative test). **Met** —
  `demo/content-a2a-roundtrip.sh` registers `content_creator` into a live
  mesh node, confirms discovery, then proves both directions against a
  real fake product server with a hit counter: no-token and wrong-token
  requests both get a real `401` and the product server's hit count stays
  `0`; a correctly-authorized request gets `200` and the hit count becomes
  exactly `1`.
- **SA4 follow-up (`lex-loom#193`) — auth parity for `cx`/`research`.
  Done.** `cx_a2a.lex`/`research_a2a.lex` were deliberately left
  unauthenticated when SA2/SA4 built them, on the reasoning that they're
  read-only. Read-only isn't the same as harmless-to-expose — there's no
  reason a caller with no mesh-relationship credentials should be able to
  invoke them at all, and `cx_a2a.lex` specifically forwards a fully
  caller-supplied `url` to a server-side `curl`, an unauthenticated
  request-forgery surface on top of the missing auth. Gated both exactly
  the way `content_a2a.lex` already is (`#187`): `CX_API_TOKEN` /
  `RESEARCH_API_TOKEN`, required at startup (refuses to serve if unset),
  `Authorization: Bearer <token>` checked via `crypto.constant_time_eq`
  before ever reaching `srv.dispatch_request`/`dispatch_subscribe_str`,
  discovery (`GET /.well-known/agent.json`) left open as public metadata.
  `demo/sa2-mesh-roundtrip.sh`/`demo/sa4-research-roundtrip.sh` both gained
  a real negative test (no-token `tasks/send` → `401`) alongside the
  existing authorized happy path.
  Deliberately **not** fixed here: `cx_a2a.lex`'s caller-supplied `url` is
  still unscoped once a caller does hold a valid token — tracked
  separately as `lex-loom#194`, since the obvious fix (block
  loopback/private-network targets) would break the legitimate case this
  project's own demos rely on (a company's `cx` role fetching from its own
  `Launch`/`Deploy` node's `http://localhost:<port>` URL); a real fix
  needs a way to scope a token to the one URL its own company is allowed
  to target, which is a bigger design question than this issue's auth
  parity fix.
  *Promotion criterion:* `cx`/`research` are reachable over A2A only with
  a valid bearer token, the same as `content_creator`. **Met.**

## Plan — Track OA (os-aware)

- **OA1 — `[policy]` grant declaration in `company.toml`. Done.** Extended
  the existing `[policy]` table with a `[policy.isolation]` role-kind →
  preset override map (`manifests.lex` refactored to expose its 5 named
  presets — `Design`/`Implementation`/`QA`/`Demo`/`Retro` — plus
  `preset_for_kind_with_overrides`/`parse_isolation_overrides`, both unit
  tested; a mistyped preset name falls back to `Demo`, the same safe
  default an unmapped role kind already gets). `cast.lex`'s new
  `roster_grant_report`/`grant_report_text` read it at role-assignment
  time and are exposed via `src/main.lex`'s `roster_grant_report_cmd`.
  Additive only — no enforcement change, `LEX_OS_ISOLATION`'s existing
  behavior (`manifest_json_for_kind`, still called unmodified by the real
  `proc_cmd` mediation path) is untouched.
  *Promotion criterion:* `cast.lex` can report, for a given roster, which
  roles would run under which grant, without anything executing
  differently yet. **Met** — `demo/oa1-grant-report-roundtrip.sh` seeds a
  company with a `build:Demo` override and a 3-node roster (`build`, `qa`,
  `docs`), runs the real `roster_grant_report_cmd`, and checks the
  override wins for `build`, `qa` keeps its own default, and the unmapped
  `docs` role falls back to `Demo` — all without executing anything.
- **OA2 — mediate the LLM executor's tool calls, not just `proc_cmd`.
  Done.** Design reviewed and approved (`docs/design/oa2-tool-call-
  mediation.md`), then implemented: `src/tool_grant.lex` re-evaluates the
  same Grant `manifest_json_for_kind_with_overrides` (OA1) already
  computes — a small, hand-maintained tool→(Dimension,Level) table, pure
  Lex, no new lex-os surface — and `src/agent/runner.lex`'s LLM branch
  filters a role's tool list through it before the model ever sees them.
  `lex_os_exec_step` (the existing `proc_cmd` path) was also switched from
  the unconditional grant to the override-aware one, so OA1's
  `[policy.isolation]` now changes real behavior on both executors, not
  just what gets reported.
  *Promotion criterion:* a QA-shaped grant denies a tool call it shouldn't
  have, end to end, with the LLM loop still completing the sprint via its
  remaining permitted tools — proven first under `--simulated`. **Met** —
  `demo/oa2-tool-filter-roundtrip.sh` shows `build`'s own default grant
  keeping both its tools, a `build:Demo` override denying `lex_check`
  while `lex_guidelines` survives, and then actually *calls* the surviving
  tool for real to prove it's still genuinely functional, not just a name
  left in a list.
  *Promotion criterion:* a QA-shaped grant denies a tool call it shouldn't
  have, end to end, with the LLM loop still completing the sprint via its
  remaining permitted tools — proven first under `--simulated`.
- **OA3 — drop the hardcoded `--simulated` in `lex_os_exec_step`,
  validate on real KVM. Half done.** The code change shipped:
  `lex_os_exec_step` no longer hardcodes `--simulated` — a new
  `LEX_OS_SIMULATED=1` env var forces it, unset defers entirely to
  lex-os's own real-by-default-on-KVM selection (`lex_os_exec_args`, pure,
  unit-tested). **Still open:** this session's environment has no
  `/dev/kvm` / `vmx`/`svm` CPU flags, so real Firecracker cannot be
  validated here — needs a KVM CI runner, which loom doesn't have yet.
  *Promotion criterion:* the same QA-deny/Build-allow proof from Phase 0,
  reproduced against lex-os's real Firecracker backend, not the
  simulated one. **Not met** — genuinely blocked on infrastructure, not
  proven, not claimed proven.

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
