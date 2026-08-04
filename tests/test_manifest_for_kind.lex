import "std.list" as list

import "std.str" as str

import "../src/manifests" as manifests

fn has_exec(label :: Str, kind :: Str, expected_exec :: Str) -> Result[Unit, Str] {
  let j := manifests.manifest_json_for_kind(kind, "sprint-test")
  let needle := str.concat("\"exec\":\"", str.concat(expected_exec, "\""))
  if str.contains(j, needle) {
    Ok(())
  } else {
    Err(str.join([label, ": expected exec=", expected_exec, " in ", j], ""))
  }
}

fn test_build_gets_sandboxed_exec() -> Result[Unit, Str] {
  has_exec("build", "build", "Sandboxed")
}

fn test_py_build_gets_sandboxed_exec() -> Result[Unit, Str] {
  has_exec("py_build", "py_build", "Sandboxed")
}

fn test_fe_build_gets_sandboxed_exec() -> Result[Unit, Str] {
  has_exec("fe_build", "fe_build", "Sandboxed")
}

fn test_qa_gets_sandboxed_exec() -> Result[Unit, Str] {
  has_exec("qa", "qa", "Sandboxed")
}

fn test_py_qa_gets_sandboxed_exec() -> Result[Unit, Str] {
  has_exec("py_qa", "py_qa", "Sandboxed")
}

fn test_security_gets_sandboxed_exec() -> Result[Unit, Str] {
  has_exec("security", "security", "Sandboxed")
}

fn test_scribe_gets_no_exec() -> Result[Unit, Str] {
  has_exec("scribe", "scribe", "None")
}

# Any role not explicitly mapped must default to no exec authority — the
# safe default (docs/design/lex-os-isolation.md), never fail-open.
fn test_unmapped_role_defaults_to_no_exec() -> Result[Unit, Str] {
  has_exec("architect (unmapped)", "architect", "None")
}

fn test_unmapped_role_defaults_to_readonly_fs() -> Result[Unit, Str] {
  let j := manifests.manifest_json_for_kind("some_future_role", "sprint-test")
  if str.contains(j, "\"filesystem\":\"ReadOnly\"") {
    Ok(())
  } else {
    Err(str.concat("expected filesystem=ReadOnly for an unmapped role, got ", j))
  }
}

fn test_build_gets_readwrite_fs() -> Result[Unit, Str] {
  let j := manifests.manifest_json_for_kind("build", "sprint-test")
  if str.contains(j, "\"filesystem\":\"ReadWrite\"") {
    Ok(())
  } else {
    Err(str.concat("expected filesystem=ReadWrite for build, got ", j))
  }
}

fn test_qa_gets_readonly_fs() -> Result[Unit, Str] {
  let j := manifests.manifest_json_for_kind("qa", "sprint-test")
  if str.contains(j, "\"filesystem\":\"ReadOnly\"") {
    Ok(())
  } else {
    Err(str.concat("expected filesystem=ReadOnly for qa, got ", j))
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_build_gets_sandboxed_exec(), test_py_build_gets_sandboxed_exec(), test_fe_build_gets_sandboxed_exec(), test_qa_gets_sandboxed_exec(), test_py_qa_gets_sandboxed_exec(), test_security_gets_sandboxed_exec(), test_scribe_gets_no_exec(), test_unmapped_role_defaults_to_no_exec(), test_unmapped_role_defaults_to_readonly_fs(), test_build_gets_readwrite_fs(), test_qa_gets_readonly_fs()]
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

