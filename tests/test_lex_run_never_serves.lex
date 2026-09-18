# test_lex_run_never_serves.lex — lex-loom#523: the lex_run tool never
# starts a server. Live failure: QA ran `main.lex main` (a server entry point)
# through lex_run; the call never returned; the worker sat in it until the
# 30-min phase await timed out and the phase bounced — twice.
#
#   1. fn_name='main' is refused before anything runs (no lex process at all);
#   2. a run that does not return is killed at the wall-clock limit and says
#      so (##TIMEOUT), ok=false;
#   3. a normal test run (run_all that returns) is untouched by the limit.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.process" as proc

import "lex-schema/json_value" as jv

import "../src/lex_skill" as lexskill

fn sprint() -> Str {
  "lexrun-never-serves"
}

fn work_dir() -> Str {
  str.join(["/tmp/loom-lex-work-", sprint()], "")
}

fn evidence() -> Str {
  "/tmp/loom-lexrun-never-serves-evidence.json"
}

# A program whose `serve` blocks (like net.serve would) and whose `quick`
# returns at once.
fn program() -> Str {
  str.join(["import \"std.process\" as proc\n", "\n", "fn serve() -> [proc] Int {\n", "  let __ := proc.run(\"bash\", [\"-c\", \"sleep 60\"])\n", "  0\n", "}\n", "\n", "fn quick() -> Int {\n", "  0\n", "}\n"], "")
}

fn clean() -> [proc] Unit {
  let __ := proc.run("bash", ["-c", str.join(["rm -rf '", work_dir(), "' '", evidence(), "'"], "")])
  ()
}

fn ran_ok(out :: jv.Json) -> Bool {
  match jv.get_field(out, "ok") {
    Some(JStr(v)) => v == "true",
    _ => false,
  }
}

fn output_of(out :: jv.Json) -> Str {
  match jv.get_field(out, "output") {
    Some(JStr(v)) => v,
    _ => "",
  }
}

fn write_program() -> [net, io, proc] Result[Unit, Str] {
  let check := lexskill.make_lex_check_tool(evidence(), sprint())
  match check.execute(JObj([("filename", JStr("svc.lex")), ("code", JStr(program()))])) {
    Err(_) => Err("lex_check tool call failed"),
    Ok(out) => if ran_ok(out) {
      Ok(())
    } else {
      Err(str.concat("fixture does not compile: ", str.slice(output_of(out), 0, 200)))
    },
  }
}

fn test_main_is_refused_without_running() -> [net, io, proc] Result[Unit, Str] {
  let __c := clean()
  let run := lexskill.make_lex_run_tool_with_limit(evidence(), sprint(), 2)
  match run.execute(JObj([("filename", JStr("nope.lex")), ("fn_name", JStr("main")), ("args", JStr(""))])) {
    Err(_) => Err("lex_run tool call failed"),
    Ok(out) => {
      let txt := output_of(out)
      if ran_ok(out) {
        Err("fn_name=main reported ok")
      } else {
        if str.contains(txt, "refused") and str.contains(txt, "run_all") and not str.contains(txt, "##EXIT") {
          Ok(())
        } else {
          Err(str.concat("main was not refused up front: ", str.slice(txt, 0, 200)))
        }
      }
    },
  }
}

fn test_a_run_that_never_returns_is_killed_at_the_limit() -> [net, io, proc] Result[Unit, Str] {
  let __c := clean()
  match write_program() {
    Err(m) => Err(m),
    Ok(_) => {
      let run := lexskill.make_lex_run_tool_with_limit(evidence(), sprint(), 2)
      match run.execute(JObj([("filename", JStr("svc.lex")), ("fn_name", JStr("serve")), ("args", JStr(""))])) {
        Err(_) => Err("lex_run tool call failed"),
        Ok(out) => {
          let txt := output_of(out)
          let __c2 := clean()
          if ran_ok(out) {
            Err("a run that never returns reported ok")
          } else {
            if str.contains(txt, "##TIMEOUT") and str.contains(txt, "2s") {
              Ok(())
            } else {
              Err(str.concat("no timeout notice in the output: ", str.slice(txt, 0, 200)))
            }
          }
        },
      }
    },
  }
}

fn test_a_normal_run_is_untouched() -> [net, io, proc] Result[Unit, Str] {
  let __c := clean()
  match write_program() {
    Err(m) => Err(m),
    Ok(_) => {
      let run := lexskill.make_lex_run_tool_with_limit(evidence(), sprint(), 2)
      match run.execute(JObj([("filename", JStr("svc.lex")), ("fn_name", JStr("quick")), ("args", JStr(""))])) {
        Err(_) => Err("lex_run tool call failed"),
        Ok(out) => {
          let txt := output_of(out)
          let __c2 := clean()
          if ran_ok(out) and not str.contains(txt, "##TIMEOUT") {
            Ok(())
          } else {
            Err(str.concat("a quick fn did not run cleanly under the limit: ", str.slice(txt, 0, 200)))
          }
        },
      }
    },
  }
}

fn suite() -> [net, io, proc] List[Result[Unit, Str]] {
  [test_main_is_refused_without_running(), test_a_run_that_never_returns_is_killed_at_the_limit(), test_a_normal_run_is_untouched()]
}

fn run_all() -> [net, io, proc] Unit {
  let results := suite()
  let __dbg := list.map(results, fn (r :: Result[Unit, Str]) -> [io] Unit {
    match r {
      Ok(_) => (),
      Err(e) => io.print(str.concat("FAIL: ", e)),
    }
  })
  let failures := list.fold(results, 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
  if failures == 0 {
    io.print("ok   3 lex_run never-serves tests")
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

