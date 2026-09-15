# test_qa_can_run_a_service.lex — QA must be able to EXECUTE the product it is
# judging, not only type-check it.
#
# lex_run's --allow-effects was a fixed list -- io, fs_read, fs_write, time,
# random, crypto, net -- and it cannot run a web service. A service reads its
# port from the environment and opens a database, so its row carries `env` and
# `sql` at minimum, and Lex rows are PER-PROGRAM: importing lex-web unions in
# its whole transitive closure, 13 effects including llm, proc and approval.
#
# Found live (alpibrusl/lex-loom#496 thread). A company's QA refused a working
# form server with
#
#   main.lex returns ok='false' from lex_run (effect-gating errors for
#   env/sql/concurrent/llm/proc/approval not in --allow-effects, EXIT 3)
#
# and an earlier iteration's hand-written product -- row `env, fs_write, io,
# net, sql` -- was equally unrunnable, short by `env` and `sql`. On this path
# QA was never judging behaviour; it was reporting a sandbox mismatch, and the
# verdict said FAIL either way.
#
# `lex check` prints the row a program declares. That row is in the source,
# reviewable, and is what Lex's own effect system enforces -- granting exactly
# it is narrower than any fixed list wide enough to be useful, and it tracks a
# product's imports as they change.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.process" as proc

import "lex-schema/json_value" as jv

import "../src/lex_skill" as lexskill

import "../src/agent/runner" as runner

fn sprint() -> Str {
  "qa-service-test"
}

fn work_dir() -> Str {
  str.join(["/tmp/loom-lex-work-", sprint()], "")
}

fn evidence() -> Str {
  "/tmp/loom-qa-service-evidence.json"
}

# A program shaped like every real service: reads the environment, opens a
# database. Neither effect is in the old fixed list.
fn service_source() -> Str {
  str.join(["import \"std.io\" as io\n", "import \"std.env\" as env\n", "import \"std.sql\" as sql\n", "\n", "fn run_all() -> [env, io, sql, fs_write] Int {\n", "  let __ := match env.get(\"QA_SERVICE_PROBE\") {\n", "    Some(v) => io.print(v),\n", "    None => io.print(\"no probe\"),\n", "  }\n", "  match sql.open(\"/tmp/loom-qa-service-probe.db\") {\n", "    Err(_) => 1,\n", "    Ok(db) => {\n", "      let __c := sql.close(db)\n", "      0\n", "    },\n", "  }\n", "}\n"], "")
}

fn clean() -> [proc] Unit {
  let __ := proc.run("bash", ["-c", str.join(["rm -rf '", work_dir(), "' /tmp/loom-qa-service-probe.db '", evidence(), "'"], "")])
  ()
}

fn ran_ok(out :: jv.Json) -> Bool {
  match jv.get_field(out, "ok") {
    Some(JStr(v)) => v == "true",
    Some(JBool(b)) => b,
    _ => false,
  }
}

fn output_of(out :: jv.Json) -> Str {
  match jv.get_field(out, "output") {
    Some(JStr(v)) => v,
    _ => "",
  }
}

# The whole point: a service-shaped program runs, and its effects are not the
# thing that fails it.
fn test_a_service_shaped_program_runs() -> [net, io, proc] Result[Unit, Str] {
  let __c := clean()
  let check := lexskill.make_lex_check_tool(evidence(), sprint())
  match check.execute(JObj([("filename", JStr("svc.lex")), ("code", JStr(service_source()))])) {
    Err(_) => Err("lex_check tool call failed"),
    Ok(_) => {
      let run := lexskill.make_lex_run_tool(evidence(), sprint())
      match run.execute(JObj([("filename", JStr("svc.lex")), ("fn_name", JStr("run_all")), ("args", JStr(""))])) {
        Err(_) => Err("lex_run tool call failed"),
        Ok(out) => {
          let txt := output_of(out)
          let __c2 := clean()
          if str.contains(txt, "effect_not_allowed") {
            Err(str.concat("QA still cannot execute a program that reads env and opens a database: ", str.slice(txt, 0, 160)))
          } else {
            if ran_ok(out) {
              Ok(())
            } else {
              Err(str.concat("the service did not run: ", str.slice(txt, 0, 160)))
            }
          }
        },
      }
    },
  }
}

# A file that does not compile has no declared row. It must still RUN and
# report its own error, not an effects error stacked on top of it.
fn test_an_uncompilable_file_still_reports_its_own_error() -> [net, io, proc] Result[Unit, Str] {
  let __c := clean()
  let run := lexskill.make_lex_run_tool(evidence(), sprint())
  match run.execute(JObj([("filename", JStr("broken.lex")), ("fn_name", JStr("run_all")), ("args", JStr(""))])) {
    Err(_) => Err("lex_run tool call failed on a missing file"),
    Ok(out) => {
      let __c2 := clean()
      if ran_ok(out) {
        Err("a file that does not exist reported success")
      } else {
        Ok(())
      }
    },
  }
}

# The prelude is what carries the row to the runner, and its fallback is what
# keeps a broken file runnable.
fn test_the_prelude_derives_and_falls_back() -> Result[Unit, Str] {
  let p := lexskill.declared_effects_prelude("/tmp/x.lex")
  if str.contains(p, "required effects") {
    if str.contains(p, "io,fs_read,fs_write,time,random,crypto,net") {
      Ok(())
    } else {
      Err("the prelude has no fallback, so a file that cannot be checked cannot be run")
    }
  } else {
    Err("the prelude does not read the row the program declares")
  }
}

fn run_all() -> [net, io, proc] Int {
  let results := [("a service-shaped program runs", test_a_service_shaped_program_runs()), ("an uncompilable file still reports its own error", test_an_uncompilable_file_still_reports_its_own_error()), ("the prelude derives and falls back", test_the_prelude_derives_and_falls_back())]
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

