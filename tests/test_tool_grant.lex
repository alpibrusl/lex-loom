# test_tool_grant.lex — regression coverage for OA2's Grant-derived tool
# filter (lex-loom#183): src/tool_grant.lex.

import "std.list" as list

import "std.str" as str

import "../src/manifests" as manifests

import "../src/tool_grant" as tool_grant

# ── level_rank ────────────────────────────────────────────────────────────────
fn test_level_rank_orders_none_below_everything() -> Result[Unit, Str] {
  if tool_grant.level_rank("None") < tool_grant.level_rank("Sandboxed") {
    Ok(())
  } else {
    Err("expected None to rank below Sandboxed")
  }
}

fn test_level_rank_full_is_highest() -> Result[Unit, Str] {
  if tool_grant.level_rank("Full") > tool_grant.level_rank("Allowlist") {
    Ok(())
  } else {
    Err("expected Full to rank above Allowlist")
  }
}

fn test_level_rank_sandboxed_and_allowlist_are_same_tier() -> Result[Unit, Str] {
  if tool_grant.level_rank("Sandboxed") == tool_grant.level_rank("Loopback") {
    Ok(())
  } else {
    Err("expected Sandboxed and Loopback to rank at the same tier (both dimension-specific names for rank 1)")
  }
}

fn test_level_rank_unrecognised_ranks_as_none() -> Result[Unit, Str] {
  if tool_grant.level_rank("NotARealLevel") == tool_grant.level_rank("None") {
    Ok(())
  } else {
    Err("expected an unrecognised level to rank as if it were None — never fail-open on a typo")
  }
}

# ── grant_level_for_dimension ─────────────────────────────────────────────────
fn test_grant_level_for_dimension_reads_a_real_manifest() -> Result[Unit, Str] {
  let j := manifests.implementation_manifest_json("sprint-test")
  if tool_grant.grant_level_for_dimension(j, "exec") == "Sandboxed" {
    Ok(())
  } else {
    Err(str.concat("expected Implementation's exec grant to read as Sandboxed, got ", tool_grant.grant_level_for_dimension(j, "exec")))
  }
}

fn test_grant_level_for_dimension_defaults_to_none_on_malformed_json() -> Result[Unit, Str] {
  if tool_grant.grant_level_for_dimension("not json", "exec") == "None" {
    Ok(())
  } else {
    Err("expected malformed manifest JSON to read as None — the safe, no-authority default")
  }
}

fn test_grant_level_for_dimension_defaults_to_none_on_missing_field() -> Result[Unit, Str] {
  if tool_grant.grant_level_for_dimension("{}", "exec") == "None" {
    Ok(())
  } else {
    Err("expected a manifest with no grant field to read as None")
  }
}

# ── tool_allowed_under_manifest ───────────────────────────────────────────────
fn test_tool_with_no_requirement_is_always_allowed() -> Result[Unit, Str] {
  let j := manifests.demo_manifest_json("sprint-test")
  if tool_grant.tool_allowed_under_manifest("lex_guidelines", j) {
    Ok(())
  } else {
    Err("expected lex_guidelines (no requirement) to be allowed under even the Demo preset")
  }
}

fn test_lex_check_allowed_under_implementation() -> Result[Unit, Str] {
  let j := manifests.implementation_manifest_json("sprint-test")
  if tool_grant.tool_allowed_under_manifest("lex_check", j) {
    Ok(())
  } else {
    Err("expected lex_check (needs exec:Sandboxed) to be allowed under Implementation's exec:Sandboxed grant")
  }
}

fn test_lex_check_denied_under_demo() -> Result[Unit, Str] {
  let j := manifests.demo_manifest_json("sprint-test")
  if tool_grant.tool_allowed_under_manifest("lex_check", j) {
    Err("expected lex_check (needs exec:Sandboxed) to be denied under Demo's exec:None grant")
  } else {
    Ok(())
  }
}

fn test_deploy_hetzner_denied_under_qa_despite_sandboxed_exec() -> Result[Unit, Str] {
  let j := manifests.qa_manifest_json("sprint-test")
  if tool_grant.tool_allowed_under_manifest("deploy_hetzner", j) {
    Err("expected deploy_hetzner (needs exec:Full) to be denied under QA's exec:Sandboxed grant — Sandboxed < Full")
  } else {
    Ok(())
  }
}

fn test_fetch_support_items_allowed_under_every_preset() -> Result[Unit, Str] {
  let presets := [manifests.design_manifest_json("s"), manifests.implementation_manifest_json("s"), manifests.qa_manifest_json("s"), manifests.demo_manifest_json("s"), manifests.retro_manifest_json("s")]
  let all_ok := list.fold(presets, true, fn (acc :: Bool, j :: Str) -> Bool {
    acc and tool_grant.tool_allowed_under_manifest("fetch_support_items", j)
  })
  if all_ok {
    Ok(())
  } else {
    Err("expected fetch_support_items (needs network:Allowlist) to be allowed under every built-in preset (all grant network:Allowlist uniformly)")
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_level_rank_orders_none_below_everything(), test_level_rank_full_is_highest(), test_level_rank_sandboxed_and_allowlist_are_same_tier(), test_level_rank_unrecognised_ranks_as_none(), test_grant_level_for_dimension_reads_a_real_manifest(), test_grant_level_for_dimension_defaults_to_none_on_malformed_json(), test_grant_level_for_dimension_defaults_to_none_on_missing_field(), test_tool_with_no_requirement_is_always_allowed(), test_lex_check_allowed_under_implementation(), test_lex_check_denied_under_demo(), test_deploy_hetzner_denied_under_qa_despite_sandboxed_exec(), test_fetch_support_items_allowed_under_every_preset()]
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

