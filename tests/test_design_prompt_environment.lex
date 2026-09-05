# test_design_prompt_environment.lex — the architect must be TOLD what the
# environment can do, not just rejected afterwards for not knowing (#318).
#
# In a local run the architect proposed a deploy node three times in a row.
# Each graph was rejected whole by metaspec's deploy-needs-a-real-target rule,
# so the constraint reached the model only as a post-hoc rejection — and after
# the third attempt the sprint fails outright. The information was available
# before the first call and simply never sent.
#
# It goes in the per-sprint INPUT rather than the architect's system prompt:
# system prompts are persisted in agent_pool and replayed in later sprints
# (#312), where "deploy is unavailable" would be wrong the moment an operator
# arms an environment.

import "std.str" as str

import "std.list" as list

import "../src/orchestrator" as orch

fn prompt_for(deploy_allowed :: Bool) -> Str {
  orch.design_prompt("PRD: build a timezone API", "convert timestamps between zones", deploy_allowed)
}

fn test_a_local_run_is_told_not_to_deploy() -> Result[Unit, Str] {
  let p := prompt_for(false)
  if str.contains(p, "deploys nowhere") {
    if str.contains(p, "Do NOT include a deploy node") {
      Ok(())
    } else {
      Err("the note describes the environment but never says what to do about it")
    }
  } else {
    Err("a local run's architect prompt says nothing about the environment being unable to deploy")
  }
}

# The other direction matters as much: an operator who arms an environment must
# not have the architect told deploy is impossible. A note that is always
# present would satisfy the test above while being wrong half the time.
fn test_a_real_target_is_not_told_to_skip_deploy() -> Result[Unit, Str] {
  let p := prompt_for(true)
  if str.contains(p, "Do NOT include a deploy node") {
    Err("an environment that CAN deploy was still told not to — arming a target would no longer produce deploy nodes")
  } else {
    Ok(())
  }
}

# And the note must be additive: the PRD and the original request still have to
# reach the architect intact.
fn test_the_prd_and_request_still_reach_the_architect() -> Result[Unit, Str] {
  let missing := list.filter(["build a timezone API", "convert timestamps between zones"], fn (needle :: Str) -> Bool {
    not str.contains(prompt_for(false), needle)
  })
  if list.is_empty(missing) {
    Ok(())
  } else {
    Err("the environment note displaced content the architect needs")
  }
}

# The retry path carries the same constraint: rejections are where the model is
# most likely to re-propose the node it was just refused.
fn test_the_retry_prompt_carries_it_too() -> Result[Unit, Str] {
  let r := orch.design_retry_prompt("PRD: build a timezone API", "convert timestamps", "metaspec: deploy-needs-a-real-target", false)
  if str.contains(r, "Do NOT include a deploy node") {
    Ok(())
  } else {
    Err("the retry prompt drops the environment note, so a rejected architect is told the rule but not the capability")
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_a_local_run_is_told_not_to_deploy(), test_a_real_target_is_not_told_to_skip_deploy(), test_the_prd_and_request_still_reach_the_architect(), test_the_retry_prompt_carries_it_too()]
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

