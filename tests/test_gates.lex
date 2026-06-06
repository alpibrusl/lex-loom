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

fn suite() -> List[Result[Unit, Str]] {
  [test_empty_gate_always_denies(), test_non_empty_allows_content(), test_non_empty_denies_empty_output(), test_contains_allows_match(), test_contains_denies_no_match(), test_not_contains_allows_clean(), test_not_contains_denies_match(), test_starts_with_allows(), test_starts_with_denies(), test_json_allows_valid(), test_json_denies_invalid(), test_json_field_allows_present(), test_json_field_denies_missing(), test_len_gt_allows(), test_len_gt_denies(), test_unknown_gate_falls_back_to_non_empty()]
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

