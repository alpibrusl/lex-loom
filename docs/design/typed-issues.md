# Typed issues: a lex company's backlog with a verifiable definition of done

lex-loom#521 · binding half of lex-lang#949 · slice 1

## What changed

A backlog item used to be a goal string with a `status` column somebody
sets. For a **lex company** (product and operations in Lex) it is now the
projection of a **typed issue** in the company's own lex-vcs store: a title,
an acceptance oracle of a declared shape, and an id that is the hash of its
content. "Done" is a verdict the `lex` gate records at the head — an
`IssueVerified` attestation — never a status the runner or a person flips.

```
cx artifact ──parse──▶ Proposal{goal, theme, kind?, example?, api?}
                            │  shape rule (src/issues.lex)
                            ▼
              lex issue create --store <company store> --shape …   ──▶ issue_id
                            │  company_backlog.issue_id (projection)
                            ▼
iteration passes ─▶ lex publish <sealed source> --intent-issue <id>  (ops link back)
                            ▼
                    lex issue verify <id>  ──▶ verified | failed | inconclusive
                            │  trail: issue_realized, issue_verified
                            ▼
                    verified ⇒ backlog item done (the ONLY path to "done")
```

## Where things live

| Piece | Location |
|---|---|
| Shape rule, proposal parsing, toolchain calls | `src/issues.lex` (leaf module; `examples {}` pin the pure halves) |
| Backlog projection (`issue_id` column) | `src/company.lex` `BacklogItem`, `append_backlog_issue`; migration in `src/migrate.lex` |
| Queueing (cx + strategist) and realization | `src/company_runner.lex` `queue_typed`, `iteration_issue`, `realize_iteration_issue` |
| The cx prompt's fence | `src/roles.lex` `cx_system_prompt` (typed fields optional) |
| Company store | `$LOOM_WORKSPACE/<company_id>/.lex-store` (bootstrap exports `LOOM_WORKSPACE`; unset ⇒ nothing is typed, nothing written) |

## Role → shape (this slice)

| Source | Proposal | Shape | Machine verdict? |
|---|---|---|---|
| cx | has `example` (one call and the result users expect) | `failing_example` | yes — the example runs at the head |
| cx | has `api` entries (`name:(params) -> Ret`) | `typed_delta` | yes — signatures compared like-with-like |
| cx | neither | `free_form` | no — human-closed; `inconclusive` on the trail |
| strategist `add` | goal text | `free_form` | no |
| iteration goal not from the backlog (mission, revise) | goal text | `free_form` | no — but the ops still link to it |

Every passing Lex iteration realizes *an* issue, so the op-log carries
provenance for all work; only the typed ones get a verdict. A typing failure
(no toolchain, malformed api entry) never drops a request: the goal queues
untyped with `issue_create_failed` on the trail.

## Trail events

`issue_created {iter, source, issue_id, shape}` ·
`issue_create_failed {iter, source, shape, reason}` ·
`issue_realized {iter, issue_id, head_op, modules}` ·
`issue_verified {iter, issue_id, verdict, detail}` ·
`issue_realize_failed {iter, issue_id, reason}` ·
`issue_realize_skipped {iter, reason}`. `backlog_added` now also carries
`issue_id` and `shape` when typed.

## Limits, deliberately

- **Primary source only.** The sealed build is published by its primary
  file (`main.lex` › `server.lex` › first by name; tests excluded). A build
  with several source modules publishes with `modules > 1` on the trail and
  the oracle may report the head unverifiable — multi-module verification is
  lex-lang#942. A package publish needs `lex.toml` + `src/`, which loom's
  work dir doesn't have; staging one is the next slice.
- **No dependency edges yet.** cx proposals carry no `deps`, so nothing is
  `blocked`; the hub's derived board (`/v1/issues`) will show them when a
  later slice pushes the company store (`lex op push`) to vcs.lexlang.org.
- **Toolchain floor.** `lex issue` exists from lex-lang 0.11.48; the JSON
  output and `--intent-issue` this binding reads are 0.11.50 (CI pins it).
- **Non-Lex paths** are untouched: the binding is a no-op, said on the trail.

## Proof

`tests/test_typed_issues.lex`: (1) untyped fallback without a workspace —
both goals queue, `issue_id` empty, reason on the trail; (2) the typed loop
against a real store — `typed_delta` **verified** at the published head, a
wrong expected value **failed** (the example ran), same proposal ⇒ same id.
Sabotage-checked: making the bug's expected value correct fails the test.
`demo/ti1-typed-issues-roundtrip.sh` runs both plus the pure examples.
