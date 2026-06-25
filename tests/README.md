# lex-loom task ladder tests

Runs portfolio product sprints in both Lex and Python in parallel, comparing
implementation quality, QA pass rates, and token usage.

## Quick start

### 1. Start the stack

```bash
cd agents/lex-loom

# With local Ollama (qwen3-coder:30b via LiteLLM proxy):
cd litellm && docker compose up -d && cd ..
docker compose up -d --build

# Or with Anthropic:
ANTHROPIC_API_KEY=sk-... docker compose up -d --build
```

### 2. Verify loom is ready

```bash
curl http://localhost:8880/
```

### 3. (Optional) Connect to loom-cloud

Register a runner at [loom.lexlang.org](https://loom.lexlang.org) → Settings → Runners → New Token, then:

```bash
export LOOM_RUNNER_TOKEN=<your-runner-token>
export LOOM_SERVER=https://loom.lexlang.org

# This publishes all 11 agents (pm, architect, build, py_build, qa, py_qa,
# devops, docs, security, demo, scribe) to loom-cloud so the dashboard shows them.
# run-tasks.sh does this automatically when LOOM_RUNNER_TOKEN is set.
```

### 4. Run sprint 1 (portfolio static site)

```bash
MODEL=qwen3-coder:30b ./tests/run-tasks.sh tests/tasks/portfolio-sprint-1.json
```

### 5. Run all sprints

```bash
MODEL=qwen3-coder:30b ./tests/run-tasks.sh tests/tasks/portfolio-sprint-*.json
```

## What each sprint builds

| Sprint | Task | Lex | Python |
|--------|------|-----|--------|
| portfolio-s1 | Static site: About, Projects, Contact on port 8080 | `build` + `qa` | `py_build` + `py_qa` |
| portfolio-s2 | Blog engine: markdown → HTML, /blog listing + /blog/:slug | `build` + `qa` | `py_build` + `py_qa` |

## Reading results

After each sprint, the runner prints a summary table:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Sprint                         Status       QA Verdicts                    Notes
──────────────────────────────────────────────────────
portfolio-s1                   complete     py=PASS lex=PASS               bounces=1
portfolio-s2                   complete     py=PASS lex=FAIL               bounces=3
```

Trail DBs are written to the working directory as `<sprint-id>-trail.db`.
Inspect with:

```bash
sqlite3 portfolio-s1-trail.db "SELECT event_kind, data_json FROM traces ORDER BY ts;"
```

If `LOOM_RUNNER_TOKEN` is set, the full trail is also visible at:
`https://loom.lexlang.org` → Sprints → `<sprint-id>`

## Publishing agents manually

```bash
cd loom-cloud
LOOM_RUNNER_TOKEN=<token> bin/loom-publish agents/portfolio.yaml
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LOOM_URL` | `http://localhost:8880` | Local loom server |
| `LOOM_SERVER` | `https://loom.lexlang.org` | loom-cloud URL |
| `LOOM_RUNNER_TOKEN` | (unset) | Runner token; enables cloud upload + agent publish |
| `MODEL` | `qwen3-coder:30b` | Model passed in sprint request |
| `LITELLM_BASE_URL` | `http://localhost:4000` | LiteLLM proxy for local models |
