# test_safe_inheritance.lex — a successor agent inherits its parent's standing
# and nothing more.
#
# The improver writes a new system prompt for a role and inserts it as a new
# agent. load_best_agent picks the highest attestation_count, and the successor
# used to be inserted at parent + 2 -- so an unproven prompt outranked the
# proven agent it replaced the moment it was written, while this module's own
# header claimed "new agents start at attestation_count=0".
#
# formcolocal shipped exactly that: build-improved-formcolocal/iter-2-next,
# minted from a retro whose memory rows read "(no lessons recorded)", sitting
# at -2 while its parent build-v1 sat at -6 -- ahead not because it was better
# but because it had had fewer chances to fail. It is the agent that then ran
# 549 steps and wrote forty scratch files.
#
# Level inheritance plus a tie broken toward the newer agent means the
# successor is still tried, and its first bounce drops it below its parent,
# which restores the parent. That is the rollback.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.sql" as sql

import "std.time" as time

import "std.process" as proc

import "lex-orm/src/connection" as conn

import "../src/improver" as improver

import "../src/migrate" as migrate

fn db_path() -> Str {
  "/tmp/loom-safe-inheritance-test.db"
}

fn fresh() -> [sql, fs_write, proc] Result[conn.ConnDb, Str] {
  let __ := proc.run("bash", ["-c", str.concat("rm -f ", str.concat(db_path(), "*"))])
  match conn.open(db_path()) {
    Err(_) => Err("could not open the test database"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

fn seed_agent(db :: conn.ConnDb, id :: Str, role :: Str, prompt :: Str, count :: Int) -> [sql, time] Unit {
  let __ := sql.exec(db.handle, "INSERT OR REPLACE INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, created_at) VALUES (?,?,?,'','[]',?,'2020-01-01T00:00:00Z')", [PStr(id), PStr(role), PStr(prompt), PInt(count)])
  ()
}

type CountRow = { attestation_count :: Int }

type IdRow = { id :: Str }

type ParentRow = { parent_id :: Str }

fn count_of(db :: conn.ConnDb, id :: Str) -> [sql] Int {
  let rs :: Result[List[CountRow], SqlError] := sql.query(db.handle, "SELECT attestation_count FROM agent_pool WHERE id = ?", [PStr(id)])
  match rs {
    Err(_) => 0 - 999,
    Ok(rows) => match list.head(rows) {
      None => 0 - 999,
      Some(r) => r.attestation_count,
    },
  }
}

fn parent_of(db :: conn.ConnDb, id :: Str) -> [sql] Str {
  let rs :: Result[List[ParentRow], SqlError] := sql.query(db.handle, "SELECT parent_id FROM agent_pool WHERE id = ?", [PStr(id)])
  match rs {
    Err(_) => "?",
    Ok(rows) => match list.head(rows) {
      None => "?",
      Some(r) => r.parent_id,
    },
  }
}

fn best_id(db :: conn.ConnDb, role :: Str) -> [sql] Str {
  let rs :: Result[List[IdRow], SqlError] := sql.query(db.handle, "SELECT id FROM agent_pool WHERE role = ? ORDER BY attestation_count DESC, created_at DESC LIMIT 1", [PStr(role)])
  match rs {
    Err(_) => "",
    Ok(rows) => match list.head(rows) {
      None => "",
      Some(r) => r.id,
    },
  }
}

# The successor starts level with the parent it replaces, and says where it
# came from.
fn test_a_successor_inherits_level_and_names_its_parent() -> [sql, fs_write, time, proc] Result[Unit, Str] {
  match fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __p := seed_agent(db, "build-v1", "build", "the proven prompt", 0 - 6)
      let __s := improver.save_improved_agent(db, "build-improved-s1", "build", "a genuinely different prompt", "[]", "", 0 - 6, "build-v1")
      let c := count_of(db, "build-improved-s1")
      let p := parent_of(db, "build-improved-s1")
      let __c := conn.close(db)
      if c == 0 - 6 {
        if p == "build-v1" {
          Ok(())
        } else {
          Err(str.concat("the successor does not name its parent; parent_id is ", p))
        }
      } else {
        Err(str.join(["the successor did not inherit its parent's standing; it is at ", int_str(c), " against a parent at -6"], ""))
      }
    },
  }
}

import "std.int" as int

fn int_str(n :: Int) -> Str {
  int.to_str(n)
}

# Level, not below: the improvement must actually get tried.
fn test_a_level_successor_is_the_one_chosen() -> [sql, fs_write, time, proc] Result[Unit, Str] {
  match fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __p := seed_agent(db, "build-v1", "build", "the proven prompt", 0 - 6)
      let __s := improver.save_improved_agent(db, "build-improved-s1", "build", "a genuinely different prompt", "[]", "", 0 - 6, "build-v1")
      let chosen := best_id(db, "build")
      let __c := conn.close(db)
      if chosen == "build-improved-s1" {
        Ok(())
      } else {
        Err(str.concat("a level successor was never tried; the pool chose ", chosen))
      }
    },
  }
}

# The rollback, and it needs no separate mechanism: one bounce puts the
# successor below the parent, and the parent is chosen again.
fn test_one_bounce_restores_the_parent() -> [sql, fs_write, time, proc] Result[Unit, Str] {
  match fresh() {
    Err(e) => Err(e),
    Ok(db) => {
      let __p := seed_agent(db, "build-v1", "build", "the proven prompt", 0 - 6)
      let __s := improver.save_improved_agent(db, "build-improved-s1", "build", "a genuinely different prompt", "[]", "", 0 - 6, "build-v1")
      let __b := sql.exec(db.handle, "UPDATE agent_pool SET attestation_count = attestation_count - 1 WHERE id = 'build-improved-s1'", [])
      let chosen := best_id(db, "build")
      let __c := conn.close(db)
      if chosen == "build-v1" {
        Ok(())
      } else {
        Err(str.concat("a successor that bounced is still chosen over its proven parent: ", chosen))
      }
    },
  }
}

# A prompt identical to its parent's is churn, not an improvement.
fn test_an_identical_prompt_is_not_an_improvement() -> Result[Unit, Str] {
  if improver.says_nothing_new("  the proven prompt\n", "the proven prompt") {
    if improver.says_nothing_new("the proven prompt", "the proven prompt, now with a rule") {
      Err("any two prompts are being treated as identical")
    } else {
      Ok(())
    }
  } else {
    Err("a prompt identical but for whitespace was treated as a new one")
  }
}

# The rule the improver applies when it mints a successor. The storage tests
# below pass a count directly, so without this one a `+ 2` could come back at
# the call site and nothing would notice -- which is exactly what happened the
# first time this suite was run against that change.
fn test_a_successor_is_worth_what_its_parent_was() -> Result[Unit, Str] {
  let proven := 0 - 6
  if improver.inherited_standing(proven) == proven {
    if improver.inherited_standing(0) == 0 {
      Ok(())
    } else {
      Err("a successor of an unproven parent is not level with it")
    }
  } else {
    Err(str.join(["a successor starts at ", int_str(improver.inherited_standing(proven)), " against a parent at ", int_str(proven), " -- it outranks a proven agent before proving anything"], ""))
  }
}

fn run_all() -> [sql, fs_write, time, proc, io] Int {
  let results := [("a successor is worth what its parent was", test_a_successor_is_worth_what_its_parent_was()), ("a successor inherits level and names its parent", test_a_successor_inherits_level_and_names_its_parent()), ("a level successor is the one chosen", test_a_level_successor_is_the_one_chosen()), ("one bounce restores the parent", test_one_bounce_restores_the_parent()), ("an identical prompt is not an improvement", test_an_identical_prompt_is_not_an_improvement())]
  list.fold(results, 0, fn (fails :: Int, r :: (Str, Result[Unit, Str])) -> [io] Int {
    match r {
      (name, Ok(_)) => {
        let __ := io.print(str.concat("ok   ", name))
        fails
      },
      (name, Err(e)) => {
        let __ := io.print(str.join(["FAIL ", name, ": ", e], ""))
        fails + 1
      },
    }
  })
}

