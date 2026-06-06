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

import "lex-trail/src/log" as tlog

import "lex-trail/src/emit" as emit

import "lex-trail/src/event" as ev

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

