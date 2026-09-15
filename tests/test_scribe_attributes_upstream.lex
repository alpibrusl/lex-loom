# test_scribe_attributes_upstream.lex — the retro must be able to blame the
# role that CAUSED a failure, not the one that reported it.
#
# The Scribe decides every tightened_spec, and it decides from the trail, which
# reports which NODE failed. A node that fails is often not the node at fault.
#
# Found live (lex-loom#496): a company shipped a working product at iteration 9
# -- POST /f/demo storing to SQLite, 200 on success, 400 naming a missing
# field, verified by curl -- and QA refused it three iterations running,
# because the PRD it was judging against pinned response bodies the goal never
# specified and replaced the goal's SQLite store with an in-memory vector.
# Every retro blamed qa and test_author. The pm was never tightened once in ten
# iterations; it ended holding the highest attestation_count in the company
# while both qa successors sat at -5, one decrement from retirement.
#
# The graph already knows what fed what. These assert the Scribe is handed that
# and told what to do with it.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "../src/digest" as digest

fn expect_contains(hay :: Str, needle :: Str, what :: Str) -> Result[Unit, Str] {
  if str.contains(hay, needle) {
    Ok(())
  } else {
    Err(str.join([what, ": never says '", needle, "'"], ""))
  }
}

fn rule() -> Str {
  digest.attribution_rule()
}

fn test_the_rule_says_the_failing_node_may_not_be_at_fault() -> Result[Unit, Str] {
  expect_contains(rule(), "the node that FAILED is often not the role at fault", "attribution rule")
}

# The exact case that cost three iterations.
fn test_a_qa_refusing_a_correct_product_blames_the_spec() -> Result[Unit, Str] {
  match expect_contains(rule(), "refused a product which does what the GOAL asked", "attribution rule") {
    Err(e) => Err(e),
    Ok(_) => expect_contains(rule(), "not qa", "attribution rule"),
  }
}

fn test_a_build_that_got_its_own_work_wrong_still_blames_build() -> Result[Unit, Str] {
  expect_contains(rule(), "got its own work wrong -> tighten build", "attribution rule")
}

# The consequence, said out loud, because it is the reason the rule exists.
fn test_the_rule_names_the_cost_of_blaming_the_reporter() -> Result[Unit, Str] {
  expect_contains(rule(), "weak gate goes ten iterations without ever being corrected", "attribution rule")
}

# A prompt every company reads must name no company (#483).
fn test_the_rule_names_no_company() -> Result[Unit, Str] {
  let low := str.to_lower(rule())
  if str.contains(low, "formco") {
    Err("the attribution rule names a tenant")
  } else {
    Ok(())
  }
}

# Attribution has to be readable from data, not inferred: the Scribe gets the
# edges, with the role on each end.
fn test_the_prompt_carries_the_edges() -> Result[Unit, Str] {
  let p := digest.scribe_prompt("co/iter-1", "(trail)", "co/iter-2", "\n\nWHAT FED WHAT in this sprint (node <- the node whose artifact it worked from):\n  qa  <-  build   (build fed qa)\n")
  match expect_contains(p, "WHAT FED WHAT", "scribe prompt") {
    Err(e) => Err(e),
    Ok(_) => match expect_contains(p, "build fed qa", "scribe prompt") {
      Err(e) => Err(e),
      Ok(_) => expect_contains(p, "the node that FAILED is often not the role at fault", "scribe prompt"),
    },
  }
}

# A sprint whose graph could not be read still produces a usable prompt.
fn test_no_edges_still_yields_a_prompt() -> Result[Unit, Str] {
  let p := digest.scribe_prompt("co/iter-1", "(trail)", "co/iter-2", "")
  match expect_contains(p, "You are the Scribe", "scribe prompt") {
    Err(e) => Err(e),
    Ok(_) => expect_contains(p, "tightened_specs", "scribe prompt"),
  }
}

fn run_all() -> [io] Int {
  let results := [("the rule says the failing node may not be at fault", test_the_rule_says_the_failing_node_may_not_be_at_fault()), ("a qa refusing a correct product blames the spec", test_a_qa_refusing_a_correct_product_blames_the_spec()), ("a build that got its own work wrong still blames build", test_a_build_that_got_its_own_work_wrong_still_blames_build()), ("the rule names the cost of blaming the reporter", test_the_rule_names_the_cost_of_blaming_the_reporter()), ("the rule names no company", test_the_rule_names_no_company()), ("the prompt carries the edges", test_the_prompt_carries_the_edges()), ("no edges still yields a prompt", test_no_edges_still_yields_a_prompt())]
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

