# authority.lex — stamp delegated authority onto the node trail (#248).
#
# From the deepseek-harness review: a delegated execution's record must be
# SELF-CONTAINED — the trail alone answers "under what authority did this
# node run". The trail already records what happened (worker_node_executed,
# node_refused_budget, artifacts); this records what the node was ALLOWED
# to do at the moment of dispatch: the resolved isolation preset, the
# envelope caps and spend AS THEY STOOD, the model and the API-call budget.
# Reconstructing that later from the company DB would read its CURRENT
# state — which may have changed since — so the stamp happens at dispatch,
# on both execution paths (queue: worker.execute_node_job; inline:
# orchestrator.invoke_node).
#
# One event kind, `node_authority`, recorded via the same tr.trail plane as
# every other node event. This is the allow-side counterpart of #245's
# node_refused_budget: refusals were already durable; grants now are too.

import "std.int" as int

import "std.str" as str

import "lex-orm/src/connection" as conn

import "./budget" as budget

import "./manifests" as manifests

import "./transport" as tr

fn envelope_json(e :: Option[budget.Envelope]) -> Str {
  match e {
    None => "null",
    Some(env) => str.join(["{\"cap_cents\":", int.to_str(env.cap_cents), ",\"spent_cents\":", int.to_str(env.spent_cents), "}"], ""),
  }
}

# The payload is built from internal identifiers (role kinds, preset names,
# sprint/worker ids, a model tag) — same hand-assembled JSON idiom as the
# neighboring trail events in worker.lex/orchestrator.lex.
fn authority_json(node_id :: Str, role :: Str, preset :: Str, model :: Str, api_calls_max :: Int, dispatcher :: Str, role_env :: Option[budget.Envelope], total_env :: Option[budget.Envelope]) -> Str
  examples {
    authority_json("write_docs", "docs", "Demo", "proc:cat", 10, "inline", Some({ scope: "role:docs", cap_cents: 100, spent_cents: 0 }), None) => "{\"node\":\"write_docs\",\"role\":\"docs\",\"preset\":\"Demo\",\"fs\":\"ReadOnly\",\"exec\":\"None\",\"model\":\"proc:cat\",\"api_calls_max\":10,\"dispatcher\":\"inline\",\"role_envelope\":{\"cap_cents\":100,\"spent_cents\":0},\"total_envelope\":null}"
  }
{
  let dims := manifests.preset_dims(preset)
  str.join(["{\"node\":\"", node_id, "\",\"role\":\"", role, "\",\"preset\":\"", preset, "\",\"fs\":\"", dims.fs, "\",\"exec\":\"", dims.exec, "\",\"model\":\"", model, "\",\"api_calls_max\":", int.to_str(api_calls_max), ",\"dispatcher\":\"", dispatcher, "\",\"role_envelope\":", envelope_json(role_env), ",\"total_envelope\":", envelope_json(total_env), "}"], "")
}

# Resolve and stamp. `policy_isolation` is the company's raw declared
# override string ("qa:Demo,devops:Implementation" or "") — the same value
# cast.lex's grant report resolves, so the stamped preset and the report
# can never disagree. `dispatcher` is the worker id on the queue path,
# "inline" on the orchestrator path.
fn record_node_authority(db :: conn.ConnDb, company_id :: Str, sprint_id :: Str, node_id :: Str, role :: Str, model :: Str, api_calls_max :: Int, policy_isolation :: Str, dispatcher :: Str) -> [sql, fs_read, fs_write, time, random, crypto] Unit {
  let overrides := manifests.parse_isolation_overrides(policy_isolation)
  let preset := manifests.preset_for_kind_with_overrides(role, overrides)
  let role_env := budget.envelope_for(db, company_id, str.concat("role:", role))
  let total_env := budget.envelope_for(db, company_id, "total")
  tr.trail(db, sprint_id, "node_authority", authority_json(node_id, role, preset, model, api_calls_max, dispatcher, role_env, total_env))
}

