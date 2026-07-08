---
name: create-company
description: "Interactively build a valid company.toml for lex-loom, then scaffold and optionally launch the company. Use when the user wants to start a new loom company/product but hasn't written a company.toml yet, or asks things like 'how do I start a company', 'set up a new product', 'create a company config'."
when_to_use: "When working in the lex-loom repo and the user wants to configure and launch a new company, and no company.toml already exists for it (if one exists, read/edit it directly instead of re-interviewing)."
---

# create-company

Guides a user through **every decision `company.toml` needs**, asking only
what's necessary (skip anything with a sane default and just state the
default), then writes the file and validates it with a real, free,
deterministic dry run — never guesses field values on the user's behalf.

Full schema reference: `docs/design/company-manifest.md`. Worked example:
`examples/linksnap.company.toml`. Vetted paths live under `paths/<name>/` —
**always re-check that directory** for the current list rather than trusting
a memorized one (new paths get added over time).

## Before asking anything

1. Read `docs/design/company-manifest.md` if you haven't already this session — the field list may have changed since this skill was written.
2. `ls paths/` to get the CURRENT list of vetted stack paths. Only these are valid for `[stack].path` — the bootstrap will hard-reject anything else.
3. Check whether a `company.toml` already exists for this product (ask the user, or search `examples/*.toml` / their stated workspace). If one exists, offer to read and edit it instead of starting over.

## What to ask (use the AskUserQuestion tool — do not silently assume)

Ask in this order; each answer can make later questions unnecessary.

1. **Identity** — a short id (lowercase, hyphenated, becomes the workspace dir name and `COMPANY_ID`) and a one-paragraph mission. The mission is the single highest-leverage input: it becomes the Architect's entire brief, so push for specifics (what the product actually does, the concrete first feature, not a vague goal). Bad: "build a SaaS tool." Good: linksnap's actual mission in `examples/linksnap.company.toml`.

2. **Stack path** — show the user the CURRENT contents of `paths/` (from your `ls` above) with a one-line description of when to pick each (read each skeleton's own comments if unsure — `app.py`'s docstring in each path explains its trade-off, e.g. python-flask vs python-fastapi). If the user's product doesn't fit any existing path, say so plainly — don't force a bad fit; that's a real gap to flag (point at issue #92), not something to paper over.

3. **Model** — default `glm-5.2` unless the user has a preference or you know a specific model is degraded right now (check recent conversation context / logs before defaulting blindly).

4. **Budget** (`policy.budget_eur`) — ask directly: "what's the estimated-spend ceiling before the company should stop?" This maps to a `spend ge N.00` stop condition. Be upfront that this is a **rough proxy, not a real billing figure** (see `docs/design/company-manifest.md`'s cost-ledger caveat) — so the number should have margin, not be treated as a hard financial guarantee.

5. **Max iterations** (`policy.max_iterations`) — default 12 (matches every reference run this session) unless the user wants tighter/looser.

6. **Role packs** (`roles.packs`) — ask what the company needs beyond core engineering: does it need marketing (`brand_strategist`/`copywriter`/`content_creator`/`seo_specialist`)? Finance (pricing/budget)? Legal (ToS/privacy draft)? Don't default to "everything" — a pure internal tool needs none of these; a product going to real paying users usually needs finance + legal at minimum. State plainly that finance/legal are prose-drafting roles only — legal output always carries a mandatory human-review disclaimer, never a final legal document (see `docs/design/company-manifest.md`).

7. **Infra / repo** (`infra.*`) — these are **declared-intent, not yet enforced** (see the manifest doc's field-status table): hosting/domain are recorded but not deployed; `infra.repo` only becomes a real GitHub repo if the user later runs the bootstrap with `GITHUB_PUBLISH=1`. Say this explicitly so the user doesn't think setting `infra.repo` publishes anything by itself. Ask for the repo string in `github:org/name` form if they want it recorded; otherwise leave blank.

8. **Human gates** (`policy.human_gates`) — default `["payments", "go-public", "app-store"]` (the standing loom policy: money and legal-identity actions are never autonomous). Only change this if the user explicitly wants to loosen or add to it, and if they want to loosen a money/legal gate, push back once and confirm they mean it.

## Writing the file

- Follow the exact structure and field-status commenting style of `examples/linksnap.company.toml` (every field commented `[enforced]` or `[declared-intent]`) — this is what makes the manifest honest, don't drop it.
- Write to `examples/<id>.company.toml` unless the user names a different path.
- Show the user the full file before treating it as final.

## Validate before declaring done

Always run the bootstrap in dry-run mode — it's free and deterministic, and it's the actual source of truth for whether the manifest is valid:

```bash
bin/bootstrap-company.sh examples/<id>.company.toml --no-run
```

- If it fails (e.g. unknown `[stack].path`), read the error, fix the manifest, retry — don't hand-wave a fix without re-running it.
- On success, show the user the resolved run command it prints and the scaffolded file tree (`find $LOOM_WORKSPACE/<id> -type f -not -path '*/.git/*'`).

## Launching (only if the user explicitly asks to start it now)

Real launches cost money and run for a while — never start one without the user explicitly saying so in this turn. If they do:

```bash
export OPENCODE_API_KEY=$(cat ~/.credentials/opencode/key | tr -d '\n')   # bootstrap also auto-loads this
bin/bootstrap-company.sh examples/<id>.company.toml
```

This runs in the foreground by default; for anything beyond a quick smoke test, background it and monitor the log/DB the way established earlier in this session (grep `[company]` lines, check `company_iterations`/`companies` tables, watch for launch-node health) rather than blocking the conversation on it.

## What NOT to do

- Don't invent field values the user didn't state (mission specifics, budget, repo name) — ask, or state you're using a named default and let them object.
- Don't pick a stack path for the user without explaining the trade-off — this is a real per-product decision (see the flask-vs-fastapi discussion in the manifest doc), not a rubber stamp.
- Don't claim `infra.hosting`/`infra.repo` are live just because they're in the file — they're declared-intent until the bootstrap/deploy wiring for them exists.
- Don't skip the `--no-run` validation step — an unvalidated manifest is not a finished manifest.
