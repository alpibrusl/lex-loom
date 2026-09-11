# FormCo, Run A: the build plan and an estimate that matches loom's stack

Status: plan, 2026-09-11. Part of lex-loom#445 (#446). The manifest is
`examples/formco.company.toml`; the contract Run A settles is
`operable-delivery/v1` (#447).

## Why the research estimates do not apply

All three research documents estimated 5–14 engineering days, and all three
assumed a managed stack: Vercel or Fly for hosting, Supabase for the
database, Resend or Postmark for email, a Stripe SDK, Cloudflare Turnstile
for spam, sometimes Redis and WebSockets. loom has none of those. It builds
on `python-fastapi` with the standard library, `flask`/`fastapi`/`jinja2`/
`markdown`/`pytest`; stores in SQLite on disk; deploys to one Hetzner box
behind Caddy; sends email with `smtplib` at most; and every external
credential comes from the founder through a board decision, never from an
agent. So the estimate below is per build node, in iterations, against that
stack -- and it says which nodes cannot finish until the founder provides
something.

The one real data point: run 1's SoftwareCo (a smaller product, `python-
fastapi`, `kimi-k2.7-code`) failed iteration 1 (`launch` ok:false, `py-qa`
FAIL) and passed iteration 2, about 85 minutes of wall-clock for the two.
Expect that shape, not a clean first pass.

## Build nodes (#448), sequential -- one piece each

The architect prompt records, from live evidence, that a build node given
several substantial pieces returns empty output. So one piece per node, each
with its own `py_test_author` sibling and `py_qa`.

| # | node | what lands | gate | waits on the founder? |
|---|---|---|---|---|
| 1 | endpoint | `POST /f/{id}`: form-encoded + JSON, declared-field validation, SQLite store, configured redirect | `check_imports.py` + `py_qa` | no |
| 2 | notification | one email per submission, via the founder's sender; built and tested against a stub | same | **yes -- EMAIL_API_KEY / SMTP (#451)**; nothing sends until answered |
| 3 | spam controls | honeypot, per-endpoint + per-IP rate limit, body and field-count caps | the abuse checker (#449) | no |
| 4 | dashboard + CSV | list, view, export, delete | `check_imports.py` + `py_qa` | no |
| 5 | retention | scheduled deletion past the endpoint's window (short by default), recorded | same, plus `check_restore_performed.py` proves the store is real | no |
| 6 | paid-tier hooks | plan limits enforced in code | same | **yes -- the product itself is the founder's (#89, `monetization_handoff`)** |

## Operable nodes (Run A's contract, #447)

| node | evidence the buyer re-derives | waits on the founder? |
|---|---|---|
| `analytics` | `check_metrics_instrumented.py` -- every stated metric names an event the code emits | no |
| `ops` | `check_restore_performed.py` -- a restore performed into a fresh database; an alert drill to a local sink | no (a real alert channel is a credential, later) |
| `release_manager` | an accepted node: runbook with owners/times, rollback, evidence-backed go/no-go | no |
| `data_protection` | an accepted node: data map matching the code, lawful basis, sub-processors from real config, DPA draft | no |
| `deploy` over TLS | `https://<domain>/healthz` -> `{"ok":true}` (#450, #458) | **yes -- a hostname pointed at the box (#451)** |

## Estimate

| phase | iterations | wall-clock on kimi-k2.7-code | note |
|---|---|---|---|
| build nodes 1, 3, 4, 5 | 3–4 | 3–5 h | run 1's shape: expect one failed iteration |
| build node 2 (email) | 1 | ~1 h, **then parked** | resumes when EMAIL_API_KEY is set |
| build node 6 (paid tier) | 1 | ~1 h, **then parked** | resumes when the product exists |
| operable nodes | 1–2 | 2–3 h | four new roles; expect prompt fixes |
| deploy over TLS | 1 | ~30 min, **then parked** | resumes when the hostname exists |
| **total, autonomous** | **6–8** | **7–10 h** | `max_iterations = 6` in the manifest is deliberate: past it, the founder decides whether to extend |

Token cost is on the operator's OpenCode Go subscription, so the financial
risk is bounded by rate limiting rather than open-ended billing.

## What the founder must provide, and when (#451)

Three things, each a board decision the company parks on, with the exact
action in the question. The company does not guess, does not fake, and does
not proceed.

1. **A transactional email sender** -- before build node 2 can send anything.
2. **The paid product** (Stripe or Lemon Squeezy) -- before node 6 is more
   than limits in code.
3. **A hostname pointed at the Hetzner box** -- before deploy can be over TLS,
   and therefore before the operable contract can settle in full rather than
   at 50%.

Everything else runs without a human.
