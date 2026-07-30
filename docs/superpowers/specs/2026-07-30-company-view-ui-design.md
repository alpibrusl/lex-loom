# Company view for the loom UI

Status: approved. Epic context: the Operate loop v1 work (#118, #145, #147, #148)
gave the Company layer (mission, iterations, backlog, operate-loop incidents/
escalations) real behavior with zero UI — `board_report_cmd` is the only way
to see any of it today. This adds a real UI for it, extending the existing
`ui/` React app rather than building something new.

## Problem

The existing `ui/` app (Dashboard, SprintDetail, Agents pages, backed by
`src/web/server.lex`) is entirely **sprint**-scoped. There is no API or UI
surface for the Company layer at all — a user running a company has to read
`board_report_cmd`'s prose CLI output to know whether anything needs
attention.

## Non-goals

- **Not** a per-company generated product UI. Whatever a company's mission
  produces (an API, a web app, a CLI) is that company's own artifact,
  launched via the existing `launch`/`deploy` roles — unrelated to this
  dashboard. This spec only adds a **link out** to that live product, never
  embeds or generates it.
- **Not** real-time/websocket updates. Matches the existing app's pattern
  (manual refresh only).
- **Not** a rewrite of `board_report_cmd`'s underlying data functions.
  Reuses `company.lex`'s existing formatters directly.

## Backend: two new read-only endpoints

Added to `src/web/server.lex`, alongside the existing `/api/sprints/*` routes.

### `GET /api/companies`

List, for a Company List page (cards).

```json
{ "companies": [
  { "id": "acme", "goal": "...", "stage": "growth", "iterations": 4,
    "open_incidents": 1, "escalated_count": 0, "spend_cents": 1293 }
]}
```

One new query: all `companies` rows, joined with a per-company iteration
count and `oledger.operate_metrics` (already exists) for incident counts.
Everything else below reuses existing `company.lex` functions — this is the
only genuinely new query in the whole feature.

### `GET /api/companies/:id`

Detail, for a Company Detail page.

```json
{
  "id": "acme", "goal": "...", "stage": "growth", "max_iterations": 5,
  "stop_when": "...", "spend_cents": 1293,
  "latest_sprint_id": "acme/iter-4",
  "live_url": "http://localhost:8081",
  "live_status": "up",
  "iterations": [{ "idx": 1, "sprint_id": "acme/iter-1", "status": "success", "goal": "..." }],
  "shipped_summary": "- iter 1: ...",
  "backlog_summary": "...",
  "operate_metrics": { "open_incidents": 1, "resolved_count": 0, "escalated_count": 0,
                        "verified_effects": 0, "hit_rate_pct": 0, "hit_rate_trend": "...",
                        "avg_evidence_cost_milli": 0 },
  "operate_signals": "recent liveness checks... (prose, from operate_section)",
  "escalations": ["...dossier text..."],
  "decisions": ["iter 1: stop — ..."],
  "stage_transitions": ["iter 1: ideation -> sunset"]
}
```

Design principle: **structured fields for anything the UI needs to render as
cards/lists/stats** (ids, counts, the iteration list, `operate_metrics` —
already a clean typed record); **prose strings for sections that
`company.lex` already formats as text** (`shipped_summary`,
`escalation_dossiers_for_company`, `format_decision`,
`format_stage_transition`) — no reformatting logic duplicated.

`live_url`/`live_status` come from the same functions `check_and_record_liveness`
already uses internally (`find_deploy_url`/`find_launch_url`, latest
`liveness` operate signal) — not new logic, just newly exposed.

`latest_sprint_id` is the last iteration's `sprint_id` — lets the frontend
fetch that sprint's graph via the *existing* `/api/sprints/:id/graph`
endpoint with zero backend changes.

## Frontend

Two new pages, mirroring the existing Dashboard/SprintDetail pair:

### `ui/src/pages/Companies.tsx`

Grid of company cards (same visual language as Dashboard's `SprintCard`):
id, goal excerpt, a stage badge (ideation/growth/maintenance/sunset,
color-coded), iteration count, and an incident badge that goes amber/red
when `open_incidents > 0`.

### `ui/src/pages/CompanyDetail.tsx`

- **Product status card** (top, prominent): live/down badge from
  `live_status`, the product URL (`live_url`) as a clickable external link,
  last-checked time and latency from the underlying signal.
- **Latest iteration DAG** (inline, not a link): embeds the *existing*
  `PhaseGraph` component fed by `/api/sprints/${latest_sprint_id}/graph` —
  so the current/most recent agent pipeline is visible at a glance without
  navigating away.
- **Iterations list**: each row (except the latest, already shown above)
  links to the existing `/sprint/:id` route.
- **Operate stat row**: reuses the Dashboard's stat-tile pattern for
  `operate_metrics` (open/resolved/escalated incidents, hit rate).
- **Escalations**: rendered as distinct amber/red cards, not buried in prose
  — these need human attention.
- **Shipped / backlog / decisions / stage transitions**: prose sections,
  same treatment as the existing Digest view's `summary` field.

### Shared component change: sub-loom visibility in `PhaseGraph`

`Node.expand :: Option[Str]` already exists in the graph JSON
(`src/graph.lex`) but the frontend's `GraphNode` type doesn't declare it and
`PhaseGraph.tsx` has no idea it exists — an expand node (a full child sprint,
id `"<parent_id>/<node_id>"`, per `dag_view.lex`) currently renders as an
ordinary box with no way to drill in.

Fix: add `expand?: string` to `GraphNode`; when a node has it, `PhaseGraph`
renders a distinct badge (e.g. "🧩 sub-loom") and links to
`/sprint/${encodeURIComponent(graph.id + '/' + node.id)}` — react-router
decodes the `%2F` back to a literal slash within the single `:id` param, so
the existing `/sprint/:id` route and every `/api/sprints/:id/*` endpoint work
unchanged for the nested id. No new backend endpoint.

Since this lives in the shared component, it benefits the standalone
SprintDetail page too, not just the new inline embed.

### Wiring

- `App.tsx`: add `/companies` and `/company/:id` routes, add a "Companies"
  nav link next to "Agent Pool".
- `types.ts`: add `CompanyStat`, `CompanyDetail`, `OperateMetrics`; add
  `expand?: string` to `GraphNode`.
- `api.ts`: add `getCompanies()`, `getCompanyDetail(id)` — same shape as
  every existing function in the file.

## Data flow

No live/websocket updates. Load once on mount, manual refresh button —
matches the existing Dashboard's pattern exactly (no polling exists
anywhere in this codebase today).

## Testing

- Backend: new Lex test coverage for the two new endpoints against a seeded
  DB — list shape, detail shape, 404 for an unknown id, `live_url`/
  `live_status` present vs. absent (no launch artifact yet).
- Frontend: no existing test suite in `ui/` for any component — consistent
  with that, no new test infra invented here. Manual verification against a
  real company DB (e.g. this session's `operate-flow-test`) is the
  acceptance check.
