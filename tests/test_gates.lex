import "std.list" as list

import "std.str" as str

import "../src/gates" as gates

fn allow(label :: Str, gate :: Str, output :: Str) -> Result[Unit, Str] {
  match gates.evaluate(gate, output) {
    GateAllow => Ok(()),
    GateDeny(msg) => Err(str.join([label, " expected Allow, got Deny: ", msg], "")),
  }
}

fn deny(label :: Str, gate :: Str, output :: Str) -> Result[Unit, Str] {
  match gates.evaluate(gate, output) {
    GateDeny(_) => Ok(()),
    GateAllow => Err(str.concat(label, " expected Deny, got Allow")),
  }
}

fn test_empty_gate_always_denies() -> Result[Unit, Str] {
  deny("empty gate", "", "any output")
}

fn test_non_empty_allows_content() -> Result[Unit, Str] {
  allow("non-empty with content", "spec non-empty", "hello world")
}

fn test_non_empty_denies_empty_output() -> Result[Unit, Str] {
  deny("non-empty with empty", "spec non-empty", "")
}

fn test_contains_allows_match() -> Result[Unit, Str] {
  allow("contains PASS match", "spec contains PASS", "QA verdict: PASS")
}

fn test_contains_denies_no_match() -> Result[Unit, Str] {
  deny("contains PASS no match", "spec contains PASS", "QA verdict: FAIL")
}

fn test_not_contains_allows_clean() -> Result[Unit, Str] {
  allow("not-contains ERROR clean", "spec not-contains ERROR", "all good")
}

fn test_not_contains_denies_match() -> Result[Unit, Str] {
  deny("not-contains ERROR found", "spec not-contains ERROR", "ERROR: something failed")
}

fn test_starts_with_allows() -> Result[Unit, Str] {
  allow("starts-with fn", "spec starts-with fn ", "fn reverse(xs :: List[Str]) -> List[Str] {")
}

fn test_starts_with_denies() -> Result[Unit, Str] {
  deny("starts-with fn fails on prose", "spec starts-with fn ", "here is a function")
}

fn test_json_allows_valid() -> Result[Unit, Str] {
  allow("json valid", "spec json", "{\"ok\": true}")
}

fn test_json_denies_invalid() -> Result[Unit, Str] {
  deny("json invalid", "spec json", "not json at all")
}

# launch/deploy nodes return {"ok": true|false, ...} from a real tool
# (run_server / deploy_hetzner) — "spec json" alone accepts a well-formed
# {"ok": false, "error": "..."} just as happily as a real success, so a
# launch that genuinely never started the server still passed its gate.
fn test_json_ok_true_allows_true() -> Result[Unit, Str] {
  allow("json-ok-true with ok:true", "spec json-ok-true", "{\"ok\": true, \"url\": \"http://localhost:8080\"}")
}

fn test_json_ok_true_denies_false() -> Result[Unit, Str] {
  deny("json-ok-true with ok:false", "spec json-ok-true", "{\"ok\": false, \"error\": \"server did not respond within 20s\"}")
}

fn test_json_ok_true_denies_missing_field() -> Result[Unit, Str] {
  deny("json-ok-true missing ok field", "spec json-ok-true", "{\"url\": \"http://localhost:8080\"}")
}

fn test_json_ok_true_denies_non_boolean() -> Result[Unit, Str] {
  deny("json-ok-true non-boolean ok field", "spec json-ok-true", "{\"ok\": \"true\"}")
}

fn test_json_ok_true_denies_invalid_json() -> Result[Unit, Str] {
  deny("json-ok-true invalid json", "spec json-ok-true", "not json at all")
}

fn test_json_field_allows_present() -> Result[Unit, Str] {
  allow("json-field id present", "spec json-field id", "{\"id\": \"sprint-1\", \"phase\": \"Design\"}")
}

fn test_json_field_denies_missing() -> Result[Unit, Str] {
  deny("json-field id missing", "spec json-field id", "{\"phase\": \"Design\"}")
}

fn test_len_gt_allows() -> Result[Unit, Str] {
  allow("len-gt 5 on longer string", "spec len-gt 5", "hello world")
}

fn test_len_gt_denies() -> Result[Unit, Str] {
  deny("len-gt 20 on short string", "spec len-gt 20", "short")
}

fn test_unknown_gate_falls_back_to_non_empty() -> Result[Unit, Str] {
  allow("unknown gate with content", "spec whatever-unknown", "some output")
}

# ── Grounded-gate classifier (#32) ────────────────────────────────────────────
fn is_grounded_eq(label :: Str, gate :: Str, expected :: Bool) -> Result[Unit, Str] {
  if gates.is_grounded(gate) == expected {
    Ok(())
  } else {
    Err(str.concat(label, ": is_grounded mismatch"))
  }
}

fn test_compiles_is_grounded() -> Result[Unit, Str] {
  is_grounded_eq("spec compiles", "spec compiles", true)
}

fn test_compiles_is_grounded_trimmed() -> Result[Unit, Str] {
  is_grounded_eq("  spec compiles  ", "  spec compiles  ", true)
}

fn test_formal_gates_not_grounded() -> Result[Unit, Str] {
  is_grounded_eq("spec len-gt 50", "spec len-gt 50", false)
}

fn test_json_gate_not_grounded() -> Result[Unit, Str] {
  is_grounded_eq("spec json", "spec json", false)
}

# ── Attestation-tier classifiers: LLM-judge + grounded shell gate (#21) ────────
fn test_judge_gate_recognized() -> Result[Unit, Str] {
  if gates.is_llm_judge("spec judge \"names the product, has a CTA\"") {
    if gates.judge_criteria("spec judge \"names the product, has a CTA\"") == "\"names the product, has a CTA\"" {
      Ok(())
    } else {
      Err("judge_criteria extraction wrong")
    }
  } else {
    Err("spec judge not recognized as llm-judge")
  }
}

fn test_judge_well_formed() -> Result[Unit, Str] {
  if gates.is_well_formed("spec judge \"clear and concise\"") {
    Ok(())
  } else {
    Err("spec judge should be well-formed")
  }
}

fn test_sh_gate_recognized() -> Result[Unit, Str] {
  if gates.is_shell_gate("spec sh \"docker build -t app .\"") {
    if gates.shell_command("spec sh \"docker build -t app .\"") == "docker build -t app ." {
      Ok(())
    } else {
      Err(str.concat("shell_command extraction wrong: ", gates.shell_command("spec sh \"docker build -t app .\"")))
    }
  } else {
    Err("spec sh not recognized as shell gate")
  }
}

fn test_sh_well_formed() -> Result[Unit, Str] {
  if gates.is_well_formed("spec sh \"semgrep --error .\"") {
    Ok(())
  } else {
    Err("spec sh should be well-formed")
  }
}

fn test_json_ok_true_well_formed() -> Result[Unit, Str] {
  if gates.is_well_formed("spec json-ok-true") {
    Ok(())
  } else {
    Err("spec json-ok-true should be well-formed")
  }
}

fn test_json_ok_true_gate_not_grounded() -> Result[Unit, Str] {
  is_grounded_eq("spec json-ok-true", "spec json-ok-true", false)
}

fn test_judge_and_sh_not_plain_grounded() -> Result[Unit, Str] {
  if gates.is_grounded("spec judge \"x\"") {
    Err("judge is not the compiles-grounded lane")
  } else {
    if gates.is_grounded("spec sh \"x\"") {
      Err("sh is not the compiles-grounded lane")
    } else {
      Ok(())
    }
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_empty_gate_always_denies(), test_non_empty_allows_content(), test_non_empty_denies_empty_output(), test_contains_allows_match(), test_contains_denies_no_match(), test_not_contains_allows_clean(), test_not_contains_denies_match(), test_starts_with_allows(), test_starts_with_denies(), test_json_allows_valid(), test_json_denies_invalid(), test_json_ok_true_allows_true(), test_json_ok_true_denies_false(), test_json_ok_true_denies_missing_field(), test_json_ok_true_denies_non_boolean(), test_json_ok_true_denies_invalid_json(), test_json_field_allows_present(), test_json_field_denies_missing(), test_len_gt_allows(), test_len_gt_denies(), test_unknown_gate_falls_back_to_non_empty(), test_compiles_is_grounded(), test_compiles_is_grounded_trimmed(), test_formal_gates_not_grounded(), test_json_gate_not_grounded(), test_json_ok_true_well_formed(), test_json_ok_true_gate_not_grounded(), test_judge_gate_recognized(), test_judge_well_formed(), test_sh_gate_recognized(), test_sh_well_formed(), test_judge_and_sh_not_plain_grounded()]
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

