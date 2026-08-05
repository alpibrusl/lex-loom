# test_lex_os_exec_args.lex — regression coverage for OA3's
# real-vs-simulated `lex-os exec` arg construction (lex-loom#184):
# src/agent/runner.lex's lex_os_exec_args.
#
# lex_os_exec_step's actual proc.run("lex-os", ...) call can't be exercised
# here — no lex-os binary is installed in this environment, matching Phase
# 0's own precedent (docs/design/lex-os-isolation.md: "no live end-to-end
# test in loom's own CI"). This is the dependency-free proof on the
# arg-construction side that precedent already established: what lex-os
# actually decides for real hardware is out of loom's control, but what
# ARGS loom hands it is fully within loom's control and fully testable.

import "std.list" as list

import "std.str" as str

import "../src/agent/runner" as runner

fn test_unsimulated_omits_the_flag() -> Result[Unit, Str] {
  let joined := str.join(runner.lex_os_exec_args(false, "manifest.json", "echo hi"), " ")
  if str.contains(joined, "--simulated") {
    Err(str.concat("expected no --simulated flag when simulated=false, got: ", joined))
  } else {
    Ok(())
  }
}

fn test_simulated_includes_the_flag() -> Result[Unit, Str] {
  let joined := str.join(runner.lex_os_exec_args(true, "manifest.json", "echo hi"), " ")
  if str.contains(joined, "--simulated") {
    Ok(())
  } else {
    Err(str.concat("expected --simulated flag when simulated=true, got: ", joined))
  }
}

fn test_manifest_path_and_cmd_are_threaded_through() -> Result[Unit, Str] {
  let joined := str.join(runner.lex_os_exec_args(true, "/tmp/m.json", "run-me"), " ")
  if str.contains(joined, "/tmp/m.json") {
    if str.contains(joined, "run-me") {
      Ok(())
    } else {
      Err("expected the shell command to appear in the args")
    }
  } else {
    Err("expected the manifest path to appear in the args")
  }
}

fn test_args_end_with_bash_dash_c_cmd() -> Result[Unit, Str] {
  let joined := str.join(runner.lex_os_exec_args(false, "manifest.json", "echo hi"), " ")
  if str.ends_with(joined, "bash -c echo hi") {
    Ok(())
  } else {
    Err(str.concat("expected the args to end with 'bash -c echo hi', got: ", joined))
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_unsimulated_omits_the_flag(), test_simulated_includes_the_flag(), test_manifest_path_and_cmd_are_threaded_through(), test_args_end_with_bash_dash_c_cmd()]
}

fn run_all() -> Unit {
  let failures := list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
  if failures == 0 {
    ()
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

