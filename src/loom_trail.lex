# loom_trail.lex — Sprint trail backed by lex-trail (§VIII, issue #7).
#
# Wraps lex-trail's content-addressed hash chain around the sprint
# lifecycle. Every phase transition, node outcome, and gate decision
# is appended as a typed lex-trail Event, giving:
#
#   - SHA-256 content-addressed event IDs (tamper-evident)
#   - Parent-pointer chain (replay any sprint from first event)
#   - lex replay compatibility — override individual node events
#   - Attestation API — attach QA verdicts, spec verdicts, etc.
#
# The lex-soft trace table (traces) is kept as a secondary index for
# fast SQL queries; lex-trail is the authoritative audit record.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.io" as io

import "lex-trail/src/log" as tlog

import "lex-trail/src/emit" as emit

import "lex-trail/src/event" as ev

# ── Paths ─────────────────────────────────────────────────────────────────────
#
# A sprint id is not a safe filename. `company.iteration_sprint_id` builds ids
# like `acme-ab12cd/iter-3`, and SQLite will not create a database under a
# directory that does not exist — it returns "unable to open database file".
# Since `run_sprint` swallows that with `Err(_) => None`, every company-run
# sprint has silently had NO lex-trail chain at all. Flattening the separator
# fixes that; plain sprint ids (`sprint-1`) are unaffected, so no existing
# database changes name.
fn slug(sprint_id :: Str) -> Str
  examples {
    slug("sprint-1") => "sprint-1",
    slug("acme-ab12cd/iter-3") => "acme-ab12cd_iter-3",
    slug("a/b/c") => "a_b_c"
  }
{
  str.replace(sprint_id, "/", "_")
}

# Where a sprint's trail database lives.
fn trail_db_path(sprint_id :: Str) -> Str
  examples {
    trail_db_path("sprint-1") => "sprint-1-trail.db",
    trail_db_path("acme/iter-2") => "acme_iter-2-trail.db"
  }
{
  str.concat(slug(sprint_id), "-trail.db")
}

# Where its exported, portable chain lives — the artifact an external verifier
# binds to (see `export_jsonl`).
fn trail_export_path(sprint_id :: Str) -> Str
  examples {
    trail_export_path("sprint-1") => "sprint-1-trail.jsonl",
    trail_export_path("acme/iter-2") => "acme_iter-2-trail.jsonl"
  }
{
  str.concat(slug(sprint_id), "-trail.jsonl")
}

# ── Sprint log lifecycle ──────────────────────────────────────────────────────
# Open a lex-trail Log backed by the same SQLite DB as the sprint.
# Safe to call on every sprint start — init_schema is idempotent.
fn open(db_path :: Str) -> [sql, fs_write] Result[tlog.Log, Str] {
  tlog.open(db_path)
}

fn open_for_sprint(db_path :: Str) -> [sql, fs_write] Result[tlog.Log, Str] {
  open(db_path)
}

# ── Sprint event helpers ──────────────────────────────────────────────────────
#
# Each loom event kind maps to a lex-trail `kind` string + JSON payload.
# The parent chain links events within a sprint in append order.
fn sprint_started(log :: tlog.Log, sprint_id :: Str, request :: Str, parent :: Option[Str]) -> [sql, time] Result[ev.Event, Str] {
  tlog.append(log, "loom.sprint.started", parent, str.join(["{\"sprint_id\":\"", sprint_id, "\",\"request_len\":", int.to_str(str.len(request)), "}"], ""))
}

fn phase_advanced(log :: tlog.Log, sprint_id :: Str, from_phase :: Str, to_phase :: Str, parent :: Option[Str]) -> [sql, time] Result[ev.Event, Str] {
  tlog.append(log, "loom.phase.advanced", parent, str.join(["{\"sprint_id\":\"", sprint_id, "\",\"from\":\"", from_phase, "\",\"to\":\"", to_phase, "\"}"], ""))
}

fn graph_validated(log :: tlog.Log, sprint_id :: Str, graph_id :: Str, node_count :: Int, parent :: Option[Str]) -> [sql, time] Result[ev.Event, Str] {
  tlog.append(log, "loom.graph.validated", parent, str.join(["{\"sprint_id\":\"", sprint_id, "\",\"graph_id\":\"", graph_id, "\",\"nodes\":", int.to_str(node_count), "}"], ""))
}

fn graph_rejected(log :: tlog.Log, sprint_id :: Str, reason :: Str, attempt :: Int, parent :: Option[Str]) -> [sql, time] Result[ev.Event, Str] {
  tlog.append(log, "loom.graph.rejected", parent, str.join(["{\"sprint_id\":\"", sprint_id, "\",\"reason\":\"", reason, "\",\"attempt\":", int.to_str(attempt), "}"], ""))
}

fn node_started(log :: tlog.Log, sprint_id :: Str, node_id :: Str, role :: Str, attempt :: Int, parent :: Option[Str]) -> [sql, time] Result[ev.Event, Str] {
  tlog.append(log, "loom.node.started", parent, str.join(["{\"sprint_id\":\"", sprint_id, "\",\"node\":\"", node_id, "\",\"role\":\"", role, "\",\"attempt\":", int.to_str(attempt), "}"], ""))
}

fn node_accepted(log :: tlog.Log, sprint_id :: Str, node_id :: Str, artifact_hash :: Str, parent :: Option[Str]) -> [sql, time] Result[ev.Event, Str] {
  tlog.append(log, "loom.node.accepted", parent, str.join(["{\"sprint_id\":\"", sprint_id, "\",\"node\":\"", node_id, "\",\"artifact\":\"", artifact_hash, "\"}"], ""))
}

fn node_denied(log :: tlog.Log, sprint_id :: Str, node_id :: Str, gate :: Str, reason :: Str, attempt :: Int, parent :: Option[Str]) -> [sql, time] Result[ev.Event, Str] {
  tlog.append(log, "loom.node.denied", parent, str.join(["{\"sprint_id\":\"", sprint_id, "\",\"node\":\"", node_id, "\",\"gate\":\"", gate, "\",\"reason\":\"", reason, "\",\"attempt\":", int.to_str(attempt), "}"], ""))
}

fn phase_bounced(log :: tlog.Log, sprint_id :: Str, from_phase :: Str, to_phase :: Str, bounce :: Int, parent :: Option[Str]) -> [sql, time] Result[ev.Event, Str] {
  tlog.append(log, "loom.phase.bounced", parent, str.join(["{\"sprint_id\":\"", sprint_id, "\",\"from\":\"", from_phase, "\",\"to\":\"", to_phase, "\",\"bounce\":", int.to_str(bounce), "}"], ""))
}

fn digest_produced(log :: tlog.Log, sprint_id :: Str, spec_count :: Int, parent :: Option[Str]) -> [sql, time] Result[ev.Event, Str] {
  tlog.append(log, "loom.digest.produced", parent, str.join(["{\"sprint_id\":\"", sprint_id, "\",\"tightened_specs\":", int.to_str(spec_count), "}"], ""))
}

fn sprint_complete(log :: tlog.Log, sprint_id :: Str, success :: Bool, fully_sealed :: Bool, demo_ref :: Str, parent :: Option[Str]) -> [sql, time] Result[ev.Event, Str] {
  tlog.append(log, "loom.sprint.complete", parent, str.join(["{\"sprint_id\":\"", sprint_id, "\",\"success\":", if success {
    "true"
  } else {
    "false"
  }, ",\"fully_sealed\":", if fully_sealed {
    "true"
  } else {
    "false"
  }, ",\"demo_ref\":\"", demo_ref, "\"}"], ""))
}

# ── Chain reading ─────────────────────────────────────────────────────────────
# Return all events in the log from a given start time (0 = all).
fn events_since(log :: tlog.Log, since_ms :: Int) -> [sql] Result[List[ev.Event], Str] {
  tlog.range(log, since_ms, 9999999999999)
}

# Return the most recent event in the log.
fn latest(log :: tlog.Log) -> [sql] Option[ev.Event] {
  tlog.head(log)
}

# Extract the parent id from the latest event to chain the next append.
fn latest_id(log :: tlog.Log) -> [sql] Option[Str] {
  match tlog.head(log) {
    None => None,
    Some(e) => Some(e.id),
  }
}

# ── Portable export ───────────────────────────────────────────────────────────
#
# The trail lives in SQLite, which is the right home for it while a sprint is
# running but the wrong thing to hand to a third party: a database file keeps
# changing, so nothing outside can commit to it. `export_jsonl` renders a
# sprint's chain as a standalone, immutable artifact that an external verifier
# (lex-notebooklab) can bind a run record to.
#
# The line format is lex-games' `src/arena/trail_file.lex` — the same wire
# format lex-robot's governed rollouts already emit, so one verifier reads
# both. It is re-implemented in these few lines rather than adding lex-games
# to this repo's dependency closure for a single encoder.
#
# What binds the artifact is the id of its LAST event: `event.compute_id` folds
# each event's parent into it, so the head transitively commits to the whole
# chain. Export is therefore free to be lossy about the container (file name,
# ordering of writes, whitespace) and still be exactly as tamper-evident as the
# database it came from.
fn esc(s :: Str) -> Str {
  str.replace(str.replace(s, "\\", "\\\\"), "\"", "\\\"")
}

fn line_json(e :: ev.Event) -> Str {
  str.join(["{\"id\":\"", e.id, "\",\"kind\":\"", e.kind, "\",\"parent\":\"", match e.parent {
    Some(p) => p,
    None => "",
  }, "\",\"payload_json\":\"", esc(e.payload_json), "\",\"ts_ms\":", int.to_str(e.ts_ms), "}"], "")
}

fn to_jsonl(evs :: List[ev.Event]) -> Str {
  str.join(list.map(evs, line_json), "\n")
}

# Write the whole chain to `path`. Returns the head event id — the value a run
# record should bind as its `trail_head`, and "" for an empty trail.
fn export_jsonl(log :: tlog.Log, path :: Str) -> [sql, io] Result[Str, Str] {
  match events_since(log, 0) {
    Err(e) => Err(e),
    Ok(evs) => match io.write(path, to_jsonl(evs)) {
      Err(e) => Err(e),
      Ok(_) => Ok(match list.head(list.reverse(evs)) {
        None => "",
        Some(last) => last.id,
      }),
    },
  }
}

