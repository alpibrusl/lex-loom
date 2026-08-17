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

fn run_all() -> [io, proc] Int {
  let results := [("ts compiles gate passes on real ts", test_ts_compiles_gate_passes_on_real_ts()), ("ts compiles gate fails on syntax error", test_ts_compiles_gate_fails_on_syntax_error()), ("ts compiles gate fails on empty work dir", test_ts_compiles_gate_fails_on_empty_work_dir()), ("ts roster rows agree", test_ts_roster_rows_agree())]
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

