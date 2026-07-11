# Company manifest (`company.toml`) + deterministic bootstrap — #91

Status: v0 landed 2026-07-08. The keystone that turns "run a company" from a
pile of env vars into one declarative, reproducible artifact.

## Principle

Repo layout, chosen stack, infra, budget and policy are **plumbing, not
judgment** — decided once, up front, from config, by a deterministic script.
The LLM agents never decide structure; they only fill in features inside a
pre-decided skeleton. loom's runtime stays env-var driven and unchanged;
`bin/bootstrap-company.sh` is the *only* thing that reads `company.toml`.

```
company.toml  →  bin/bootstrap-company.sh  →  $LOOM_WORKSPACE/<id>/   →  bin/run-company.sh
 (declarative)     (deterministic scaffold)    (own git repo + skeleton)   (agents fill it in)
```

## Usage

```bash
bin/bootstrap-company.sh examples/linksnap.company.toml            # scaffold + run
bin/bootstrap-company.sh examples/linksnap.company.toml --no-run   # scaffold only (free, deterministic)
```

`--no-run` scaffolds the workspace, skeleton, and git repo and prints the
resolved run command without spending anything — safe for inspection/tests.

## What the bootstrap does (all deterministic)

1. Parses `company.toml` (python `tomllib`).
2. Validates `[stack].path` is a **vetted path** (a skeleton dir under `paths/`).
3. Creates `$LOOM_WORKSPACE/<id>/` (default `~/loom-companies`, **outside** the loom repo).
4. Lays down the path skeleton into empty slots only — never clobbers existing
   product code (idempotent; re-bootstrapping a live company is safe).
5. Writes the company's own `company.toml` copy + a generated `README.md`.
6. `git init` + initial commit; `gh repo create` (private) only if `GITHUB_PUBLISH=1`.
7. Maps `[policy]` → `run-company.sh` env vars and hands off.

## Field reference & status

Each field is `enforced` (acted on today) or `declared-intent` (recorded now,
realized as bootstrap/deploy/golden-path wiring lands — see #92, #93).

| Field | Maps to | Status |
|---|---|---|
| `[identity].id` | `COMPANY_ID` + workspace dir name | **enforced** |
| `[identity].mission` | `GOAL` | **enforced** |
| `[stack].path` | skeleton selection (+ tech-specialist agents in #92) | **enforced** (must be a vetted path) |
| `[stack].model` | `MODEL` | **enforced** |
| `[policy].max_iterations` | `MAX_ITERATIONS` | **enforced** |
| `[policy].budget_eur` | `STOP_WHEN="spend ge N.00"` (rough estimate guard; EUR≈USD) | **enforced** |
| `[monitoring].checks=["liveness"]` | OP1 liveness | **enforced** (error_rate/usage declared-intent) |
| `[infra].repo` | `gh repo create` | declared-intent (only with `GITHUB_PUBLISH=1`) |
| `[infra].hosting` / `.domain` | deploy target | declared-intent (needs deploy path) |
| `[roles].packs` | active function packs | **enforced** for finance/legal/distribution roles (#92 slice 1, shipped); declared-intent only for stack-specific specialist packs not yet built |
| `[policy].human_gates` | `lex-os-manifest` grants | declared-intent |

## Vetted paths (`paths/<name>/`)

A path is a skeleton dir the bootstrap copies in — an entry point
(PORT-aware, `/health`), dependency manifest, a `Dockerfile` (`COPY . .` so
it can't drift out of sync with the real file layout — the earlier devops
failure mode), and a passing skeleton test. Three exist today, all proven
to boot and pass their skeleton test:

| Path | Pick when |
|---|---|
| **`python-flask`** | a genuinely minimal server — no request/response validation needed. This was picked for `linksnap` (3 thin JSON endpoints), matching `py_build`'s own existing convention: *"flask for simple servers, fastapi for REST APIs with validation."* |
| **`python-fastapi`** | anything with real input validation (Pydantic models catch bad input before your handler runs), or that benefits from free OpenAPI/Swagger docs at `/docs` — the common case for a documented public API a developer integrates against, e.g. a paid micro-API. |
| **`lex-x402-api`** | a metered API that charges per call via the x402 protocol — the only real, tested payment-*receiving* rail loom has (`lex-x402`/`lex-guard` are Lex-only packages, so the priced endpoint has to be a Lex server, not Python, to call the real protocol code rather than reimplement it). Ships a pre-written `payments.lex` gate (build agents call it, never hand-roll the handshake) — proven end-to-end in a real Docker build: `/health` returns 200, an unpaid call to the priced route returns a real 402 with a valid base64 `PAYMENT-REQUIRED` challenge header. |

Adding a path for another stack (TS-API, Next-PWA, RN-web) + its specialist
agents is the remaining part of #92.

Deployment for any path is still a manual, one-time human step — see
`devops`'s prompt (`src/roles.lex`), which now produces BOTH a Google Cloud
Run deploy command and a Hetzner (Docker Compose + Caddy) deploy path, so
whichever a human picks is copy-paste, not a from-scratch decision. Loom
does not push to the cloud itself (#92/#93 gap, still open).

## Not in this slice (honest scope)

- Build agents **reading and extending** the skeleton (vs building from scratch)
  is #92 — the skeleton is laid down and git-tracked, but the agents don't yet
  consume it.
- `[infra]` realization (real Hetzner deploy) is declared-intent until deploy
  wiring lands. `[roles].packs` for finance/legal/distribution already work
  (#92 slice 1); only stack-specific specialist packs remain declared-intent.
