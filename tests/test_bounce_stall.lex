# test_bounce_stall.lex — regression coverage for the QA<->Implementation
# bounce-loop stagnation detector (orchestrator.bounce_stalled).
#
# Found live burning a real OpenCode subscription: build<->QA bounced the
# full max_qa_bounces() (4) every company iteration without the underlying
# defect (wrong framework, missing output format) ever actually changing --
# every round after the first was pure wasted spend once the denial reason
# stopped changing or the rebuild produced identical content. bounce_stalled
# is the pure predicate run_qa_with_bounce_tracked checks BEFORE spending
# tokens on another Implementation+QA round.

import "std.list" as list

import "../src/orchestrator" as orch

# First failure ever (no prior denial to compare against) must never be
# treated as stalled -- every sprint's first QA bounce has to be allowed.
fn test_first_failure_is_never_stalled() -> Result[Unit, Str] {
  if orch.bounce_stalled("verdict is FAIL", "", "hashA", "hashA") {
    Err("a first-ever denial (no prior_denial) must not be reported as stalled")
  } else {
    Ok(())
  }
}

# The exact bug scenario: the same denial reason comes back after a rebuild
# that was supposed to fix it.
fn test_identical_denial_is_stalled() -> Result[Unit, Str] {
  if orch.bounce_stalled("missing rfc2822 format", "missing rfc2822 format", "hashB", "hashA") {
    Ok(())
  } else {
    Err("expected an identical repeated denial to be flagged as stalled")
  }
}

# A different denial reason after a genuinely different rebuild is real
# progress, not a rabbit hole -- must be allowed to continue.
fn test_different_denial_and_changed_artifact_is_not_stalled() -> Result[Unit, Str] {
  if orch.bounce_stalled("missing rfc2822 format", "wrong framework (Flask not FastAPI)", "hashB", "hashA") {
    Err("a genuinely different denial with a changed artifact must not be flagged as stalled")
  } else {
    Ok(())
  }
}

# Even if the wording of the denial happens to differ, an unchanged
# (content-addressed) artifact hash means the rebuild produced byte-identical
# content -- no real fix attempt happened.
fn test_unchanged_artifact_is_stalled_even_with_different_wording() -> Result[Unit, Str] {
  if orch.bounce_stalled("slightly different phrasing this time", "missing rfc2822 format", "hashA", "hashA") {
    Ok(())
  } else {
    Err("expected an unchanged rebuild artifact to be flagged as stalled regardless of denial wording")
  }
}

# Found live (tzlocal iter-2): a py-qa node returned a correct FAIL naming a
# real bug, was denied by its own gate ("verdict is 'FAIL', expected 'PASS'"),
# and was RETRIED against the identical artifact. The second attempt returned
# PASS and the iteration sealed with a suite that genuinely failed 1 of 9.
# Retrying a judge that already gave a well-formed FAIL can only succeed if the
# model recants, so the node must fail and let the QA<->Implementation bounce
# send the work back to whoever can actually fix the code.
fn test_well_formed_fail_is_final() -> Result[Unit, Str] {
  if orch.verdict_fail_is_final("spec json-verdict-pass", "{\"verdict\":\"FAIL\",\"reason\":\"one test really fails\"}") {
    Ok(())
  } else {
    Err("a well-formed FAIL must be final, not retried against the same artifact")
  }
}

# A malformed verdict is a different failure: the artifact may be fine and only
# the reply shape was wrong, so the same node should get another attempt.
fn test_malformed_verdict_is_retryable() -> Result[Unit, Str] {
  if orch.verdict_fail_is_final("spec json-verdict-pass", "I could not produce JSON this time.") {
    Err("an unparseable verdict is a formatting failure and should still be retryable")
  } else {
    Ok(())
  }
}

fn test_pass_verdict_is_not_final_failure() -> Result[Unit, Str] {
  if orch.verdict_fail_is_final("spec json-verdict-pass", "{\"verdict\":\"PASS\"}") {
    Err("a PASS verdict is not a final failure")
  } else {
    Ok(())
  }
}

# Non-verdict gates keep their existing retry behaviour untouched.
fn test_other_gates_are_unaffected() -> Result[Unit, Str] {
  if orch.verdict_fail_is_final("spec compiles", "{\"verdict\":\"FAIL\"}") {
    Err("only json-verdict-pass gates should take the final-failure path")
  } else {
    Ok(())
  }
}

# A verdict value that is neither PASS nor FAIL asserts nothing about the
# artifact, so it is a formatting slip and must stay retryable. Being final is
# a claim about the CODE, and only the word FAIL makes that claim.
fn test_unexpected_verdict_value_is_retryable() -> Result[Unit, Str] {
  if orch.verdict_fail_is_final("spec json-verdict-pass", "{\"verdict\":\"inconclusive\"}") {
    Err("only an explicit FAIL should be final; an odd verdict value is a formatting slip")
  } else {
    Ok(())
  }
}

fn test_lowercase_fail_is_still_final() -> Result[Unit, Str] {
  if orch.verdict_fail_is_final("spec json-verdict-pass", "{\"verdict\":\"fail\"}") {
    Ok(())
  } else {
    Err("casing must not let a real FAIL slip through as retryable")
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_first_failure_is_never_stalled(), test_identical_denial_is_stalled(), test_different_denial_and_changed_artifact_is_not_stalled(), test_unchanged_artifact_is_stalled_even_with_different_wording(), test_well_formed_fail_is_final(), test_malformed_verdict_is_retryable(), test_pass_verdict_is_not_final_failure(), test_other_gates_are_unaffected(), test_unexpected_verdict_value_is_retryable(), test_lowercase_fail_is_still_final()]
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

