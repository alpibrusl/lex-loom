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

fn suite() -> List[Result[Unit, Str]] {
  [test_first_failure_is_never_stalled(), test_identical_denial_is_stalled(), test_different_denial_and_changed_artifact_is_not_stalled(), test_unchanged_artifact_is_stalled_even_with_different_wording()]
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

