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

The estimate below was made against `kimi-k2.7-code` on the `python-fastapi`
path, the stack the prior runs used. FormCo now builds in **Lex on lex-web**
(`lex-web-api` path, 2026-09-12): the gates are the same except that Lex
build nodes are gated by a real `lex check` (`spec compiles`) instead of
`check_imports.py`, and no Lex-path company has run end to end before, so
the first iterations will also be finding the Lex build agent's limits. The manifest now names `qwen3.8:27b-mlx`, served locally through
LiteLLM (2026-09-12): no provider spend, but a smaller model, so expect
more gate bounces per node and treat the iteration counts as a floor.

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

## Local first: no domain, no host (the way to start)

A founder without a hostname or a VM can still run this company end to end.
With `LOOM_ENV` unset the architect is **forbidden** a deploy node, so every
graph ends at `launch` -- the node that boots the product on a port and curls
it for real. That is a genuine finish line: the product runs, answers a real
request, and its own suite passes.

Use `examples/formco-local.company.toml`. It is the same company with two
differences: it declares no `[needs]`, and its mission says the run is local.
That matters -- on the first run (2026-09-12) the deploy needs were declared
at iteration 5 and parked a company whose graphs had never contained a deploy
node at all.

    LOOM_SERVER=https://loom.lexlang.org LOOM_RUNNER_TOKEN=<key> bin/cloud-company-runner.sh
    # dashboard: Companies -> New company -> kind `company` -> paste
    # examples/formco-local.company.toml

### Trying the product yourself, while it builds

Each iteration's accepted files land in the company's workspace under
`$LOOM_WORKSPACE/cloud-<uuid>/formcolocal/`. To run one yourself, from that
directory, on a port nothing else holds:

    lsof -ti :8123 || PORT=8123 lex run --allow-effects \
      env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,approval,stream,vcs \
      main.lex main
    curl -i localhost:8123/health
    curl -i -d 'name=Ada&email=ada@example.eu' 'localhost:8123/submit?next=/thanks'

That effect row is not decoration: a Lex program needs the union of every
effect its imports declare, and lex-web reaches `crypto` and `random` inside
its own request-id middleware. A shorter row lets the process start and then
fails every request -- which reads as a dead endpoint on a server that is
plainly running. `demo/lw1-lex-web-path-roundtrip.sh` pins it.

### When a host does appear

Switch to `examples/formco.company.toml` (which declares `DEPLOY_DOMAIN@5`
and `HETZNER_HOST@5`), put the values in `~/.loom/needs.env`, set `LOOM_ENV`
to something other than `local`, and flip `grants.allow_real_deploy` in
`~/.loom/profile.toml`. Only then is a deploy node planned, and only then does
the operable contract's `reachable-over-tls` criterion become assessable.

## How to start Run A (#453)

Through the cloud runner, from the dashboard, as a founder would. Nothing
below is a CLI run of the company; the CLI is for the checks.

### On the runner machine, once

1. A provider that serves the manifest's model and returns tool calls. The
   default route is LiteLLM at `localhost:4000`; name another with
   `LOOM_PROVIDER=opencode|ollama|...`. Prove it before a token is spent:

       LOOM_PROVIDER=<provider> bin/check-company-env.sh examples/formco.company.toml

   Every line must be `ok`. The check makes one real tool-calling request;
   a model that lists but does not call tools fails every build node.

2. The needs file. Iteration 5 parks on `DEPLOY_DOMAIN` and `HETZNER_HOST`
   (`[needs]` in the manifest). The runner reads them from
   `~/.loom/needs.env` (or `LOOM_NEEDS_FILE`) before every bootstrap, so
   they can be written while the company is parked -- or now:

       mkdir -p ~/.loom
       printf 'DEPLOY_DOMAIN=<hostname pointed at the box>\nHETZNER_HOST=<ip>\n' >> ~/.loom/needs.env

   Values never leave this machine; the board decision carries the NAME.

3. The runner, with a key from the dashboard's Runners page:

       LOOM_SERVER=https://loom.lexlang.org LOOM_RUNNER_TOKEN=<key> bin/cloud-company-runner.sh

### In the dashboard

4. Companies -> New company -> paste `examples/formco.company.toml` ->
   Queue company. The runner claims it on its next poll.
5. Answer the board decisions as they appear on the card, in order:
   the founding plan (budget in the question; `budget_eur=N` in the reason
   changes it), then each need at iteration 5, then the operable contract's
   human criterion.

### What to watch, and what counts as a finding

- `iteration_nodes`, `company_backlog` and the runner's `role_kinds` are
  all reported over the wire for the first time on a real company. Any of
  the three empty after the first poll is a finding, not a display bug.
- Every gate refusal is expected the first time through six new roles; the
  run report records the node, the gate's reason, and whether the role's
  output was usable or merely present.
- A need that parks twice with the same name means the value did not reach
  the runner: check the file, not the company.

The written report goes in `docs/`, the fixes as issues against #435 or
#445, each citing the node and the reason.
