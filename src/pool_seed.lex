# pool_seed.lex — seed the agent_pool with GENERIC, domain-neutral agents.
#
# This package is the generic sprint orchestrator, so it must not carry any
# domain knowledge. Domain-specialist agents (e.g. OCPP/EV, finance) live in
# their own repos and register themselves via `insert_agents` — see
# alpibrusl/lex-csms and alpibrusl/lex-oms-agent.

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "std.time" as time

import "lex-orm/src/connection" as conn

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

type SeedAgent = { id :: Str, role :: Str, system_prompt :: Str, model_name :: Str, domain_tags_json :: Str }

# Generic, domain-neutral defaults. A generic build agent (no OCPP/finance
# framing), plus role-generic QA and scribe. Keep model_name empty so agents
# inherit the sprint's requested model.
fn seed_agents() -> List[SeedAgent] {
  [{ id: "build-v1", role: "build", system_prompt: "You are a Build agent working in Lex — a typed-effect language NOT in your training data. WORKFLOW: (1) Call lex_guidelines (topic='all') FIRST to learn Lex syntax, effects, and stdlib. (2) Implement the design as Lex modules with correct types and effect rows. (3) After each file, call lex_check (filename + code) and repair until ok='true'. Finish only when every file passes. Output each final file in a fenced block labelled with its filename.", model_name: "", domain_tags_json: "[\"lex\",\"build\"]" }, { id: "strict-qa-v1", role: "qa", system_prompt: "You are a strict QA agent for a Lex language sprint. Lex is NOT in your training data — verify with tools, never guess.\n\nWORKFLOW (mandatory):\n1. Extract every .lex file from the Build output.\n2. Call lex_check on each file (filename + code). Every file MUST return ok='true'.\n3. If a test file exists, call lex_run with filename=<test file>, fn_name='run_all', args=''. Tests pass when output shows ok='true' and zero failures.\n4. Output ONLY JSON — no prose, no fences:\n{\"verdict\":\"PASS\",\"reason\":\"...\",\"check_output\":\"<first 200 chars>\",\"test_output\":\"<first 200 chars>\"}\n\nPASS only if lex_check is ok='true' for ALL files AND tests pass. Otherwise FAIL with the errors. Your verdict MUST be based on lex_check / lex_run output.", model_name: "", domain_tags_json: "[\"lex\",\"qa\",\"strict\"]" }, { id: "general-scribe-v1", role: "scribe", system_prompt: "You are the Scribe for a software sprint. After reviewing the sprint trail, produce a JSON digest. Output ONLY JSON — no prose, no markdown fences.", model_name: "", domain_tags_json: "[\"lex\",\"scribe\"]" }]
}

fn insert_agent(db :: conn.ConnDb, now :: Str, a :: SeedAgent) -> [sql, fs_write] Unit {
  let q := str.join(["INSERT OR IGNORE INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, created_at) VALUES ('", sq(a.id), "','", sq(a.role), "','", sq(a.system_prompt), "','", sq(a.model_name), "','", sq(a.domain_tags_json), "',0,'", sq(now), "')"], "")
  let __r := sql.exec(db.handle, q, [])
  ()
}

# Reusable seeder: domain apps build their own List[SeedAgent] of specialists
# and call this to register them in the pool (keeping their prompts in their
# own repos, not here).
fn insert_agents(db :: conn.ConnDb, agents :: List[SeedAgent]) -> [sql, fs_write, time] Unit {
  let now := time.now_str()
  let __r := list.map(agents, fn (a :: SeedAgent) -> [sql, fs_write] Unit {
    insert_agent(db, now, a)
  })
  ()
}

fn seed(db :: conn.ConnDb) -> [sql, fs_write, time] Unit {
  insert_agents(db, seed_agents())
}

