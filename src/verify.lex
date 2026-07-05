# verify.lex — independent re-derivation of a sprint's integrity (#47, P0).
#
# "A run is a trail, not a claim." Instead of trusting the trail's stored
# verdicts, this RE-COMPUTES integrity from ground truth: every artifact the
# trail says a node produced is content-addressed (#5 / vcs), so we re-fetch it
# from the content store and confirm sha256(content) == the hash the trail
# referenced. A tampered artifact (or a forged trail entry pointing at content
# that doesn't hash to its id) is caught — the verdict is recomputed, not
# asserted. This is the loom-side foundation for the governed-agent kernel's
# independent verifier (#47): it needs no trust in loom's own bookkeeping.

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "std.crypto" as crypto

import "std.int" as int

import "std.vcs" as vcs

import "lex-orm/src/connection" as conn

import "lex-schema/json_value" as jv

import "std.io" as io

import "std.process" as proc

import "./gates" as gates

import "./role_tools" as rt

type AcceptedRow = { data_json :: Str }

type ContentRow = { content :: Str }

# Per-sprint integrity report. `verified` iff every accepted artifact re-derives
# (present in the content store AND its content hashes to its referenced id).
type Report = { sprint_id :: Str, checked :: Int, intact :: Int, mismatched :: Int, missing :: Int, verified :: Bool }

type Check = Intact | Mismatch | Missing

type Tally = { checked :: Int, intact :: Int, mismatched :: Int, missing :: Int }

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

# Pull the artifact hash out of a node_accepted event: {"node":..,"artifact":H}.
fn artifact_hash(data_json :: Str) -> Str {
  match jv.parse(data_json) {
    Err(_) => "",
    Ok(j) => match jv.get_field(j, "artifact") {
      Some(JStr(h)) => h,
      _ => "",
    },
  }
}

# Re-derive one artifact: fetch from the content-addressed vcs store and confirm
# sha256(content) == hash. Fall back to the SQLite artifacts table (same sha) so
# this works whether or not the run mirrored to vcs. A hash mismatch = tampering.
fn check_artifact(db :: conn.ConnDb, hash :: Str) -> [vcs, fs_read, sql, crypto] Check {
  match vcs.get_blob(hash) {
    Ok(content) => if crypto.sha256_str(content) == hash {
      Intact
    } else {
      Mismatch
    },
    Err(_) => {
      let q := str.join(["SELECT content FROM artifacts WHERE hash='", sq(hash), "'"], "")
      let rows :: Result[List[ContentRow], SqlError] := sql.query(db.handle, q, [])
      match rows {
        Err(_) => Missing,
        Ok(rs) => match list.head(rs) {
          None => Missing,
          Some(r) => if crypto.sha256_str(r.content) == hash {
            Intact
          } else {
            Mismatch
          },
        },
      }
    },
  }
}

# Independently re-derive the integrity of every artifact a sprint accepted.
fn verify_sprint(db :: conn.ConnDb, sprint_id :: Str) -> [vcs, fs_read, sql, crypto] Report {
  let q := str.join(["SELECT data_json FROM traces WHERE agent_id='", sq(sprint_id), "' AND event_kind='node_accepted'"], "")
  let rows :: Result[List[AcceptedRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => { sprint_id: sprint_id, checked: 0, intact: 0, mismatched: 0, missing: 0, verified: false },
    Ok(rs) => {
      let t := list.fold(rs, { checked: 0, intact: 0, mismatched: 0, missing: 0 }, fn (acc :: Tally, row :: AcceptedRow) -> [vcs, fs_read, sql, crypto] Tally {
        let h := artifact_hash(row.data_json)
        if str.is_empty(h) {
          acc
        } else {
          match check_artifact(db, h) {
            Intact => { checked: acc.checked + 1, intact: acc.intact + 1, mismatched: acc.mismatched, missing: acc.missing },
            Mismatch => { checked: acc.checked + 1, intact: acc.intact, mismatched: acc.mismatched + 1, missing: acc.missing },
            Missing => { checked: acc.checked + 1, intact: acc.intact, mismatched: acc.mismatched, missing: acc.missing + 1 },
          }
        }
      })
      let ok := if t.mismatched == 0 {
        t.missing == 0
      } else {
        false
      }
      { sprint_id: sprint_id, checked: t.checked, intact: t.intact, mismatched: t.mismatched, missing: t.missing, verified: ok }
    },
  }
}

fn report_json(r :: Report) -> Str {
  str.join(["{\"sprint_id\":\"", r.sprint_id, "\",\"checked\":", int.to_str(r.checked), ",\"intact\":", int.to_str(r.intact), ",\"mismatched\":", int.to_str(r.mismatched), ",\"missing\":", int.to_str(r.missing), ",\"verdict\":\"", if r.verified {
    "verified"
  } else {
    "FAILED"
  }, "\"}"], "")
}

# ── P0.5: re-execute grounded gates against the verified artifact ──────────────
# Content integrity proves the bytes weren't altered. This goes further: for
# every node whose gate was GROUNDED (`spec compiles` / `spec sh`), re-materialize
# its produced files and RE-RUN the tool — confirming the gate STILL passes, not
# just that the trail says it did. The strongest "provable, not asserted" tier.
type GraphRow = { graph_json :: Str }

type ReReport = { sprint_id :: Str, grounded :: Int, passed :: Int, failed :: Int, verified :: Bool }

type ReTally = { grounded :: Int, passed :: Int, failed :: Int }

fn json_str_field(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# (node_id, gate) pairs from the sprint graph JSON.
fn node_gates(graph_json :: Str) -> List[(Str, Str)] {
  match jv.parse(graph_json) {
    Err(_) => [],
    Ok(j) => match jv.get_field(j, "nodes") {
      Some(JList(nodes)) => list.fold(nodes, [], fn (acc :: List[(Str, Str)], n :: jv.Json) -> List[(Str, Str)] {
        let id := json_str_field(n, "id")
        if str.is_empty(id) {
          acc
        } else {
          list.concat(acc, [(id, json_str_field(n, "gate"))])
        }
      }),
      _ => [],
    },
  }
}

fn lookup_gate(pairs :: List[(Str, Str)], node_id :: Str) -> Str {
  list.fold(pairs, "", fn (acc :: Str, p :: (Str, Str)) -> Str {
    if str.is_empty(acc) {
      match p {
        (id, gate) => if id == node_id {
          gate
        } else {
          acc
        },
      }
    } else {
      acc
    }
  })
}

fn get_content(db :: conn.ConnDb, hash :: Str) -> [vcs, fs_read, sql] Option[Str] {
  match vcs.get_blob(hash) {
    Ok(c) => Some(c),
    Err(_) => {
      let q := str.join(["SELECT content FROM artifacts WHERE hash='", sq(hash), "'"], "")
      let rows :: Result[List[ContentRow], SqlError] := sql.query(db.handle, q, [])
      match rows {
        Err(_) => None,
        Ok(rs) => match list.head(rs) {
          None => None,
          Some(r) => Some(r.content),
        },
      }
    },
  }
}

# Whether a gate re-runs a tool (the two grounded tiers).
fn is_grounded_gate(gate :: Str) -> Bool {
  if gates.is_grounded(gate) {
    true
  } else {
    gates.is_shell_gate(gate)
  }
}

# Re-materialize the fenced artifact and re-run the gate's tool in a scratch dir.
fn reverify_grounded(content :: Str, gate :: Str) -> [io, proc] Result[Unit, Str] {
  let __w := io.write("/tmp/loom-reverify-art.txt", content)
  let toolcmd := if gates.is_shell_gate(gate) {
    gates.shell_command(gate)
  } else {
    "ok=1; n=0; for f in *.lex; do [ -f \"$f\" ] && { n=$((n+1)); ${LEX:-lex} check \"$f\" >/dev/null 2>&1 || ok=0; }; done; for f in *.py; do [ -f \"$f\" ] && { n=$((n+1)); python3 -m py_compile \"$f\" >/dev/null 2>&1 || ok=0; }; done; [ $n -gt 0 ] && [ $ok -eq 1 ]"
  }
  let script := str.join(["W=/tmp/loom-reverify-work; rm -rf $W; mkdir -p $W; python3 bin/extract_fenced.py /tmp/loom-reverify-art.txt $W >/dev/null 2>&1; cd $W && (", toolcmd, ") && echo GATE_OK"], "")
  match proc.run("bash", ["-c", script]) {
    Err(m) => Err(str.concat("reverify could not run: ", m)),
    Ok(r) => {
      let combined := str.concat(r.stdout, r.stderr)
      if str.contains(combined, "GATE_OK") {
        Ok(())
      } else {
        Err(str.slice(combined, 0, 600))
      }
    },
  }
}

# Re-run every grounded gate in a sprint; report how many still pass.
fn reverify_sprint(db :: conn.ConnDb, sprint_id :: Str) -> [vcs, fs_read, sql, io, proc] ReReport {
  let gq := str.join(["SELECT graph_json FROM sprint_graphs WHERE sprint_id='", sq(sprint_id), "' ORDER BY created_at DESC LIMIT 1"], "")
  let grows :: Result[List[GraphRow], SqlError] := sql.query(db.handle, gq, [])
  let gmap := match grows {
    Err(_) => [],
    Ok(rs) => match list.head(rs) {
      None => [],
      Some(r) => node_gates(r.graph_json),
    },
  }
  let q := str.join(["SELECT data_json FROM traces WHERE agent_id='", sq(sprint_id), "' AND event_kind='node_accepted'"], "")
  let rows :: Result[List[AcceptedRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => { sprint_id: sprint_id, grounded: 0, passed: 0, failed: 0, verified: false },
    Ok(rs) => {
      let t := list.fold(rs, { grounded: 0, passed: 0, failed: 0 }, fn (acc :: ReTally, row :: AcceptedRow) -> [vcs, fs_read, sql, io, proc] ReTally {
        let parsed := match jv.parse(row.data_json) {
          Err(_) => { node: "", hash: "" },
          Ok(j) => { node: json_str_field(j, "node"), hash: json_str_field(j, "artifact") },
        }
        let gate := lookup_gate(gmap, parsed.node)
        if is_grounded_gate(gate) {
          match get_content(db, parsed.hash) {
            None => { grounded: acc.grounded + 1, passed: acc.passed, failed: acc.failed + 1 },
            Some(content) => match reverify_grounded(content, gate) {
              Ok(_) => { grounded: acc.grounded + 1, passed: acc.passed + 1, failed: acc.failed },
              Err(_) => { grounded: acc.grounded + 1, passed: acc.passed, failed: acc.failed + 1 },
            },
          }
        } else {
          acc
        }
      })
      { sprint_id: sprint_id, grounded: t.grounded, passed: t.passed, failed: t.failed, verified: t.failed == 0 }
    },
  }
}

fn rereport_json(r :: ReReport) -> Str {
  str.join(["{\"sprint_id\":\"", r.sprint_id, "\",\"grounded_gates\":", int.to_str(r.grounded), ",\"re_passed\":", int.to_str(r.passed), ",\"re_failed\":", int.to_str(r.failed), ",\"verdict\":\"", if r.verified {
    "grounded-reproduced"
  } else {
    "FAILED"
  }, "\"}"], "")
}

# ── P1: per-node authority — did each node stay within its tool grant? ─────────
# The governed-agent kernel (#47) wants to prove not just *what* a run produced
# but *under what authority*. loom scopes tools per role; when a node runs it now
# emits an `op_grant` trail event recording {node, role, tools}. This layer
# RE-DERIVES whether each grant was legitimate: the tools a node was handed must
# fall within its role's canonical policy. A roster/custom agent smuggling in a
# tool its role shouldn't wield (e.g. a `demo` node granted `lex_run`) is caught.
type AuthReport = { sprint_id :: Str, nodes :: Int, ok :: Int, violations :: Int, verified :: Bool }

# Canonical per-role tool authority — the SAME policy the runtime grants from
# (role_tools.tools_for, also consumed by roles.tools_of_role). Re-deriving
# authority against the granting source is the point: the check can't drift from
# what was actually handed out. A role NOT in the policy wields no tools.
fn allowed_tools(role :: Str) -> List[Str] {
  rt.tools_for(role)
}

fn tool_in(allowed :: List[Str], name :: Str) -> Bool {
  list.fold(allowed, false, fn (acc :: Bool, a :: Str) -> Bool {
    if acc {
      true
    } else {
      a == name
    }
  })
}

# Every granted tool must be within the role's policy. An empty grant is always
# legitimate (prose roles wield nothing).
fn grant_ok(role :: Str, tools_csv :: Str) -> Bool {
  if str.is_empty(tools_csv) {
    true
  } else {
    let allowed := allowed_tools(role)
    list.fold(str.split(tools_csv, ","), true, fn (acc :: Bool, name :: Str) -> Bool {
      if acc {
        tool_in(allowed, name)
      } else {
        false
      }
    })
  }
}

# Re-derive per-node authority from the op_grant trail. `verified` iff no node
# was handed a tool outside its role's canonical policy.
fn verify_authority(db :: conn.ConnDb, sprint_id :: Str) -> [sql] AuthReport {
  let q := str.join(["SELECT data_json FROM traces WHERE agent_id='", sq(sprint_id), "' AND event_kind='op_grant'"], "")
  let rows :: Result[List[AcceptedRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => { sprint_id: sprint_id, nodes: 0, ok: 0, violations: 0, verified: false },
    Ok(rs) => {
      let t := list.fold(rs, (0, 0), fn (acc :: (Int, Int), row :: AcceptedRow) -> (Int, Int) {
        match acc {
          (nok, nbad) => {
            let parsed := match jv.parse(row.data_json) {
              Err(_) => { role: "", tools: "" },
              Ok(j) => { role: json_str_field(j, "role"), tools: json_str_field(j, "tools") },
            }
            if grant_ok(parsed.role, parsed.tools) {
              (nok + 1, nbad)
            } else {
              (nok, nbad + 1)
            }
          },
        }
      })
      match t {
        (nok, nbad) => { sprint_id: sprint_id, nodes: nok + nbad, ok: nok, violations: nbad, verified: nbad == 0 },
      }
    },
  }
}

fn authreport_json(r :: AuthReport) -> Str {
  str.join(["{\"sprint_id\":\"", r.sprint_id, "\",\"nodes\":", int.to_str(r.nodes), ",\"within_grant\":", int.to_str(r.ok), ",\"violations\":", int.to_str(r.violations), ",\"verdict\":\"", if r.verified {
    "authority-ok"
  } else {
    "VIOLATION"
  }, "\"}"], "")
}

# ── P1b: per-operation capability — did each node only INVOKE tools it may? ────
# op_grant proves what authority a node was *handed*; this proves what it
# *exercised*. The runner wraps every tool handler it hands an agent and records
# each executed invocation as an `op_call` event (#65); here we re-derive
# whether every invoked tool fell within the invoking node's role policy. A node
# that exercises a tool beyond its role's canonical grant (e.g. a roster agent
# smuggling `lex_run` into a demo node) is counted as `exceeded` — the trail
# proves the excess operation, not just the excess grant.
type OpReport = { sprint_id :: Str, ops :: Int, in_grant :: Int, exceeded :: Int, verified :: Bool }

type OpTally = { ops :: Int, in_grant :: Int, exceeded :: Int }

fn agent_seen(acc :: List[(Str, Str)], agent :: Str) -> Bool {
  list.fold(acc, false, fn (found :: Bool, p :: (Str, Str)) -> Bool {
    if found {
      true
    } else {
      match p {
        (a, _) => a == agent,
      }
    }
  })
}

# Distinct (agent_id, role) pairs the sprint granted, from its op_grant events.
fn grant_agents(db :: conn.ConnDb, sprint_id :: Str) -> [sql] List[(Str, Str)] {
  let q := str.join(["SELECT data_json FROM traces WHERE agent_id='", sq(sprint_id), "' AND event_kind='op_grant'"], "")
  let rows :: Result[List[AcceptedRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => [],
    Ok(rs) => list.fold(rs, [], fn (acc :: List[(Str, Str)], row :: AcceptedRow) -> List[(Str, Str)] {
      match jv.parse(row.data_json) {
        Err(_) => acc,
        Ok(j) => {
          let agent := json_str_field(j, "agent")
          if str.is_empty(agent) {
            acc
          } else {
            if agent_seen(acc, agent) {
              acc
            } else {
              list.concat(acc, [(agent, json_str_field(j, "role"))])
            }
          }
        },
      }
    }),
  }
}

# Tally the op_call events for one agent against its role's tool policy.
fn ops_for_agent(db :: conn.ConnDb, agent :: Str, role :: Str, acc :: OpTally) -> [sql] OpTally {
  let q := str.join(["SELECT data_json FROM traces WHERE agent_id='", sq(agent), "' AND event_kind='op_call'"], "")
  let rows :: Result[List[AcceptedRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => acc,
    Ok(rs) => {
      let allowed := allowed_tools(role)
      list.fold(rs, acc, fn (a :: OpTally, row :: AcceptedRow) -> OpTally {
        let tool := match jv.parse(row.data_json) {
          Err(_) => "",
          Ok(j) => json_str_field(j, "tool"),
        }
        if str.is_empty(tool) {
          a
        } else {
          if tool_in(allowed, tool) {
            { ops: a.ops + 1, in_grant: a.in_grant + 1, exceeded: a.exceeded }
          } else {
            { ops: a.ops + 1, in_grant: a.in_grant, exceeded: a.exceeded + 1 }
          }
        }
      })
    },
  }
}

# Re-derive per-operation authority across a sprint. `verified` iff no node
# invoked a tool outside its role's policy.
fn verify_operations(db :: conn.ConnDb, sprint_id :: Str) -> [sql] OpReport {
  let agents := grant_agents(db, sprint_id)
  let t := list.fold(agents, { ops: 0, in_grant: 0, exceeded: 0 }, fn (acc :: OpTally, ar :: (Str, Str)) -> [sql] OpTally {
    match ar {
      (agent, role) => ops_for_agent(db, agent, role, acc),
    }
  })
  { sprint_id: sprint_id, ops: t.ops, in_grant: t.in_grant, exceeded: t.exceeded, verified: t.exceeded == 0 }
}

fn opreport_json(r :: OpReport) -> Str {
  str.join(["{\"sprint_id\":\"", r.sprint_id, "\",\"ops\":", int.to_str(r.ops), ",\"in_grant\":", int.to_str(r.in_grant), ",\"exceeded\":", int.to_str(r.exceeded), ",\"verdict\":\"", if r.verified {
    "ops-within-grant"
  } else {
    "EXCEEDED"
  }, "\"}"], "")
}

