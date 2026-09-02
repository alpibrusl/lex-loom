# test_py_shadow.lex — a model-written file must never be able to disable the
# Python toolchain it is checked by.
#
# Found live. A tzconvert run wrote `inspect.py` into its work dir while poking
# at the environment. The working directory comes first on sys.path, so that
# file hid the real stdlib `inspect` — and `python3 -m py_compile` imports
# traceback -> dataclasses -> inspect before it ever opens the file it was
# handed. Every compile from then on failed, blaming whichever innocent file
# was being checked. The builder believed the gate, concluded the Python
# toolchain was broken, and spent all three iterations writing shims to
# re-export the stdlib. It never wrote a line of the product.
#
# Two independent defences, one test each way round: the gate compiles under
# -P so the code under test cannot poison its own compiler, and py_check
# refuses the shadowing name at the moment of creation, where the error can
# still say something true.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.process" as proc

import "../src/agent/runner" as runner

import "../src/lex_skill" as lexskill

import "lex-schema/json_value" as jv

fn seed_py(sprint :: Str, filename :: Str, code :: Str) -> [io, proc] Unit {
  let dir := lexskill.py_work_dir(sprint)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, "; mkdir -p ", dir], "")])
  let __w := io.write(str.join([dir, "/", filename], ""), code)
  ()
}

fn tool_field(r :: jv.Json, key :: Str) -> Str {
  match jv.get_field(r, key) {
    Some(JStr(v)) => v,
    _ => "",
  }
}

fn py_check_tool(sprint :: Str, filename :: Str, code :: Str) -> [env, io, net, proc] Result[(Str, Str), Str] {
  let tool := lexskill.make_py_check_tool("/tmp/loom-evidence-test.json", sprint)
  match tool.execute(JObj([("filename", JStr(filename)), ("code", JStr(code))])) {
    Err(_) => Err("py_check errored"),
    Ok(r) => Ok((tool_field(r, "ok"), tool_field(r, "output"))),
  }
}

# The regression that cost three iterations: a stdlib-shadowing file sitting in
# the work dir must not stop the gate from compiling the real source beside it.
fn test_compiles_gate_survives_stdlib_shadow() -> [io, proc] Result[Unit, Str] {
  let sprint := "t-pyshadow-poison"
  let __s := seed_py(sprint, "server.py", "def convert(x):\n    return x\n")
  let dir := lexskill.py_work_dir(sprint)
  let __w := io.write(str.join([dir, "/inspect.py"], ""), "\"\"\"shadows the stdlib\"\"\"\n")
  match runner.verify_build_compiles("py_build", sprint) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a shadowing file in the work dir disabled the compiles gate: ", e)),
  }
}

# The gate must still be a gate: -P isolates the compiler, it does not soften it.
fn test_compiles_gate_still_fails_on_syntax_error() -> [io, proc] Result[Unit, Str] {
  let sprint := "t-pyshadow-broken"
  let __s := seed_py(sprint, "server.py", "def broken(\n")
  match runner.verify_build_compiles("py_build", sprint) {
    Ok(_) => Err("a syntax error must fail the compiles gate"),
    Err(_) => Ok(()),
  }
}

fn test_py_check_refuses_stdlib_name() -> [env, io, net, proc] Result[Unit, Str] {
  let sprint := "t-pyshadow-refuse"
  match py_check_tool(sprint, "inspect.py", "x = 1\n") {
    Err(e) => Err(e),
    Ok((ok, output)) => if ok == "false" {
      if str.contains(output, "shadows a Python standard-library module") {
        Ok(())
      } else {
        Err(str.concat("refused, but with the wrong message: ", output))
      }
    } else {
      Err("a filename that shadows a stdlib module must be refused")
    },
  }
}

# Refusing is only useful if it also declines to write: a file left on disk
# keeps poisoning every later import even though the agent was told no.
fn test_refused_stdlib_name_is_not_written() -> [env, io, net, proc] Result[Unit, Str] {
  let sprint := "t-pyshadow-nowrite"
  let dir := lexskill.py_work_dir(sprint)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, "; mkdir -p ", dir], "")])
  match py_check_tool(sprint, "inspect.py", "x = 1\n") {
    Err(e) => Err(e),
    Ok(_) => match proc.run("bash", ["-c", str.join(["test -e ", dir, "/inspect.py"], "")]) {
      Err(_) => Ok(()),
      Ok(r) => if r.exit_code == 0 {
        Err("py_check refused the name but wrote the file anyway")
      } else {
        Ok(())
      },
    },
  }
}

fn test_py_check_refuses_dotdot_filename() -> [env, io, net, proc] Result[Unit, Str] {
  match py_check_tool("t-pyshadow-dotdot", "../escape.py", "x = 1\n") {
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

# The negative control: the guard must not refuse ordinary product filenames.
fn test_py_check_still_accepts_a_normal_file() -> [env, io, net, proc] Result[Unit, Str] {
  match py_check_tool("t-pyshadow-ok", "server.py", "def convert(x):\n    return x\n") {
    Err(e) => Err(e),
    Ok((ok, output)) => if ok == "true" {
      Ok(())
    } else {
      Err(str.concat("a normal filename must still compile: ", output))
    },
  }
}

# lex_check and lex_run recorded tool-level evidence; py_check and ts_check
# recorded none. Surfaced by a review from the lex-code team, which looked in
# the wrong file but was right about the gap: a Lex build could show which files
# failed their check, and the Python and Node builds -- most of what these
# companies actually produce -- left no trail at all.
fn evidence_after_check(sprint :: Str, filename :: Str, code :: Str) -> [env, io, net, proc] Str {
  let ev := str.join(["/tmp/loom-evidence-", sprint, ".json"], "")
  let __rm := proc.run("bash", ["-c", str.concat("rm -f ", ev)])
  let tool := lexskill.make_py_check_tool(ev, sprint)
  match tool.execute(JObj([("filename", JStr(filename)), ("code", JStr(code))])) {
    Err(_) => "TOOL ERROR",
    Ok(_) => match proc.run("bash", ["-c", str.join(["cat ", ev, " 2>/dev/null"], "")]) {
      Err(_) => "",
      Ok(r) => str.trim(r.stdout),
    },
  }
}

fn test_py_check_records_a_failing_file() -> [env, io, net, proc] Result[Unit, Str] {
  let ev := evidence_after_check("t-ev-bad", "broken.py", "def broken(\n")
  if str.contains(ev, "broken.py") {
    Ok(())
  } else {
    Err(str.concat("a failed py_check must leave the filename in the evidence trail, got: ", ev))
  }
}

# The control: a passing check must NOT leave the file marked failed, or the
# trail would condemn every build it recorded.
fn test_py_check_does_not_record_a_passing_file_as_failed() -> [env, io, net, proc] Result[Unit, Str] {
  let ev := evidence_after_check("t-ev-good", "fine.py", "def fine():\n    return 1\n")
  if str.contains(ev, "fine.py") {
    Err(str.concat("a passing py_check must not mark the file failed: ", ev))
  } else {
    Ok(())
  }
}

fn run_all() -> [env, io, net, proc] Int {
  let results := [("compiles gate survives stdlib shadow", test_compiles_gate_survives_stdlib_shadow()), ("compiles gate still fails on syntax error", test_compiles_gate_still_fails_on_syntax_error()), ("py_check refuses stdlib name", test_py_check_refuses_stdlib_name()), ("refused stdlib name is not written", test_refused_stdlib_name_is_not_written()), ("py_check refuses dotdot filename", test_py_check_refuses_dotdot_filename()), ("py_check still accepts a normal file", test_py_check_still_accepts_a_normal_file()), ("py_check records a failing file", test_py_check_records_a_failing_file()), ("py_check does not record a passing file as failed", test_py_check_does_not_record_a_passing_file_as_failed())]
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

