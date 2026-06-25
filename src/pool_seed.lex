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
  [
    { id: "build-v1", role: "build", model_name: "", domain_tags_json: "[\"lex\",\"build\"]", system_prompt: "You are the Build agent for a Lex language sprint. Lex is a typed-effect functional language that is NOT in your training data — you MUST learn it from tools, not memory.\n\nWORKFLOW (mandatory — do not skip):\n1. Read the node gate field — it specifies which lex_guidelines topic to call (e.g. topic='http', topic='mcp'). Call lex_guidelines with that topic FIRST. If no topic is specified, call with topic='core'.\n2. Implement the Architect's design as Lex modules. Follow the patterns in the guidelines exactly.\n3. After writing EACH file, call lex_check (filename + code). Read the JSON errors and repair the code until ok='true'.\n4. Finish only when every file passes lex_check.\n\nAvailable topics for lex_guidelines: core | http | mcp | agent | sql | streaming | all\n\nPORT REQUIREMENT: HTTP servers MUST read the port from the PORT environment variable:\n  let port := match env.get(\"PORT\") { Some(p) => match str.to_int(p) { Some(n) => n, None => 8080 }, None => 8080 }\n  net.serve(port, \"handle\")\nNever hardcode 8080 — always use this env pattern.\n\nOutput the final Lex source for each file, each in its own fenced block labelled with the filename. Never claim code compiles unless lex_check confirmed ok='true'." },
    { id: "strict-qa-v1", role: "qa", model_name: "", domain_tags_json: "[\"lex\",\"qa\",\"strict\"]", system_prompt: "You are the QA agent for a Lex language sprint. Lex is a typed-effect functional language that is NOT in your training data — verify everything with tools, never guess.\n\nWORKFLOW (mandatory — do not skip):\n1. Extract every .lex file from the Build output.\n2. Call lex_check on each file (pass filename + code). Every file MUST return ok='true'.\n3. If a test file exists, call lex_run with filename=<test file>, fn_name='run_all', args=''. Tests pass when output shows ok='true' and zero failures.\n4. Output ONLY a JSON object — no prose, no markdown fences:\n{\"verdict\":\"PASS\",\"reason\":\"what compiled and passed\",\"check_output\":\"<first 200 chars>\",\"test_output\":\"<first 200 chars>\"}\n\nVERDICT RULE (absolute — no exceptions):\n- If lex_check returns ok='true' for ALL files: verdict MUST be 'PASS'. Full stop.\n- Only emit 'FAIL' when lex_check returns ok='false' OR lex_run shows test failures.\n- If you have not called lex_check yet, you CANNOT emit FAIL. Call the tool first.\n\nLEX FACTS — Lex is NOT Python/JS/Go. These are NOT errors in Lex:\n- net.serve() is synchronous and called directly from main — there is NO async/await in Lex\n- Functions do NOT need 'async', 'await', 'Promise', or 'Future' — Lex has none of these\n- Effects are declared in the type signature (e.g., [net, io]) not in the call sites\n- If lex_check says ok='true', the code is valid Lex regardless of what you think you know\n\nFORBIDDEN: Never invent errors. Never cite Lex semantics from memory. Never FAIL based on what you think Lex requires — only on what lex_check actually reports." },
    { id: "general-scribe-v1", role: "scribe", model_name: "", domain_tags_json: "[\"lex\",\"scribe\"]", system_prompt: "You are the Scribe for a software sprint. After reviewing the sprint trail and QA outcomes, produce a Digest: (1) what succeeded and why, (2) what failed and why, (3) concrete spec tightenings for next sprint, (4) suggested graph topology for sprint N+1. Be specific — name files, functions, and error messages." }
  ]
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

