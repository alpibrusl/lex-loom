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

# Found live (URL-shortener sprint, real kimi-k2.7-code run): py_qa's
# run_code tool hit a real ModuleNotFoundError (flask not installed),
# which annotate_missing_dependency (roles.lex) prefixes with the literal
# sentinel "[MISSING_DEPENDENCY]" -- but the QA agent still emitted
# {"verdict":"PASS",...} reasoning that the code "would pass in a Flask
# environment". run_code's own evidence file only records a boolean
# passed/failed, so the orchestrator's evidence cross-check
# (runner.verify_json_verdict_evidence) can be satisfied by ANY later
# run_code call that happens to pass -- even a trivial, unrelated one --
# without ever verifying that run actually exercised the real deliverable.
# This closes the cheapest version of that gap at the pure-gate layer:
# a PASS verdict whose own output text admits the sentinel is
# self-contradictory and denied outright, before the effectful evidence
# check even runs.
fn test_json_verdict_pass_allows_clean_pass() -> Result[Unit, Str] {
  allow("verdict PASS, no missing-dependency admission", "spec json-verdict-pass", "{\"verdict\":\"PASS\",\"reason\":\"all good\"}")
}

fn test_json_verdict_pass_denies_fail() -> Result[Unit, Str] {
  deny("verdict FAIL", "spec json-verdict-pass", "{\"verdict\":\"FAIL\",\"reason\":\"broke\"}")
}

fn test_json_verdict_pass_denies_missing_dependency_admission() -> Result[Unit, Str] {
  deny("verdict PASS but output admits MISSING_DEPENDENCY", "spec json-verdict-pass", "{\"verdict\":\"PASS\",\"reason\":\"would pass in a Flask environment\",\"output\":\"[MISSING_DEPENDENCY] No module named 'flask'\"}")
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

# Found live (local-model smoke sprint, 2026-08-27): a launch node was denied
# on 4 consecutive attempts with "trailing characters after JSON value" while
# emitting exactly the object its gate required -- wrapped in a ```json fence.
# Gates now narrow the output to its JSON body before parsing.
fn test_json_gate_accepts_fenced_payload() -> Result[Unit, Str] {
  match gates.evaluate("spec json-ok-true", "Here you go:\n```json\n{\"ok\": true}\n```\n") {
    GateAllow => Ok(()),
    GateDeny(r) => Err(str.concat("a fenced JSON payload should be accepted, got: ", r)),
  }
}

fn test_json_gate_accepts_payload_with_trailing_prose() -> Result[Unit, Str] {
  match gates.evaluate("spec json-ok-true", "{\"ok\": true}\n\nLet me know if you need anything else.") {
    GateAllow => Ok(()),
    GateDeny(r) => Err(str.concat("prose after the object should not deny it, got: ", r)),
  }
}

# The tolerance must not become a rubber stamp: a payload that really says
# ok=false still has to be denied.
fn test_json_gate_still_denies_false_inside_a_fence() -> Result[Unit, Str] {
  match gates.evaluate("spec json-ok-true", "```json\n{\"ok\": false}\n```") {
    GateAllow => Err("ok=false must still be denied, fence or not"),
    GateDeny(_) => Ok(()),
  }
}

fn test_json_gate_still_denies_output_with_no_json_at_all() -> Result[Unit, Str] {
  match gates.evaluate("spec json-ok-true", "I could not complete the task.") {
    GateAllow => Err("output containing no JSON at all must still be denied"),
    GateDeny(_) => Ok(()),
  }
}

# A model answering "pass" instead of "PASS" is agreeing, not failing. Denying
# it over casing sank a whole iteration live (tzlocal2 iter-2).
fn test_verdict_pass_is_case_insensitive() -> Result[Unit, Str] {
  match gates.evaluate("spec json-verdict-pass", "{\"verdict\":\"pass\",\"reason\":\"all tests green\"}") {
    GateAllow => Ok(()),
    GateDeny(r) => Err(str.concat("a lowercase pass should be accepted, got: ", r)),
  }
}

fn test_verdict_fail_still_denied_regardless_of_case() -> Result[Unit, Str] {
  match gates.evaluate("spec json-verdict-pass", "{\"verdict\":\"fail\",\"reason\":\"a test fails\"}") {
    GateAllow => Err("a FAIL must still be denied whatever its casing"),
    GateDeny(_) => Ok(()),
  }
}

# Real launch-node outputs, taken from failing runs. The node was denied four
# times in a row with "output is not valid JSON", which was true but useless:
# the actual problem was different each time, and one of them was a model
# claiming success for a tool it never called.
fn test_json_object_followed_by_a_text_tool_call_is_denied() -> Result[Unit, Str] {
  let out := "{\"ok\":true,\"url\":\"http://localhost:8080\",\"response\":\"\",\"pid\":\"\"}\n\n<function_calls>\n<invoke name=\"run_server\">"
  match gates.evaluate("spec json-ok-true", out) {
    GateAllow => Err("a claimed ok:true with an EMPTY response, next to the unmade call it claims to have made, must not pass"),
    GateDeny(r) => if str.contains(r, "written as TEXT") {
      Ok(())
    } else {
      Err(str.concat("the denial should name the real cause, not a parse error; got: ", r))
    },
  }
}

# A single object followed by the model second-guessing itself in prose. The
# object is complete and is the answer; the prose is not JSON and must not
# drag the parse down with it.
fn test_object_followed_by_self_correction_prose_is_read() -> Result[Unit, Str] {
  let out := "{\"ok\":false,\"url\":\"http://localhost:8080\",\"error\":\"no server binary\"}\n\nWait - I must actually attempt the launch as instructed."
  match gates.evaluate("spec json-ok-true", out) {
    GateAllow => Err("ok:false must still be denied"),
    GateDeny(r) => if str.contains(r, "'ok' field is false") {
      Ok(())
    } else {
      Err(str.concat("should be read as ok:false, not as malformed JSON; got: ", r))
    },
  }
}

# Two objects: the first must be read, not a span covering both (which parses
# as neither and produced the misleading "trailing characters" denial).
fn test_first_of_two_objects_is_extracted() -> Result[Unit, Str] {
  match gates.evaluate("spec json-ok-true", "{\"ok\":true}\nsome prose\n{\"ok\":false}") {
    GateAllow => Ok(()),
    GateDeny(r) => Err(str.concat("the first complete object should be read; got: ", r)),
  }
}

fn test_pure_prose_is_still_denied() -> Result[Unit, Str] {
  match gates.evaluate("spec json-ok-true", "Let me start by exploring the work directory.") {
    GateAllow => Err("prose with no JSON at all must be denied"),
    GateDeny(_) => Ok(()),
  }
}

# The same pathology appeared three times today with three different models and
# three different tools: a local model wrote lex_check as a ```json block,
# another wrote a raw argument dict, and a hosted model wrote
# <invoke name="run_server">. It is a framework-level failure, not a quirk of
# one gate, so every gate that accepts a structured CLAIM about work done now
# rejects it.
fn test_verdict_gate_rejects_a_text_tool_call() -> Result[Unit, Str] {
  let out := "{\"verdict\":\"PASS\",\"reason\":\"all tests pass\"}\n<invoke name=\"run_code\">"
  match gates.evaluate("spec json-verdict-pass", out) {
    GateAllow => Err("a PASS verdict next to the unmade call it claims to be based on must not pass"),
    GateDeny(r) => if str.contains(r, "written as TEXT") {
      Ok(())
    } else {
      Err(str.concat("should name the real cause; got: ", r))
    },
  }
}

fn test_plain_json_gate_rejects_a_text_tool_call() -> Result[Unit, Str] {
  match gates.evaluate("spec json", "{\"a\":1}\n<function_calls>") {
    GateAllow => Err("a structured claim beside an unmade tool call must not pass"),
    GateDeny(_) => Ok(()),
  }
}

# Prose gates must NOT trip on this. A docs or scribe node explaining a tool is
# doing its job, and denying it would be a false positive on the one kind of
# node whose output is meant to describe things.
fn test_prose_gate_is_not_tripped_by_the_word_invoke() -> Result[Unit, Str] {
  match gates.evaluate("spec len-gt 20", "To call it, write <invoke name=\"run_server\"> in your reply. This is documentation.") {
    GateAllow => Ok(()),
    GateDeny(r) => Err(str.concat("a docs node explaining a tool must not be denied; got: ", r)),
  }
}

fn test_clean_structured_claim_still_passes() -> Result[Unit, Str] {
  match gates.evaluate("spec json-ok-true", "{\"ok\":true,\"url\":\"http://localhost:8080\"}") {
    GateAllow => Ok(()),
    GateDeny(r) => Err(str.concat("a clean claim must still pass; got: ", r)),
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_empty_gate_always_denies(), test_non_empty_allows_content(), test_non_empty_denies_empty_output(), test_contains_allows_match(), test_contains_denies_no_match(), test_not_contains_allows_clean(), test_not_contains_denies_match(), test_starts_with_allows(), test_starts_with_denies(), test_json_allows_valid(), test_json_denies_invalid(), test_json_verdict_pass_allows_clean_pass(), test_json_verdict_pass_denies_fail(), test_json_verdict_pass_denies_missing_dependency_admission(), test_json_ok_true_allows_true(), test_json_ok_true_denies_false(), test_json_ok_true_denies_missing_field(), test_json_ok_true_denies_non_boolean(), test_json_ok_true_denies_invalid_json(), test_json_field_allows_present(), test_json_field_denies_missing(), test_len_gt_allows(), test_len_gt_denies(), test_unknown_gate_falls_back_to_non_empty(), test_compiles_is_grounded(), test_compiles_is_grounded_trimmed(), test_formal_gates_not_grounded(), test_json_gate_not_grounded(), test_json_ok_true_well_formed(), test_json_ok_true_gate_not_grounded(), test_judge_gate_recognized(), test_judge_well_formed(), test_sh_gate_recognized(), test_sh_well_formed(), test_judge_and_sh_not_plain_grounded(), test_json_gate_accepts_fenced_payload(), test_json_gate_accepts_payload_with_trailing_prose(), test_json_gate_still_denies_false_inside_a_fence(), test_json_gate_still_denies_output_with_no_json_at_all(), test_verdict_pass_is_case_insensitive(), test_verdict_fail_still_denied_regardless_of_case(), test_json_object_followed_by_a_text_tool_call_is_denied(), test_object_followed_by_self_correction_prose_is_read(), test_first_of_two_objects_is_extracted(), test_pure_prose_is_still_denied(), test_verdict_gate_rejects_a_text_tool_call(), test_plain_json_gate_rejects_a_text_tool_call(), test_prose_gate_is_not_tripped_by_the_word_invoke(), test_clean_structured_claim_still_passes()]
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

