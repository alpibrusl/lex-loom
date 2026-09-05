# test_step_budget_not_content.lex — running out of steps is not an answer
# (#324).
#
# lex-llm returns "[max_steps reached]" when an agent exhausts its step budget.
# That string reached loom's gates as ordinary content, so a node that produced
# nothing at all could satisfy `spec non-empty` — a gate passing on the literal
# text that says the work did not happen. The comment above max_steps_for
# already documented the symptom ("returned [max_steps reached] with the
# artifact only recoverable from the work dir") without anything acting on it.
#
# It belongs with the provider-error case, not the empty-output one: a retry is
# right, and so is a reason naming the real cause. What it must not be is
# content.

import "std.str" as str

import "std.list" as list

import "../src/orchestrator" as orch

fn test_step_exhaustion_is_recognised() -> Result[Unit, Str] {
  if orch.is_step_budget_exhausted("[max_steps reached]") {
    Ok(())
  } else {
    Err("the step-budget message is treated as an ordinary answer, so `spec non-empty` passes on it")
  }
}

# lex-llm 3e37dd3 now streams the message as a TextChunk before StepDone, so it
# can arrive with the turn's partial output around it rather than alone.
fn test_it_is_recognised_when_not_alone() -> Result[Unit, Str] {
  if orch.is_step_budget_exhausted("some partial thinking\n[max_steps reached]") {
    Ok(())
  } else {
    Err("the message is only recognised when it is the entire output, so a partial answer hides it")
  }
}

# The negative control. A check that answered true for everything would satisfy
# both tests above while failing every node in the system.
fn test_a_real_answer_is_not_mistaken_for_exhaustion() -> Result[Unit, Str] {
  let wrongly := list.filter(["{\"verdict\":\"PASS\"}", "the build is complete", "", "[provider error: HTTP 401]"], fn (out :: Str) -> Bool {
    orch.is_step_budget_exhausted(out)
  })
  if list.is_empty(wrongly) {
    Ok(())
  } else {
    Err("ordinary output was classified as step exhaustion")
  }
}

# Both failures are infra, and they must stay distinguishable: they have
# different fixes — raise the budget, versus fix the provider — and a gate
# reporting the wrong cause is what sends the repair loop the wrong way.
fn test_both_are_infra_but_stay_distinct() -> Result[Unit, Str] {
  if orch.is_infra_outcome("[max_steps reached]") {
    if orch.is_infra_outcome("[provider error: HTTP 401]") {
      if orch.is_step_budget_exhausted("[provider error: HTTP 401]") {
        Err("a provider error is reported as a step-budget problem, which would send someone to raise a budget that is not the cause")
      } else {
        Ok(())
      }
    } else {
      Err("a provider error stopped counting as infra")
    }
  } else {
    Err("step exhaustion is not treated as infra, so it is retried as though the content were at fault")
  }
}

fn test_ordinary_output_is_not_infra() -> Result[Unit, Str] {
  if orch.is_infra_outcome("{\"verdict\":\"PASS\"}") {
    Err("a real answer was classified as an infrastructure failure, which would retry every passing node")
  } else {
    Ok(())
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_step_exhaustion_is_recognised(), test_it_is_recognised_when_not_alone(), test_a_real_answer_is_not_mistaken_for_exhaustion(), test_both_are_infra_but_stay_distinct(), test_ordinary_output_is_not_infra()]
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

