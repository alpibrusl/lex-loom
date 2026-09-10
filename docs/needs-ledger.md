# Needs ledger — what a company depends on, who provides it, is it ready

Status: design, 2026-09-10 (founder: "do it"). Builds on the founding-plan
gate (#422), the operator profile (`examples/loom.profile.toml`,
`bin/check-company-env.sh`), the attention queue, and the cloud runner's
snapshot reporting (loom-cloud companies slice).

## Problem

A company's plan depends on things outside the company: a host, a domain,
a payment rail, a social account to publish on, an email sender, a legal
brand line. Today those are prose in the founding plan, grants and adapter
kinds in the operator profile, and tools that are silently stripped when a
grant is off. Nobody writes down, per company, **which** of these it needs,
**who** provides each one (the founder or the company), **whether it is
ready**, and **which credential** it takes. Readiness is discovered by an
agent at the moment it is missing, wearing the agent's name, hours in.

## Design in three places

### 1. Catalogue (loom, contributed by packs)

`packs/<pack>/needs.toml`, merged into one catalogue at bootstrap. Each
entry describes a *kind of* need and how readiness is checked; it never
names a company or a product (lex-soft rule: mechanism, not policy).

```toml
[[need]]
id        = "social-publishing"
kind      = "marketing"          # infra | marketing | payments | domain | comms | analytics | legal
summary   = "publish posts on a social network on the company's behalf"
owner     = "founder"            # who must make it exist: founder | company
grant     = "allow_publishing"   # operator-profile grant it requires, or ""
credential = "PUBLISH_TOKEN"     # env var NAME on the runner machine; never a value
adapter   = "publishing"         # providers.<adapter>.kind in the profile, or ""
probe     = "env"                # how readiness is checked: env | adapter | http:<url-env> | founder
tools     = ["publish_content"]  # tools that stay disarmed until ready
```

Packs and the needs they contribute:

- `core`: `model-endpoint` (probe: the existing preflight), `vcs` (adapter github).
- `infra`: `hosting` (adapter hetzner, grant allow_real_deploy, credential
  HETZNER_TOKEN, tools deploy_hetzner), `domain` (owner founder, probe founder),
  `tls` (owner company, ready when hosting is).
- `content`/marketing: `social-publishing` (above), `email-sending`
  (credential EMAIL_API_KEY), `analytics` (credential ANALYTICS_WRITE_KEY).
- `payments`: `payment-rail` (adapter x402|stripe, grant allow_real_money,
  probe adapter).
- `legal` (always present): `brand-line` ("this company is a product line of
  the operator's legal entity", owner founder, probe founder),
  `terms-and-privacy` (owner company, probe founder: the founder confirms).

### 2. The founding plan names the company's needs

The `founder` role emits, next to the budget table, one fenced block:

    ```toml needs
    [[need]]
    id = "hosting"
    why = "the API must be reachable by paying users"
    required_by = "iteration-2"     # iteration-N | launch
    provider = "hetzner"            # optional: names the adapter kind
    ```

`bin/check_founding_plan.py` gains `checkable:needs-declared`: every entry
resolves to a catalogue id; every catalogue need whose `tools` the company's
role packs would use is declared (a plan that staffs `content_creator` but
declares no `social-publishing` fails the gate); a `legal` need is always
declared. The approved plan's needs are stored on the company row
(`company_needs` table: id, why, required_by, provider) by
`attention_resolve_cmd` when the founder approves.

### 3. Readiness is computed on the runner machine, never declared

`bin/check-company-env.sh` gains a needs section: for each declared need,
evaluate the catalogue probe against the operator profile and the
environment and print one state:

| state | meaning | founder action shown |
|---|---|---|
| `ready` | adapter declared, grant on, credential set, probe ok | none |
| `no-adapter` | profile declares no `providers.<adapter>` | declare it in the profile |
| `grant-off` | profile grant is false | flip `grants.<grant> = true` |
| `missing-credential` | env var unset on the runner machine | set `<VAR>` on the runner machine |
| `founder-action` | probe = founder and not confirmed | confirm in the dashboard (board decision) |
| `not-yet-required` | required_by is later than the next iteration | none |

The preflight refuses to start an iteration whose `required_by` has arrived
while a need is not ready (same rule as today's model endpoint: fail before
a token is spent), unless `LOOM_SKIP_PREFLIGHT=1`.

The cloud runner reports the table as a `needs_status` event (like
`consortium_status`); the dashboard renders a **Checklist** section on the
company page: need, kind, owner, state, and the exact founder action. The
cloud only ever sees variable names and states.

### Gating during a run

A sprint whose node would use a tool of a not-ready need parks the company
with an attention item (`kind = need`, the need id and the action), exactly
as the founding plan parks it; the runner turns it into a board decision
("hosting is not ready: set HETZNER_TOKEN on the runner and turn on
allow_real_deploy; answer yes when done"), re-evaluates readiness on yes,
and resumes. `founder`-probe needs (brand line, domain bought) are confirmed
the same way: the board decision *is* the confirmation, recorded with the
resolver id.

## Non-goals

No credential value ever leaves the runner machine or enters loom's DB, the
trail, or the cloud. No need auto-creates an account anywhere. Grants stay
off by default. lex-loom is public: no operator's real needs, hosts or
variable values in examples, only the catalogue shapes.

## Sequencing (each step demoable offline)

1. Catalogue files + loader (`src/needs.lex`: parse, merge, validate ids
   unique, tools known) + `checkable:needs-declared` in the plan checker +
   `company_needs` persisted on approval. Demo: `demo/nl1-needs-declared.sh`
   (a plan without the block fails; with an unknown id fails; valid passes
   and the rows exist). Extend `demo/fp1-founding-plan-roundtrip.sh`.
2. Readiness in `check-company-env.sh` + `needs_status` event in
   `bin/cloud-company-runner.sh` + dashboard Checklist (loom-cloud
   `web/src/components/NeedsChecklist.tsx`, rendered from the newest
   `needs_status` event; guidance card names the first blocking need).
   Demo: profile variants → expected states (extend `demo/prof1`).
3. Tool gating + parking: `role_tools` consults the readiness table; a
   not-ready tool call parks with an attention item; runner decision loop
   handles `kind = need` (generalise the founding loop). Demo:
   `demo/nl2-need-parks-and-resumes.sh` with a fake publish need.

## Toolchain notes for whoever builds this

- `lex fmt` deletes comments inside fn bodies and after variant types
  (lex-lang#755): put comments above functions; run `lex fmt --check` and
  `lex check --strict` on every touched file; CI runs both plus `lex test`
  with the full effect row.
- The full effect row for running anything in `src/`:
  `approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,stream,time,vcs`.
- Local `lex test` needs node 25 first on PATH (default since 2026-09-10).
- Provider selection is a named decision (#427); the preflight reads it from
  `src/main.lex provider_cmd`. Follow the same pattern: readiness is read
  from the runtime, never mirrored in shell.
