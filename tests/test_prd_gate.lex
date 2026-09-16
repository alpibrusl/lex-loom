# test_prd_gate.lex — the pm gate has to be able to REFUSE, and has to be able
# to ACCEPT.
#
# The pm gate was `spec len-gt 50`: any 51 characters passed. That single fact
# explains two things at once. loom's improvement loop keys tightened_specs by
# the role whose GATE failed, so twelve iterations never tightened the pm; and
# the eval suite measures accept rate, which against a gate that cannot fail is
# 5/5 forever. Meanwhile the pm caused five consecutive QA refusals (#495).
#
# Half these tests exist because my FIRST draft of the checker was wrong in the
# expensive direction. It required every decision in the goal to be REPEATED in
# the PRD, and refused a perfectly good PRD for writing "a short success
# message" where the goal said "a short plain-text success message". A gate
# that refuses good work is worse than no gate: the pm cannot tell which of its
# words was the problem, and bounces until the iteration budget runs out.
# test_paraphrase_is_not_a_contradiction is the negative control for that, and
# it failed against the first draft.

import "std.str" as str

import "std.io" as io

import "std.list" as list

import "../bin/check_prd" as prd

fn goal() -> Str {
  "Build the smallest form-submission server. It stores the submission in a local SQLite database with a timestamp, returns 200 with a short plain-text success message, and 400 naming the missing field."
}

fn good_prd() -> Str {
  str.join(["## Goal\nA minimal Lex HTTP server storing form submissions.\n\n", "## User Stories\n- As a developer, I want a valid POST stored and acknowledged.\n\n", "## Acceptance Criteria\n1. POST /f/demo with a urlencoded body carrying name and email returns HTTP 200 and a short success message.\n2. POST /f/demo missing email returns HTTP 400 and the message names the missing field.\n3. A valid submission is persisted to the SQLite store with a timestamp.\n\n", "## Out of Scope\nSpam filtering, dashboard, CSV.\n"], "")
}

fn accepts(v :: Str) -> Bool {
  str.starts_with(v, "ACCEPT")
}

fn test_a_prd_that_narrows_the_goal_is_accepted() -> Result[Unit, Str] {
  if accepts(prd.verdict(good_prd(), goal())) {
    Ok(())
  } else {
    Err(str.join(["a well-formed PRD was refused: ", prd.verdict(good_prd(), goal())], ""))
  }
}

# The negative control for the over-strict first draft. The goal says "short
# plain-text success message"; the PRD says "a short success message". That is
# the pm doing its job, and the gate must not punish it. Vocabulary is not
# checkable; contradiction is.
fn test_paraphrase_is_not_a_contradiction() -> Result[Unit, Str] {
  let paraphrased := str.replace(good_prd(), "a short success message", "an acknowledgement the caller can read")
  if accepts(prd.verdict(paraphrased, goal())) {
    Ok(())
  } else {
    Err("the gate refused a PRD for paraphrasing the goal rather than contradicting it — the failure mode that makes a gate worse than no gate")
  }
}

# Live failure: a goal saying SQLite became acceptance criteria about "the
# in-memory vector length". The build followed the goal, QA judged the PRD, and
# the iteration was lost to the gap.
fn test_a_prd_that_reverses_a_goal_decision_is_refused() -> Result[Unit, Str] {
  let reversed := str.replace(good_prd(), "persisted to the SQLite store with a timestamp", "appended to the in-memory vector")
  let v := prd.verdict(reversed, goal())
  if accepts(v) {
    Err("the PRD swapped SQLite for an in-memory vector and the gate passed it — exactly the #495 failure")
  } else {
    if str.contains(v, "in-memory") {
      Ok(())
    } else {
      Err(str.join(["refused, but without naming the contradiction the pm has to fix: ", v], ""))
    }
  }
}

# A criterion QA cannot point at is not a criterion.
fn test_prose_acceptance_criteria_are_refused() -> Result[Unit, Str] {
  let stub := str.replace(good_prd(), "1. POST /f/demo with a urlencoded body carrying name and email returns HTTP 200 and a short success message.\n2. POST /f/demo missing email returns HTTP 400 and the message names the missing field.\n3. A valid submission is persisted to the SQLite store with a timestamp.", "It should work well.")
  match accepts(prd.verdict(stub, goal())) {
    true => Err("\"It should work well.\" passed as acceptance criteria"),
    false => Ok(()),
  }
}

fn test_a_missing_section_is_refused() -> Result[Unit, Str] {
  let truncated := str.replace(good_prd(), "## Out of Scope\nSpam filtering, dashboard, CSV.\n", "")
  let v := prd.verdict(truncated, goal())
  if accepts(v) {
    Err("a PRD with no Out of Scope section passed")
  } else {
    if str.contains(v, "Out of Scope") {
      Ok(())
    } else {
      Err(str.join(["refused without naming which section is missing: ", v], ""))
    }
  }
}

# Live failure: a PRD pinned `200 body: "ok"`; the build answered "Form
# submitted.", satisfied the goal exactly, and was failed three iterations
# running.
fn test_a_pinned_prose_body_is_refused() -> Result[Unit, Str] {
  let pinned := str.replace(good_prd(), "returns HTTP 200 and a short success message", "returns HTTP 200, body: \"ok\"")
  match accepts(prd.verdict(pinned, goal())) {
    true => Err("a byte-exact plain-text body passed — the pm is allowed to fail a correct build for choosing different words"),
    false => Ok(()),
  }
}

# Structured data IS pinnable exactly. Only prose is not, and the distinction
# has to survive in the checker or the rule becomes "never say body".
fn test_a_pinned_json_body_is_allowed() -> Result[Unit, Str] {
  let pinned := str.replace(good_prd(), "returns HTTP 200 and a short success message", "returns HTTP 200, body: \"{\\\"ok\\\":true}\"")
  if accepts(prd.verdict(pinned, goal())) {
    Ok(())
  } else {
    Err("a JSON response body was refused as if it were prose — a contract the build can actually meet")
  }
}

# The gate runs where the goal may not be on disk. Structure is still checkable
# there; only the grounding check needs the ledger.
fn test_structure_is_still_checked_without_a_goal() -> Result[Unit, Str] {
  if accepts(prd.verdict(good_prd(), "")) {
    let stub := str.replace(good_prd(), "## Goal\nA minimal Lex HTTP server storing form submissions.\n\n", "")
    match accepts(prd.verdict(stub, "")) {
      true => Err("with no goal the gate stopped checking structure too"),
      false => Ok(()),
    }
  } else {
    Err("a good PRD was refused merely because no goal file was available")
  }
}

fn run_all() -> [io] Int {
  let results := [("a PRD that narrows the goal is accepted", test_a_prd_that_narrows_the_goal_is_accepted()), ("paraphrase is not a contradiction", test_paraphrase_is_not_a_contradiction()), ("a PRD that reverses a goal decision is refused", test_a_prd_that_reverses_a_goal_decision_is_refused()), ("prose acceptance criteria are refused", test_prose_acceptance_criteria_are_refused()), ("a missing section is refused", test_a_missing_section_is_refused()), ("a pinned prose body is refused", test_a_pinned_prose_body_is_refused()), ("a pinned JSON body is allowed", test_a_pinned_json_body_is_allowed()), ("structure is still checked without a goal", test_structure_is_still_checked_without_a_goal())]
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

