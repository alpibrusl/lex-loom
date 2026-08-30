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

import "../src/graph" as graph

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

# Incremental retrigger. The bounce used to re-run the ENTIRE Implementation
# phase every round, which is what made repair unaffordable: measured here,
# three bounces turned a ~10-minute company into 45+, and one all-local
# tzconvert run cost 2.7 hours and 2.6M tokens. Only the node whose artifact QA
# rejected, plus its descendants, can be implicated by that failure.
fn test_affected_subgraph_is_node_plus_descendants() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "a", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "c", role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "b", to: "c", handoff: "schema {}" }] }
  let sub := orch.affected_impl_subgraph(gph, "b")
  if list.len(sub.nodes) == 2 {
    if graph.str_contains(graph.node_ids(sub), "a") {
      Err("node 'a' is upstream of nothing that failed — re-running it is the waste this removes")
    } else {
      Ok(())
    }
  } else {
    Err(str.concat("expected b + its descendant c, got ", int.to_str(list.len(sub.nodes))))
  }
}

# Narrowing on a guess would silently skip work that needed doing, which is a
# worse failure than re-running too much. Unknown producer => full graph.
fn test_unknown_producing_node_reruns_everything() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "a", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }], edges: [] }
  if list.len(orch.affected_impl_subgraph(gph, "").nodes) == 2 {
    Ok(())
  } else {
    Err("with no known producer the bounce must re-run everything, never guess a narrower set")
  }
}

fn test_producing_node_identifies_the_artifact_author() -> Result[Unit, Str] {
  let outs := [{ node_id: "a", attested: true, sealed: true, artifact: "hash-a", reason: "" }, { node_id: "b", attested: true, sealed: true, artifact: "hash-b", reason: "" }]
  if orch.producing_node(outs, "hash-b") == "b" {
    if str.is_empty(orch.producing_node(outs, "hash-missing")) {
      Ok(())
    } else {
      Err("an unknown artifact must yield empty, so callers fall back to the full graph")
    }
  } else {
    Err("must identify the node whose artifact this is")
  }
}

# A node that was never attested did not produce the artifact under test.
fn test_unattested_node_is_not_the_producer() -> Result[Unit, Str] {
  let outs := [{ node_id: "a", attested: false, sealed: false, artifact: "hash-a", reason: "denied" }]
  if str.is_empty(orch.producing_node(outs, "hash-a")) {
    Ok(())
  } else {
    Err("a denied node did not produce the accepted artifact")
  }
}

# Found live (tzk3r1 iter-1, the mixed-model run): py-build-core was denied
# four times with "build does not compile", exhausted its retries and produced
# not one file -- and the sprint still sealed success=true, fully_sealed=true,
# because QA passed. run_qa_with_bounce returned a FABRICATED
# { outcomes: [], success: true } for Implementation, which run_sprint then used
# in place of the real phase result. Any sprint could seal with a completely
# failed build as long as QA passed.
fn test_failed_impl_node_cannot_report_success() -> Result[Unit, Str] {
  let outs := [{ node_id: "b", attested: false, sealed: false, artifact: "", reason: "build does not compile" }, { node_id: "d", attested: true, sealed: true, artifact: "h", reason: "" }]
  if orch.impl_phase_of(outs).success {
    Err("a phase containing an unattested node must not report success — this is how a failed build sealed a green sprint")
  } else {
    Ok(())
  }
}

fn test_all_attested_reports_success() -> Result[Unit, Str] {
  let outs := [{ node_id: "b", attested: true, sealed: true, artifact: "h1", reason: "" }, { node_id: "d", attested: true, sealed: true, artifact: "h2", reason: "" }]
  if orch.impl_phase_of(outs).success {
    Ok(())
  } else {
    Err("every node attested must report success")
  }
}

# The bounce re-runs only the affected subgraph, so its outcome list is partial.
# Merging must take the fresh result for re-run nodes and KEEP the prior one for
# untouched nodes — otherwise a node that failed and was never re-run vanishes.
fn test_merge_keeps_untouched_nodes_and_takes_fresh_ones() -> Result[Unit, Str] {
  let prior := [{ node_id: "a", attested: false, sealed: false, artifact: "", reason: "failed" }, { node_id: "b", attested: false, sealed: false, artifact: "", reason: "failed" }]
  let fresh := [{ node_id: "b", attested: true, sealed: true, artifact: "h", reason: "" }]
  let merged := orch.merge_outcomes(prior, fresh)
  if list.len(merged) == 2 {
    if orch.impl_phase_of(merged).success {
      Err("node 'a' was never re-run and is still failing — the merge must not lose it")
    } else {
      Ok(())
    }
  } else {
    Err(str.concat("merge must keep both nodes, got ", int.to_str(list.len(merged))))
  }
}

# A QA failure implicates the test author as much as the builder — that is the
# point of writing the tests separately. The test author is a SIBLING of the
# build node, not a descendant, so walking descendants alone re-runs only the
# builder and the loop keeps telling one party to fix a disagreement the other
# may have caused.
fn test_bounce_reaches_the_test_author() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "t", role: "test_author", gate: "spec len-gt 50", expand: None, activate_when: "" }, { id: "d", role: "docs", gate: "spec len-gt 50", expand: None, activate_when: "" }], edges: [] }
  let ids := graph.node_ids(orch.affected_impl_subgraph(gph, "b"))
  if graph.str_contains(ids, "t") {
    if graph.str_contains(ids, "d") {
      Err("an unrelated docs node must not be dragged into the re-run — that is the waste incremental retrigger removes")
    } else {
      Ok(())
    }
  } else {
    Err("the test author must be re-run: it may be the party that is wrong")
  }
}

fn test_bounce_still_includes_the_failing_builder() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "t", role: "test_author", gate: "spec len-gt 50", expand: None, activate_when: "" }], edges: [] }
  if graph.str_contains(graph.node_ids(orch.affected_impl_subgraph(gph, "b")), "b") {
    Ok(())
  } else {
    Err("the node whose artifact failed must still be re-run")
  }
}

# A test author receives the GOAL, not the previous step's output. Bisected
# against a live failure -- same agent, same tools, only the input differing:
#
#   sprint goal alone (720 chars)   tool_execs=1  answer 16090 chars  fenced
#   the PM's PRD      (6360 chars)  tool_execs=0  answer   688 chars  no fence
#
# Not length: 8879 characters of filler did not break it. SHAPE. The PRD is a
# formatted document and the model answers in kind -- in the live run, 30418
# characters of markdown with ```json fences and no tool call at all.
fn test_test_author_roles_are_recognised() -> Result[Unit, Str] {
  if orch.is_test_author_role("py_test_author") {
    if orch.is_test_author_role("test_author") {
      Ok(())
    } else {
      Err("the Lex test author must get goal-only input too")
    }
  } else {
    Err("the Python test author must get goal-only input")
  }
}

# Everyone else keeps the previous step's output: a builder needs the design it
# is implementing, and QA needs the artifact it is judging.
fn test_other_roles_are_unaffected() -> Result[Unit, Str] {
  if orch.is_test_author_role("py_build") {
    Err("a builder must still receive the previous step output — it needs the design")
  } else {
    if orch.is_test_author_role("py_qa") {
      Err("QA must still receive the artifact it is judging")
    } else {
      Ok(())
    }
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_first_failure_is_never_stalled(), test_identical_denial_is_stalled(), test_different_denial_and_changed_artifact_is_not_stalled(), test_unchanged_artifact_is_stalled_even_with_different_wording(), test_well_formed_fail_is_final(), test_malformed_verdict_is_retryable(), test_pass_verdict_is_not_final_failure(), test_other_gates_are_unaffected(), test_unexpected_verdict_value_is_retryable(), test_lowercase_fail_is_still_final(), test_affected_subgraph_is_node_plus_descendants(), test_unknown_producing_node_reruns_everything(), test_producing_node_identifies_the_artifact_author(), test_unattested_node_is_not_the_producer(), test_failed_impl_node_cannot_report_success(), test_all_attested_reports_success(), test_merge_keeps_untouched_nodes_and_takes_fresh_ones(), test_bounce_reaches_the_test_author(), test_bounce_still_includes_the_failing_builder(), test_test_author_roles_are_recognised(), test_other_roles_are_unaffected()]
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

