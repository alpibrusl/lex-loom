# dump_config.lex — the effective company configuration, with provenance
# (#247, from the deepseek-harness review).
#
# A company's configuration is decided across five layers: compiled
# defaults → the company row (captured from company.toml + env at
# bootstrap) → run-time environment variables → [policy.isolation]
# overrides → board-set spend envelopes. Debugging "why did this agent run
# with that model/grant/budget" meant reading four modules and the DB by
# hand. This module prints every effective field annotated with the layer
# that decided it.
#
# The load-bearing rule (dsh's strongest boot-layer idea): THE EXPLAINER
# SHARES CODE WITH THE EXECUTOR. Values here come from the same functions
# the runtime calls — defaults.resolved_model / resolved_exec_mode,
# manifests.preset_for_kind_with_overrides (cast.lex's own resolution),
# budget.load_envelopes — never from a parallel reimplementation, so the
# dump cannot drift from what actually runs.

import "std.env" as env

import "std.int" as int

import "std.list" as list

import "std.str" as str

import "lex-orm/src/connection" as conn

import "./budget" as budget

import "./company" as company

import "./defaults" as defaults

import "./manifests" as manifests

import "./role_kinds" as role_kinds

type Line = { field :: Str, value :: Str, source :: Str }

fn render_line(l :: Line) -> Str
  examples {
    render_line({ field: "exec_mode", value: "inline", source: "default" }) => "exec_mode = inline    # default"
  }
{
  str.join([l.field, " = ", l.value, "    # ", l.source], "")
}

fn env_source(var :: Str, default_label :: Str) -> [env] Str {
  match env.get(var) {
    None => default_label,
    Some(v) => if str.is_empty(v) {
      default_label
    } else {
      str.join(["env ", var], "")
    },
  }
}

fn row_value(v :: Str) -> Str {
  if str.is_empty(v) {
    "(unset)"
  } else {
    v
  }
}

# The company row is authoritative for company runs — env MODEL only feeds
# the row at bootstrap. If the env is set NOW and disagrees with the row,
# say so explicitly: that mismatch is the single most common "why didn't my
# MODEL take effect" confusion.
fn model_lines(ccfg :: company.CompanyCfg) -> [env] List[Line] {
  let base := [{ field: "model", value: ccfg.model, source: "company row (captured at bootstrap: MODEL -> OLLAMA_MODEL -> default)" }]
  let now := defaults.resolved_model()
  if now == ccfg.model {
    base
  } else {
    list.concat(base, [{ field: "model (env, IGNORED)", value: now, source: "the environment resolves differently, but the company row wins for company runs" }])
  }
}

fn runtime_lines() -> [env] List[Line] {
  [{ field: "exec_mode", value: defaults.resolved_exec_mode(), source: env_source("EXEC_MODE", "default \"inline\"") }, { field: "worker_count", value: defaults.get_env("WORKER_COUNT", "1"), source: env_source("WORKER_COUNT", "default \"1\"") }, { field: "event_poll_ms", value: defaults.get_env("EVENT_POLL_MS", "2000"), source: env_source("EVENT_POLL_MS", "default \"2000\"") }, { field: "api_calls_max", value: defaults.get_env("MAX_API_CALLS", "200"), source: env_source("MAX_API_CALLS", "default \"200\"") }]
}

fn row_lines(ccfg :: company.CompanyCfg) -> List[Line] {
  [{ field: "goal", value: row_value(ccfg.goal), source: "company row" }, { field: "max_iterations", value: int.to_str(ccfg.max_iterations), source: "company row" }, { field: "stop_when", value: row_value(ccfg.stop_when), source: "company row" }, { field: "pmf_when", value: row_value(ccfg.pmf_when), source: "company row" }, { field: "maintenance_when", value: row_value(ccfg.maintenance_when), source: "company row" }, { field: "wake_when", value: row_value(ccfg.wake_when), source: "company row" }, { field: "soft.mesh_url", value: row_value(ccfg.soft_mesh_url), source: "company row [soft]" }, { field: "soft.org_id", value: row_value(ccfg.soft_org_id), source: "company row [soft]" }, { field: "soft.roles", value: row_value(ccfg.soft_roles), source: "company row [soft]" }, { field: "soft.settlement", value: row_value(ccfg.soft_settlement), source: "company row [soft]" }]
}

# One line per role kind, resolved through the SAME function cast.lex uses
# to grant a roster (so this table and the cast can never disagree), with
# the deciding layer named per role.
fn isolation_lines(ccfg :: company.CompanyCfg) -> List[Line] {
  let overrides := manifests.parse_isolation_overrides(ccfg.policy_isolation)
  list.map(role_kinds.known_kinds(), fn (kind :: Str) -> Line {
    let preset := manifests.preset_for_kind_with_overrides(kind, overrides)
    let overridden := preset != manifests.preset_name_for_kind(kind)
    { field: str.concat("isolation.", kind), value: preset, source: if overridden {
      "[policy.isolation] override"
    } else {
      "kind default"
    } }
  })
}

fn envelope_lines(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] List[Line] {
  let envs := budget.load_envelopes(db, company_id)
  if list.is_empty(envs) {
    [{ field: "budget", value: "(no envelopes)", source: "company DB" }]
  } else {
    list.map(envs, fn (e :: budget.Envelope) -> Line {
      { field: str.concat("budget.", e.scope), value: str.join(["cap ", int.to_str(e.cap_cents), "c, spent ", int.to_str(e.spent_cents), "c"], ""), source: "company DB (set_envelope)" }
    })
  }
}

fn dump_lines(db :: conn.ConnDb, ccfg :: company.CompanyCfg) -> [env, sql, fs_read] List[Line] {
  list.concat(model_lines(ccfg), list.concat(runtime_lines(), list.concat(row_lines(ccfg), list.concat(isolation_lines(ccfg), envelope_lines(db, ccfg.id)))))
}

fn render(lines :: List[Line]) -> Str {
  str.join(list.map(lines, fn (l :: Line) -> Str {
    render_line(l)
  }), "\n")
}

# Refuse, don't guess: an unknown company id is an error, not an empty dump.
fn dump(db :: conn.ConnDb, company_id :: Str) -> [env, sql, fs_read] Result[Str, Str] {
  match company.load_company(db, company_id) {
    None => Err(str.join(["no company '", company_id, "' in this workspace"], "")),
    Some(ccfg) => Ok(str.join([str.join(["# effective configuration for company '", company_id, "' — value  # deciding layer"], ""), render(dump_lines(db, ccfg))], "\n")),
  }
}

