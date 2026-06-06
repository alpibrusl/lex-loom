# pool_seed.lex — seed the agent_pool with domain-specialized agents.
#
# Uses INSERT OR IGNORE — safe to call on every startup; existing rows are kept.
# Attestation counts accumulate across sprints, progressively ranking specialists.

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "std.time" as time

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

type SeedAgent = { id :: Str, role :: Str, system_prompt :: Str, model_name :: Str, domain_tags_json :: Str }

fn seed_agents() -> List[SeedAgent] {
  [{ id: "ocpp-build-v1", role: "build", system_prompt: "You are a specialized Build agent for OCPP/EV charging protocols. You produce idiomatic Lex modules that implement OCPP 1.6 and 2.0.1 messages, handlers, and state machines. Output only the implementation — no prose.", model_name: "", domain_tags_json: "[\"ocpp\",\"ev\",\"charging\",\"websocket\",\"lex\"]" }, { id: "finance-build-v1", role: "build", system_prompt: "You are a specialized Build agent for financial systems: FIX protocol, OMS, risk engines, and position management. You produce idiomatic Lex modules with correct types and effect rows. Output only the implementation — no prose.", model_name: "", domain_tags_json: "[\"finance\",\"fix\",\"oms\",\"risk\",\"positions\",\"lex\"]" }, { id: "strict-qa-v1", role: "qa", system_prompt: "You are a strict QA agent specialized in Lex code review. You enforce: (1) examples{} blocks on every public function, (2) narrow effect rows — no effect broader than needed, (3) no IO in pure functions, (4) all match arms covered. Reply PASS only when all four criteria are satisfied; otherwise reply FAIL with a specific per-criterion verdict.", model_name: "", domain_tags_json: "[\"lex\",\"qa\",\"strict\"]" }, { id: "general-scribe-v1", role: "scribe", system_prompt: "You are the Scribe for a software sprint. After reviewing the sprint trail and QA outcomes, produce a Digest: (1) lessons learned, (2) spec tightenings for next sprint, (3) a suggested starting graph topology for the next sprint. Be concrete and actionable.", model_name: "", domain_tags_json: "[\"lex\",\"scribe\"]" }]
}

fn insert_agent(db :: Db, now :: Str, a :: SeedAgent) -> [sql, fs_write] Unit {
  let q := str.join(["INSERT OR IGNORE INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, created_at) VALUES ('", sq(a.id), "','", sq(a.role), "','", sq(a.system_prompt), "','", sq(a.model_name), "','", sq(a.domain_tags_json), "',0,'", sq(now), "')"], "")
  let __r := sql.exec(db, q, [])
  ()
}

fn seed(db :: Db) -> [sql, fs_write, time] Unit {
  let now := time.now_str()
  let agents := seed_agents()
  let __r := list.map(agents, fn (a :: SeedAgent) -> [sql, fs_write] Unit {
    insert_agent(db, now, a)
  })
  ()
}

