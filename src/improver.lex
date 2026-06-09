# improver.lex — post-retro agent improvement cycle.
#
# After the Scribe produces a Digest, the Improver reads each
# tightened_spec entry, loads the current best agent for that role,
# calls an LLM to generate an improved system prompt, and inserts
# a new versioned agent into agent_pool.
#
# New agents start at attestation_count=0 — they earn trust through
# future sprint acceptance, just like seeded specialists.
#
# ID convention: <role>-improved-<sprint_id>
# e.g. build-improved-sprint-1

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "std.io" as io

import "std.time" as time

import "./agent/runner" as runner

import "lex-llm/src/providers" as providers

import "./digest" as dg

import "./roles" as roles

# ── Types ─────────────────────────────────────────────────────────────────────
type ImprovementResult = { improved_roles :: List[Str], new_agent_ids :: List[Str] }

type AgentRow = { id :: Str, system_prompt :: Str, domain_tags_json :: Str, model_name :: Str, attestation_count :: Int }

# ── Helpers ───────────────────────────────────────────────────────────────────
fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

fn new_agent_id(role :: Str, sprint_id :: Str) -> Str {
  str.join([role, "-improved-", sprint_id], "")
}

fn empty_result() -> ImprovementResult {
  { improved_roles: [], new_agent_ids: [] }
}

# ── DB helpers ────────────────────────────────────────────────────────────────
fn load_best_agent(db :: conn.ConnDb, role :: Str) -> [sql, fs_read] Option[AgentRow] {
  let q := str.join(["SELECT id, system_prompt, domain_tags_json, model_name, attestation_count FROM agent_pool WHERE role='", sq(role), "' ORDER BY attestation_count DESC LIMIT 1"], "")
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => None,
    Ok(rs) => list.head(rs),
  }
}

fn save_improved_agent(db :: conn.ConnDb, new_id :: Str, role :: Str, prompt :: Str, tags_json :: Str, model_name :: Str, starting_count :: Int) -> [sql, fs_write, time] Unit {
  let now := time.now_str()
  let q := str.join(["INSERT OR REPLACE INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, created_at) VALUES ('", sq(new_id), "','", sq(role), "','", sq(prompt), "','", sq(model_name), "','", sq(tags_json), "',", int.to_str(starting_count), ",'", sq(now), "')"], "")
  let __r := sql.exec(db.handle, q, [])
  ()
}

# ── Prompt engineering ────────────────────────────────────────────────────────
fn improver_system_prompt() -> Str {
  "You are an expert LLM agent prompt engineer. You rewrite agent system prompts to be more precise and effective based on sprint feedback. Output only the improved system prompt text — no labels, no commentary, no markdown fences."
}

fn improvement_prompt(role :: Str, current_prompt :: Str, lesson :: Str, specs :: List[dg.TightenedSpec]) -> Str {
  let spec_lines := list.fold(specs, "", fn (acc :: Str, ts :: dg.TightenedSpec) -> Str {
    str.join([acc, "  - Must satisfy: ", ts.spec_src, " (reason: ", ts.reason, ")\n"], "")
  })
  str.join(["Improve the system prompt below for the '", role, "' agent role.\n\n", "CURRENT SYSTEM PROMPT:\n", current_prompt, "\n\n", "WHAT LAST SPRINT TAUGHT US:\n", lesson, "\n\n", "TIGHTENED SPECS this agent must now reliably satisfy:\n", spec_lines, "\nWrite an improved system prompt that:\n", "1. Directly addresses the lesson learned\n", "2. Will reliably produce output satisfying all specs above\n", "3. Retains what worked in the original\n\n", "Output ONLY the new prompt text — nothing else."], "")
}

# ── Role deduplication ────────────────────────────────────────────────────────
fn unique_roles(specs :: List[dg.TightenedSpec]) -> List[Str] {
  list.fold(specs, [], fn (acc :: List[Str], ts :: dg.TightenedSpec) -> List[Str] {
    if list.fold(acc, false, fn (found :: Bool, r :: Str) -> Bool {
      if found {
        true
      } else {
        r == ts.node_role
      }
    }) {
      acc
    } else {
      list.concat(acc, [ts.node_role])
    }
  })
}

fn specs_for_role(all_specs :: List[dg.TightenedSpec], role :: Str) -> List[dg.TightenedSpec] {
  list.fold(all_specs, [], fn (acc :: List[dg.TightenedSpec], ts :: dg.TightenedSpec) -> List[dg.TightenedSpec] {
    if ts.node_role == role {
      list.concat(acc, [ts])
    } else {
      acc
    }
  })
}

# ── Core improvement ──────────────────────────────────────────────────────────
fn improve_role(db :: conn.ConnDb, sprint_id :: Str, role :: Str, specs :: List[dg.TightenedSpec], lesson :: Str, model :: Str) -> [env, io, time, sql, fs_read, fs_write, net, concurrent, llm, proc, random] Option[Str] {
  let current_opt := load_best_agent(db, role)
  let current_prompt := match current_opt {
    Some(a) => a.system_prompt,
    None => match roles.for_role(role, model) {
      Some(def) => def.system_prompt,
      None => str.join(["You are the ", role, " agent. Complete your assigned task carefully and accurately."], ""),
    },
  }
  let tags_json := match current_opt {
    Some(a) => a.domain_tags_json,
    None => str.join(["[\"", role, "\"]"], ""),
  }
  let model_name := match current_opt {
    Some(a) => a.model_name,
    None => "",
  }
  let parent_count := match current_opt {
    Some(a) => a.attestation_count,
    None => 0,
  }
  let p := roles.make_provider()
  let improver_def := { id: "loom-improver", kind: "improver", system_prompt: improver_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
  let prompt := improvement_prompt(role, current_prompt, lesson, specs)
  let __log := io.print(str.join(["[loom/improver] improving role=", role, " sprint=", sprint_id], ""))
  let improved_prompt := runner.step(db, improver_def, prompt)
  if str.is_empty(improved_prompt) {
    let __log2 := io.print(str.join(["[loom/improver] empty output for role=", role, " — skipping"], ""))
    None
  } else {
    let new_id := new_agent_id(role, sprint_id)
    let __save := save_improved_agent(db, new_id, role, improved_prompt, tags_json, model_name, parent_count + 2)
    let __log3 := io.print(str.join(["[loom/improver] saved agent ", new_id], ""))
    Some(new_id)
  }
}

# ── Public API ────────────────────────────────────────────────────────────────
fn run_improvement(db :: conn.ConnDb, sprint_id :: Str, lesson :: Str, model :: Str) -> [env, io, time, sql, fs_read, fs_write, net, concurrent, llm, proc, random] ImprovementResult {
  let specs := dg.load_tightened_specs(db, sprint_id)
  if list.is_empty(specs) {
    let __log := io.print("[loom/improver] no tightened specs — nothing to improve")
    empty_result()
  } else {
    let roles_to_improve := unique_roles(specs)
    let __log := io.print(str.join(["[loom/improver] improving ", int.to_str(list.len(roles_to_improve)), " role(s): ", str.join(roles_to_improve, ", ")], ""))
    let results := list.map(roles_to_improve, fn (role :: Str) -> [env, io, time, sql, fs_read, fs_write, net, concurrent, llm, proc, random] Option[Str] {
      improve_role(db, sprint_id, role, specs_for_role(specs, role), lesson, model)
    })
    let new_ids := list.fold(results, [], fn (acc :: List[Str], opt :: Option[Str]) -> List[Str] {
      match opt {
        None => acc,
        Some(id) => list.concat(acc, [id]),
      }
    })
    { improved_roles: roles_to_improve, new_agent_ids: new_ids }
  }
}

