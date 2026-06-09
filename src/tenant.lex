# tenant.lex — sprint registration and multi-tenancy via lex-soft registry.
#
# Each sprint registers itself as an agent in lex-soft's agents table.
# The sprint_id is the agent_id; the registry provides liveness tracking
# (heartbeat), status, and peer discovery for external agents that want
# to interact with a running sprint.
#
# Multi-tenancy model:
#   - One DB per deployment (shared across sprints).
#   - sprint_id is the tenant key — all loom tables use it as a partition key.
#   - lex-soft's agents table tracks which sprints are active.
#   - A sprint is "active" from register() to complete()/fail().
#
# This replaces lex-hub (a Rust-only JWT gateway) for the Lex layer.
# lex-hub can sit in front of the lex-soft platform server for
# cross-org HTTP isolation when needed.

import "std.str" as str

import "std.list" as list

import "lex-orm/src/connection" as conn

import "./agent/registry" as registry

fn loom_kind() -> Str {
  "loom-sprint"
}

fn loom_inbox_url(base_url :: Str, sprint_id :: Str) -> Str {
  str.join([base_url, "/sprints/", sprint_id, "/a2a"], "")
}

# Register a sprint as an active agent in the registry.
# inbox_url is the A2A endpoint for this sprint (served by server/a2a.lex).
# Pass "" for inbox_url in single-process mode.
fn register(db :: conn.ConnDb, sprint_id :: Str, request :: Str, inbox_url :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  let capabilities := ["start", "status", "advance", "trail", "digest"]
  registry.register(db, sprint_id, loom_kind(), sprint_id, inbox_url, capabilities)
}

# Mark the sprint as complete in the registry.
fn complete(db :: conn.ConnDb, sprint_id :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  registry.set_status(db, sprint_id, "complete")
}

# Mark the sprint as failed.
fn fail(db :: conn.ConnDb, sprint_id :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  registry.set_status(db, sprint_id, "failed")
}

# Heartbeat — called periodically by run_sprint to signal liveness.
fn heartbeat(db :: conn.ConnDb, sprint_id :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  registry.heartbeat(db, sprint_id)
}

# List all currently active sprints.
fn active_sprints(db :: conn.ConnDb) -> [sql, fs_read] List[registry.AgentRef] {
  match registry.find_by_kind(db, loom_kind()) {
    Err(_) => [],
    Ok(refs) => list.fold(refs, [], fn (acc :: List[registry.AgentRef], r :: registry.AgentRef) -> List[registry.AgentRef] {
      if r.status == "active" {
        list.concat(acc, [r])
      } else {
        acc
      }
    }),
  }
}

# Look up a single sprint by id.
fn find(db :: conn.ConnDb, sprint_id :: Str) -> [sql, fs_read] Option[registry.AgentRef] {
  match registry.find_by_id(db, sprint_id) {
    Err(_) => None,
    Ok(None) => None,
    Ok(Some(ref)) => Some(ref),
  }
}

