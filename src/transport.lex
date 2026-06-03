# transport.lex — the four communication planes (§4).
#
# Plane 1  Control/work    — in-process for M2; lex-jobs queue in M5.
# Plane 2  Inter-agent     — A2A via lex-soft/a2a (used by roles that
#                            call peer agents).
# Plane 3  Artifacts       — content-hash store in SQLite for M2;
#                            lex-vcs branch per sprint in M5.
# Plane 4  Trail/audit     — append-only via lex-soft/trace.
#
# Callers import only this module; swapping a plane in M5 stays local here.

import "std.sql"    as sql
import "std.str"    as str
import "std.list"   as list
import "std.time"   as time
import "std.crypto" as crypto

import "lex-soft/src/trace" as trace
import "lex-soft/src/a2a"   as a2a

# ── Plane 4: Trail ────────────────────────────────────────────────────────────
#
# Every graph proposal, gate decision, and phase transition is appended here.
# event_kind values used by loom:
#   graph_proposed   graph_validated   graph_rejected
#   node_started     node_accepted     node_denied     node_failed
#   phase_advanced   sprint_complete

fn trail(db :: Db, sprint_id :: Str, event_kind :: Str, data :: Str) -> [sql, fs_write, time, random, crypto] Unit {
  trace.record(db, sprint_id, sprint_id, event_kind, data)
}

# ── Plane 3: Artifacts ────────────────────────────────────────────────────────
#
# Node output is stored by content hash; handoffs carry the hash, not the
# payload. In M2 the "hash" is a random hex string — content-addressed
# storage over lex-vcs lands in M5.

type ArtifactRow = { content :: Str }

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

fn artifact_put(db :: Db, sprint_id :: Str, node_id :: Str, content :: Str) -> [sql, fs_write, time, random, crypto] Result[Str, Str] {
  let hash := crypto.random_str_hex(16)
  let now  := time.now_str()
  let q := str.join([
    "INSERT INTO artifacts (hash, sprint_id, node_id, content, created_at) VALUES ('",
    sq(hash), "', '", sq(sprint_id), "', '", sq(node_id), "', '", sq(content), "', '", now, "')"
  ], "")
  match sql.exec(db, q, []) {
    Err(e) => Err(e.message),
    Ok(_)  => Ok(hash),
  }
}

fn artifact_get(db :: Db, hash :: Str) -> [sql, fs_read] Result[Str, Str] {
  let q := str.join(["SELECT content FROM artifacts WHERE hash='", sq(hash), "'"], "")
  let rows :: Result[List[ArtifactRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(e)  => Err(e.message),
    Ok(rs)  => match list.head(rs) {
      None    => Err(str.concat("artifact not found: ", hash)),
      Some(r) => Ok(r.content),
    },
  }
}

# ── Plane 2: Inter-agent A2A ──────────────────────────────────────────────────
#
# Used by roles that need to call a peer (e.g. Architect calling an external
# design agent). For in-process M2 nodes this is rarely needed — the
# orchestrator invokes nodes directly.

fn send_a2a(db :: Db, from_id :: Str, to_id :: Str, topic :: Str, payload :: Str) -> [sql, fs_read, net, crypto, random] Result[Unit, Str] {
  a2a.send(db, from_id, to_id, topic, payload)
}

# ── Plane 1: Control / work ───────────────────────────────────────────────────
#
# In M2 the "job" runs synchronously in the caller's process.
# The type here is the seam; M5 replaces the body with lex-jobs enqueue/await.

type JobInput = {
  sprint_id :: Str,
  node_id   :: Str,
  input_ref :: Str,    # artifact hash of upstream output; "" if none
  input_text :: Str,   # resolved content of input_ref (fetched before call)
}

type JobOutcome =
  | JobDone(Str)     # artifact hash of this node's output
  | JobDenied(Str)   # gate denied — reason
  | JobFailed(Str)   # execution error

# Record a phase transition in the phase_transitions table.
fn record_transition(db :: Db, sprint_id :: Str, from_phase :: Str, to_phase :: Str, evidence :: Str) -> [sql, fs_write, time, random, crypto] Result[Unit, Str] {
  let id  := crypto.random_str_hex(16)
  let now := time.now_str()
  let q := str.join([
    "INSERT INTO phase_transitions (id, sprint_id, from_phase, to_phase, evidence, ts) VALUES ('",
    sq(id), "', '", sq(sprint_id), "', '", sq(from_phase), "', '", sq(to_phase), "', '", sq(evidence), "', '", now, "')"
  ], "")
  match sql.exec(db, q, []) {
    Err(e) => Err(e.message),
    Ok(_)  => Ok(()),
  }
}
