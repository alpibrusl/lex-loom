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

