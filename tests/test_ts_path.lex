# test_ts_path.lex — the Node/TS golden path's grounded plumbing (#92).
#
# The path is only real when its gates are: these tests prove the
# `spec compiles` gate for ts_build actually runs Node's syntax check
# against the files the node wrote (pass on real TS, fail on a syntax
# error, fail on an empty work dir — never a silent allow), and that the
# roster/tooling rows agree with the rest of the vocabulary.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.process" as proc

import "../src/agent/runner" as runner

import "../src/role_tools" as rt

import "../src/role_kinds" as role_kinds

import "../src/lex_skill" as lexskill

import "lex-schema/json_value" as jv

fn seed(sprint :: Str, filename :: Str, code :: Str) -> [io, proc] Unit {
  let dir := lexskill.ts_work_dir(sprint)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, "; mkdir -p ", dir], "")])
  let __w := io.write(str.join([dir, "/", filename], ""), code)
  ()
}

fn test_ts_compiles_gate_passes_on_real_ts() -> [io, proc] Result[Unit, Str] {
  let sprint := "t-tspath-good"
  let __s := seed(sprint, "app.ts", "const x: number = 1;\nexport function double(n: number): number {\n  return n * 2;\n}\nconsole.log(x);\n")
  match runner.verify_build_compiles("ts_build", sprint) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("expected real TS to pass the compiles gate, got: ", e)),
  }
}

fn test_ts_compiles_gate_fails_on_syntax_error() -> [io, proc] Result[Unit, Str] {
  let sprint := "t-tspath-bad"
  let __s := seed(sprint, "app.ts", "const x: number = ;\nfunction {{\n")
  match runner.verify_build_compiles("ts_build", sprint) {
    Ok(_) => Err("expected a syntax error to fail the compiles gate"),
    Err(e) => if str.contains(e, "COMPILE_FAIL") {
      Ok(())
    } else {
      Err(str.concat("failed, but not with COMPILE_FAIL: ", e))
    },
  }
}

fn test_ts_compiles_gate_fails_on_empty_work_dir() -> [io, proc] Result[Unit, Str] {
  let sprint := "t-tspath-empty"
  let dir := lexskill.ts_work_dir(sprint)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, "; mkdir -p ", dir], "")])
  match runner.verify_build_compiles("ts_build", sprint) {
    Ok(_) => Err("expected an empty work dir to fail (prose, not code)"),
    Err(e) => if str.contains(e, "no ts source files") {
      Ok(())
    } else {
      Err(str.concat("failed, but not with the no-source message: ", e))
    },
  }
}

fn test_ts_roster_rows_agree() -> Result[Unit, Str] {
  let has := fn (xs :: List[Str], x :: Str) -> Bool {
    list.fold(xs, false, fn (found :: Bool, e :: Str) -> Bool {
      found or e == x
    })
  }
  if rt.tools_for("ts_build") == ["ts_check"] {
    if rt.tools_for("ts_qa") == ["run_node_code"] {
      if has(role_kinds.known_kinds(), "ts_build") {
        if has(role_kinds.known_kinds(), "ts_qa") {
          Ok(())
        } else {
          Err("ts_qa missing from role_kinds.known_kinds")
        }
      } else {
        Err("ts_build missing from role_kinds.known_kinds")
      }
    } else {
      Err("ts_qa should wield exactly [run_node_code]")
    }
  } else {
    Err("ts_build should wield exactly [ts_check]")
  }
}

# ── ts_check file-type dispatch (#92 web-pwa) ────────────────────────────────
# The one build tool writes the whole project: code is syntax-checked, JSON
# manifests are parse-checked, static assets are stored — and a bad file of
# any checkable type is refused, never silently accepted.
fn tool_result_field(r :: jv.Json, key :: Str) -> Str {
  match jv.get_field(r, key) {
    Some(JStr(v)) => v,
    _ => "",
  }
}

fn check_tool(filename :: Str, code :: Str) -> [env, io, net, proc] Result[(Str, Str), Str] {
  let tool := lexskill.make_ts_check_tool("t-tspath-dispatch")
  match tool.execute(JObj([("filename", JStr(filename)), ("code", JStr(code))])) {
    Err(_) => Err("ts_check errored"),
    Ok(r) => Ok((tool_result_field(r, "ok"), tool_result_field(r, "output"))),
  }
}

fn test_ts_check_stores_static_assets() -> [env, io, net, proc] Result[Unit, Str] {
  match check_tool("public/styles.css", "body { margin: 0; }") {
    Err(e) => Err(e),
    Ok((ok, output)) => if ok == "true" {
      if output == "stored" {
        Ok(())
      } else {
        Err(str.concat("expected output 'stored' for css, got: ", output))
      }
    } else {
      Err("css asset should be accepted as stored")
    },
  }
}

fn test_ts_check_parse_checks_manifest() -> [env, io, net, proc] Result[Unit, Str] {
  match check_tool("public/manifest.webmanifest", "{\"name\": \"x\", }") {
    Err(e) => Err(e),
    Ok((ok, _)) => if ok == "false" {
      match check_tool("public/manifest.webmanifest", "{\"name\": \"x\"}") {
        Err(e) => Err(e),
        Ok((ok2, _)) => if ok2 == "true" {
          Ok(())
        } else {
          Err("valid manifest JSON should pass")
        },
      }
    } else {
      Err("trailing-comma manifest should fail JSON.parse")
    },
  }
}

fn test_ts_check_still_refuses_bad_ts() -> [env, io, net, proc] Result[Unit, Str] {
  match check_tool("bad.ts", "const x: number = ;") {
    Err(e) => Err(e),
    Ok((ok, _)) => if ok == "false" {
      Ok(())
    } else {
      Err("bad TS should still be refused")
    },
  }
}

fn test_ts_check_refuses_dotdot_filename() -> [env, io, net, proc] Result[Unit, Str] {
  match check_tool("../escape.ts", "const x = 1;") {
    Err(e) => Err(e),
    Ok((ok, output)) => if ok == "false" {
      if str.contains(output, "plain relative path") {
        Ok(())
      } else {
        Err(str.concat("refused, but with the wrong message: ", output))
      }
    } else {
      Err("a '..' filename must be refused")
    },
  }
}

fn run_all() -> [env, io, net, proc] Int {
  let results := [("ts compiles gate passes on real ts", test_ts_compiles_gate_passes_on_real_ts()), ("ts compiles gate fails on syntax error", test_ts_compiles_gate_fails_on_syntax_error()), ("ts compiles gate fails on empty work dir", test_ts_compiles_gate_fails_on_empty_work_dir()), ("ts roster rows agree", test_ts_roster_rows_agree()), ("ts_check stores static assets", test_ts_check_stores_static_assets()), ("ts_check parse-checks manifest", test_ts_check_parse_checks_manifest()), ("ts_check still refuses bad ts", test_ts_check_still_refuses_bad_ts()), ("ts_check refuses dotdot filename", test_ts_check_refuses_dotdot_filename())]
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

