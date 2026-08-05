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

# ── Preset naming (OA1, lex-loom#182) ────────────────────────────────────────
fn test_preset_name_for_kind_matches_build() -> Result[Unit, Str] {
  let p := manifests.preset_name_for_kind("build")
  if p == "Implementation" {
    Ok(())
  } else {
    Err(str.concat("expected Implementation for build, got ", p))
  }
}

fn test_preset_name_for_kind_matches_qa() -> Result[Unit, Str] {
  let p := manifests.preset_name_for_kind("qa")
  if p == "QA" {
    Ok(())
  } else {
    Err(str.concat("expected QA for qa, got ", p))
  }
}

fn test_preset_name_for_kind_unmapped_falls_back_to_demo() -> Result[Unit, Str] {
  let p := manifests.preset_name_for_kind("some_future_role")
  if p == "Demo" {
    Ok(())
  } else {
    Err(str.concat("expected Demo for an unmapped role, got ", p))
  }
}

# manifest_json_for_kind must stay byte-for-byte the same as before the OA1
# refactor into preset_name_for_kind + manifest_json_for_preset — this is
# the same assertion test_build_gets_sandboxed_exec already makes, restated
# here to document that the refactor is the thing under test.
fn test_manifest_json_for_kind_matches_preset_composition() -> Result[Unit, Str] {
  let direct := manifests.manifest_json_for_kind("build", "sprint-test")
  let composed := manifests.manifest_json_for_preset(manifests.preset_name_for_kind("build"), "sprint-test")
  if direct == composed {
    Ok(())
  } else {
    Err(str.join(["expected manifest_json_for_kind to equal the preset composition, got '", direct, "' vs '", composed, "'"], ""))
  }
}

# ── [policy.isolation] override resolution (OA1, lex-loom#182) ──────────────
fn test_parse_isolation_overrides_empty_string() -> Result[Unit, Str] {
  let pairs := manifests.parse_isolation_overrides("")
  if list.is_empty(pairs) {
    Ok(())
  } else {
    Err(str.concat("expected no pairs for an empty string, got ", int.to_str(list.len(pairs))))
  }
}

fn test_parse_isolation_overrides_parses_pairs() -> Result[Unit, Str] {
  let pairs := manifests.parse_isolation_overrides("qa:Demo, devops:Implementation")
  if list.len(pairs) == 2 {
    Ok(())
  } else {
    Err(str.concat("expected 2 pairs, got ", int.to_str(list.len(pairs))))
  }
}

fn test_parse_isolation_overrides_skips_malformed_segments() -> Result[Unit, Str] {
  let pairs := manifests.parse_isolation_overrides("qa:Demo,garbage,:Implementation,devops:")
  if list.len(pairs) == 1 {
    Ok(())
  } else {
    Err(str.concat("expected malformed segments dropped (1 pair left), got ", int.to_str(list.len(pairs))))
  }
}

fn test_preset_for_kind_with_overrides_honors_override() -> Result[Unit, Str] {
  let overrides := manifests.parse_isolation_overrides("build:Demo")
  let p := manifests.preset_for_kind_with_overrides("build", overrides)
  if p == "Demo" {
    Ok(())
  } else {
    Err(str.concat("expected the override (Demo) to win over build's default (Implementation), got ", p))
  }
}

fn test_preset_for_kind_with_overrides_falls_back_without_override() -> Result[Unit, Str] {
  let overrides := manifests.parse_isolation_overrides("build:Demo")
  let p := manifests.preset_for_kind_with_overrides("qa", overrides)
  if p == "QA" {
    Ok(())
  } else {
    Err(str.concat("expected qa's own default (QA) when no override names it, got ", p))
  }
}

# A mistyped preset name in the override table must fall back to the same
# safe default (Demo) an unmapped role kind already gets -- never fail-open
# into an unrecognised, un-resolvable preset.
fn test_manifest_json_for_kind_with_overrides_mistyped_preset_falls_back_to_demo() -> Result[Unit, Str] {
  let overrides := manifests.parse_isolation_overrides("build:Nonexistent")
  let j := manifests.manifest_json_for_kind_with_overrides("build", "sprint-test", overrides)
  let demo_j := manifests.manifest_json_for_preset("Demo", "sprint-test")
  if j == demo_j {
    Ok(())
  } else {
    Err(str.join(["expected a mistyped override preset to fall back to Demo, got '", j, "'"], ""))
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_build_gets_sandboxed_exec(), test_py_build_gets_sandboxed_exec(), test_fe_build_gets_sandboxed_exec(), test_qa_gets_sandboxed_exec(), test_py_qa_gets_sandboxed_exec(), test_security_gets_sandboxed_exec(), test_scribe_gets_no_exec(), test_unmapped_role_defaults_to_no_exec(), test_unmapped_role_defaults_to_readonly_fs(), test_build_gets_readwrite_fs(), test_qa_gets_readonly_fs(), test_preset_name_for_kind_matches_build(), test_preset_name_for_kind_matches_qa(), test_preset_name_for_kind_unmapped_falls_back_to_demo(), test_manifest_json_for_kind_matches_preset_composition(), test_parse_isolation_overrides_empty_string(), test_parse_isolation_overrides_parses_pairs(), test_parse_isolation_overrides_skips_malformed_segments(), test_preset_for_kind_with_overrides_honors_override(), test_preset_for_kind_with_overrides_falls_back_without_override(), test_manifest_json_for_kind_with_overrides_mistyped_preset_falls_back_to_demo()]
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

