# test_cast.lex — regression coverage for the Agent Resources layer (#19):
# roster manager (select_roster/cast_node/score_agent) and evaluator
# (increment/decrement attestation, retire, update_pool_from_sprint).
#
# This machinery is fully wired into the live sprint flow (orchestrator.lex
# calls select_roster before a sprint, roster_lookup per node, and
# update_pool_from_sprint after — confirmed firing live during #21's e2e
# sprint runs), but had almost no unit coverage of its own: only one cast
# test existed (test_identity.lex's reputation tie-break), and
# domain_bonus/score_agent, the attestation/retire lifecycle, and
# select_roster/cast_node's fallback behavior were entirely untested.

import "std.list" as list

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.sql" as sql

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/cast" as cast

import "../src/graph" as graph

# "sqlite::memory:" is shared across separate `lex run` invocations, not just
# within one process (confirmed directly: state from an earlier run of THIS
# file was still visible on a later, independent run). Fixed ids are not
# enough on their own — every seeded agent_pool row uses a random suffix
# (uniq()) so repeat runs of this same file never collide with leftover rows.
fn fresh_db() -> [sql, fs_write, time] Result[conn.ConnDb, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(m) => Err(str.concat("migrate failed: ", m)),
      Ok(_) => Ok(db),
    },
  }
}

fn uniq(prefix :: Str) -> [random] Str {
  str.join([prefix, "-", crypto.random_str_hex(6)], "")
}

fn seed_pool_agent(db :: conn.ConnDb, id :: Str, role :: Str, count :: Int, tags_json :: Str) -> [sql, fs_write] Unit {
  let q := str.join(["INSERT OR IGNORE INTO agent_pool (id, role, system_prompt, domain_tags_json, attestation_count, created_at) VALUES ('", id, "', '", role, "', 'p', '", tags_json, "', ", int.to_str(count), ", 't')"], "")
  let __r := sql.exec(db.handle, q, [])
  ()
}

fn node(id :: Str, role :: Str) -> graph.Node {
  { id: id, role: role, gate: "spec non-empty", expand: None, activate_when: "" }
}

# ── Scoring (pure) ────────────────────────────────────────────────────────────
fn test_domain_bonus_matches_tag_in_request() -> Result[Unit, Str] {
  let bonus := cast.domain_bonus("[\"python\",\"api\"]", "build a python REST api")
  if bonus == 20 {
    Ok(())
  } else {
    Err(str.concat("expected +10 per matching tag (2 tags match) = 20, got ", int.to_str(bonus)))
  }
}

fn test_domain_bonus_no_match_is_zero() -> Result[Unit, Str] {
  let bonus := cast.domain_bonus("[\"rust\",\"cli\"]", "build a python REST api")
  if bonus == 0 {
    Ok(())
  } else {
    Err(str.concat("expected 0 for no matching tags, got ", int.to_str(bonus)))
  }
}

fn test_score_agent_weights_reputation_above_attestation() -> Result[Unit, Str] {
  let generalist := { id: "g", role: "build", system_prompt: "", model_name: "", domain_tags_json: "[]", attestation_count: 5, reputation: 0 }
  let proven := { id: "p", role: "build", system_prompt: "", model_name: "", domain_tags_json: "[]", attestation_count: 0, reputation: 2 }
  let s_generalist := cast.score_agent(generalist, "some request")
  let s_proven := cast.score_agent(proven, "some request")
  if s_proven > s_generalist {
    Ok(())
  } else {
    Err(str.join(["expected reputation (", int.to_str(s_proven), ") to outweigh raw attestation (", int.to_str(s_generalist), ") here"], ""))
  }
}

fn test_score_agent_domain_match_beats_generalist_reputation() -> Result[Unit, Str] {
  let generalist := { id: "g", role: "build", system_prompt: "", model_name: "", domain_tags_json: "[]", attestation_count: 0, reputation: 1 }
  let specialist := { id: "s", role: "build", system_prompt: "", model_name: "", domain_tags_json: "[\"python\"]", attestation_count: 0, reputation: 0 }
  let s_generalist := cast.score_agent(generalist, "build a python service")
  let s_specialist := cast.score_agent(specialist, "build a python service")
  if s_specialist > s_generalist {
    Ok(())
  } else {
    Err("expected a matching domain tag (+10) to outrank a single verified-reputation point (+3)")
  }
}

# ── Roster assembly (DB) ──────────────────────────────────────────────────────
fn test_cast_node_falls_back_when_pool_empty() -> [env, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let entry := cast.cast_node(db, node("n1", "docs"), "some request", "gemma4:latest", "test-sprint")
      if str.is_empty(entry.pool_agent_id) {
        Ok(())
      } else {
        Err(str.concat("expected no pool agent id (empty pool), got ", entry.pool_agent_id))
      }
    },
  }
}

fn test_cast_node_picks_seeded_pool_agent() -> [env, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let agent_id := uniq("cast-py")
      let role := uniq("cast_role_a")
      let __s := seed_pool_agent(db, agent_id, role, 3, "[]")
      let entry := cast.cast_node(db, node("n1", role), "some request", "gemma4:latest", "test-sprint")
      if entry.pool_agent_id == agent_id {
        Ok(())
      } else {
        Err(str.join(["expected the seeded pool agent to be cast, got '", entry.pool_agent_id, "'"], ""))
      }
    },
  }
}

fn test_select_roster_covers_every_node() -> [env, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let g := { id: "g1", phase: graph.Intake, nodes: [node("a", "build"), node("b", "qa")], edges: [] }
      let roster := cast.select_roster(db, g, "some request", "gemma4:latest", "test-sprint")
      if list.len(roster) == 2 {
        match cast.roster_lookup(roster, "a") {
          None => Err("expected a roster entry for node 'a'"),
          Some(_) => match cast.roster_lookup(roster, "missing") {
            None => Ok(()),
            Some(_) => Err("roster_lookup should return None for an unknown node id"),
          },
        }
      } else {
        Err(str.concat("expected 2 roster entries, got ", int.to_str(list.len(roster))))
      }
    },
  }
}

# ── Evaluator: attestation / retire lifecycle (DB) ───────────────────────────
type CountRow = { n :: Int }

fn count_of_row(db :: conn.ConnDb, id :: Str) -> [sql] Int {
  let q := str.join(["SELECT attestation_count AS n FROM agent_pool WHERE id = '", id, "'"], "")
  let rows :: Result[List[CountRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => -999,
    Ok(rs) => match list.head(rs) {
      None => -999,
      Some(r) => r.n,
    },
  }
}

type RetiredRow = { retired_at :: Str }

fn is_retired(db :: conn.ConnDb, id :: Str) -> [sql] Bool {
  let q := str.join(["SELECT retired_at FROM agent_pool WHERE id = '", id, "'"], "")
  let rows :: Result[List[RetiredRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => false,
    Ok(rs) => match list.head(rs) {
      None => false,
      Some(r) => str.is_empty(r.retired_at) == false,
    },
  }
}

fn test_increment_attestation_raises_count() -> [random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let agent_id := uniq("evalop")
      let __s := seed_pool_agent(db, agent_id, "role", 0, "[]")
      let __i := cast.increment_attestation(db, agent_id)
      if count_of_row(db, agent_id) == 1 {
        Ok(())
      } else {
        Err(str.concat("expected attestation_count=1, got ", int.to_str(count_of_row(db, agent_id))))
      }
    },
  }
}

fn test_record_bounce_lowers_count_and_retires_after_three() -> [random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let agent_id := uniq("evalop")
      let __s := seed_pool_agent(db, agent_id, "role", 0, "[]")
      let __b1 := cast.record_bounce(db, agent_id)
      let __b2 := cast.record_bounce(db, agent_id)
      let after_two := is_retired(db, agent_id)
      let __b3 := cast.record_bounce(db, agent_id)
      let after_three := is_retired(db, agent_id)
      if after_two {
        Err("agent retired too early (after only 2 bounces)")
      } else {
        if count_of_row(db, agent_id) == -3 {
          if after_three {
            Ok(())
          } else {
            Err("expected agent to be retired at attestation_count <= -3")
          }
        } else {
          Err(str.concat("expected attestation_count=-3 after 3 bounces, got ", int.to_str(count_of_row(db, agent_id))))
        }
      }
    },
  }
}

fn test_retired_agent_excluded_from_pool() -> [env, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let agent_id := uniq("evalop")
      let role := uniq("cast_role_b")
      let __s := seed_pool_agent(db, agent_id, role, 0, "[]")
      let __b1 := cast.record_bounce(db, agent_id)
      let __b2 := cast.record_bounce(db, agent_id)
      let __b3 := cast.record_bounce(db, agent_id)
      let pool := cast.load_pool_for_role(db, role)
      if list.is_empty(pool) {
        Ok(())
      } else {
        Err(str.concat("expected the retired agent to be excluded, pool still has ", int.to_str(list.len(pool))))
      }
    },
  }
}

fn test_update_pool_from_sprint_rewards_accepted_and_bounces_rejected() -> [env, random, sql, fs_read, fs_write, time] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let good_id := uniq("sprint-good")
      let bad_id := uniq("sprint-bad")
      let __sa := seed_pool_agent(db, good_id, "role", 0, "[]")
      let __sb := seed_pool_agent(db, bad_id, "role", 0, "[]")
      let roster := [{ node_id: "good-node", pool_agent_id: good_id, agent_config: cast.default_config_for_role("role", "gemma4:latest", "", "test-cast") }, { node_id: "bad-node", pool_agent_id: bad_id, agent_config: cast.default_config_for_role("role", "gemma4:latest", "", "test-cast") }]
      let __u := cast.update_pool_from_sprint(db, roster, ["good-node"])
      if count_of_row(db, good_id) == 1 {
        if count_of_row(db, bad_id) == -1 {
          Ok(())
        } else {
          Err(str.concat("expected sprint-bad at -1, got ", int.to_str(count_of_row(db, bad_id))))
        }
      } else {
        Err(str.concat("expected sprint-good at 1, got ", int.to_str(count_of_row(db, good_id))))
      }
    },
  }
}

fn suite() -> [env, random, sql, fs_read, fs_write, time] List[Result[Unit, Str]] {
  [test_domain_bonus_matches_tag_in_request(), test_domain_bonus_no_match_is_zero(), test_score_agent_weights_reputation_above_attestation(), test_score_agent_domain_match_beats_generalist_reputation(), test_cast_node_falls_back_when_pool_empty(), test_cast_node_picks_seeded_pool_agent(), test_select_roster_covers_every_node(), test_increment_attestation_raises_count(), test_record_bounce_lowers_count_and_retires_after_three(), test_retired_agent_excluded_from_pool(), test_update_pool_from_sprint_rewards_accepted_and_bounces_rejected()]
}

fn run_all() -> [io, env, random, sql, fs_read, fs_write, time] Unit {
  let failures := list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> [io] Int {
    match r {
      Ok(_) => n,
      Err(m) => {
        let __p := io.print(str.concat("test_cast FAIL: ", m))
        n + 1
      },
    }
  })
  if failures == 0 {
    ()
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

