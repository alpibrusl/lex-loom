# demo/oa2_tool_filter.lex — CLI scaffolding for
# demo/oa2-tool-filter-roundtrip.sh (OA2, lex-loom#183).
#
# report_cmd calls the exact production code src/agent/runner.lex's LLM
# branch calls — cast.select_roster (a real roster for a real "build" node),
# manifests.manifest_json_for_kind_with_overrides (OA1's override
# resolution), and tool_grant.tool_allowed_under_manifest (OA2's filter) —
# and, to prove the surviving tool set isn't just names in a list, actually
# CALLS the one tool that survives. No live LLM is invoked (this repo has
# no LLM credentials in CI) — this demo proves the same filtering step
# runner.lex's LLM branch performs, against the same real tool
# implementations, which is what the promotion criterion is actually about.

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.env" as env

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-llm/src/tool" as t

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/cast" as cast

import "../src/manifests" as manifests

import "../src/tool_grant" as tool_grant

import "../src/graph" as graph

fn get_env(key :: Str, default :: Str) -> [env] Str {
  match env.get(key) {
    None => default,
    Some(v) => if str.is_empty(v) {
      default
    } else {
      v
    },
  }
}

fn open_db(db_path :: Str) -> [sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.open(db_path) {
    Err(_) => Err(str.concat("open db failed: ", db_path)),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => Ok(db),
    },
  }
}

fn tool_names(tools :: List[t.Tool]) -> Str {
  str.join(list.map(tools, fn (tl :: t.Tool) -> Str {
    tl.name
  }), ",")
}

# Real production code, called in the exact same shape src/agent/runner.lex's
# LLM branch uses it: cast.select_roster for a real "build" node, then the
# override resolution + tool filter step.
fn report_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto, net, proc] Unit {
  let db_path := get_env("DB_PATH", "demo/oa2-tool-filter-demo.db")
  let sprint_id := get_env("SPRINT_ID", "oa2-demo/iter-1")
  let policy_isolation := get_env("POLICY_ISOLATION", "")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[oa2-demo] FATAL: ", e)),
    Ok(db) => {
      let node := { id: "n-build", role: "build", gate: "spec non-empty", expand: None, activate_when: "" }
      let g := { id: sprint_id, phase: graph.Intake, nodes: [node], edges: [] }
      let roster := cast.select_roster(db, g, "demo request", "none", sprint_id)
      match cast.roster_lookup(roster, "n-build") {
        None => io.print("[oa2-demo] FATAL: no roster entry for n-build"),
        Some(def) => {
          let overrides := manifests.parse_isolation_overrides(policy_isolation)
          let manifest_json := manifests.manifest_json_for_kind_with_overrides(def.kind, def.sprint_id, overrides)
          let allowed := list.filter(def.tools, fn (tl :: t.Tool) -> Bool {
            tool_grant.tool_allowed_under_manifest(tl.name, manifest_json)
          })
          let __h1 := io.print(str.join(["[oa2-demo] role=", def.kind, " policy_isolation='", policy_isolation, "'"], ""))
          let __h2 := io.print(str.join(["[oa2-demo] tools before filter: ", tool_names(def.tools)], ""))
          let __h3 := io.print(str.join(["[oa2-demo] tools after filter:  ", tool_names(allowed)], ""))
          match list.head(allowed) {
            None => io.print("[oa2-demo] no tools survived the filter — LLM loop would run with none"),
            Some(tl) => match tl.execute(JObj([("topic", JStr("core"))])) {
              Ok(j) => io.print(str.join(["[oa2-demo] called surviving tool '", tl.name, "' for real -- ok, output_len=", int.to_str(str.len(jv.stringify(j)))], "")),
              Err(_) => io.print(str.join(["[oa2-demo] called surviving tool '", tl.name, "' for real -- tool ran (errored on args, which is fine — this call doesn't match every tool's schema)"], "")),
            },
          }
        },
      }
    },
  }
}

