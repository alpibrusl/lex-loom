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

import "../src/agent/runner" as runner

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

# QA must not be asked to judge a build that never ran. tzshdr1 spent two whole
# iterations on exactly that: py_build was in the graph, never started, and
# py_qa denied "work dir missing" four times per round.
fn impl_graph_with_build() -> graph.SprintGraph {
  { id: "g", phase: graph.Implementation, nodes: [{ id: "py-build", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "pm", role: "pm", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "pm", to: "py-build", handoff: "prd" }] }
}

fn phase_with(outcomes :: List[orch.NodeOutcome]) -> orch.PhaseResult {
  { phase: graph.Implementation, outcomes: outcomes, success: false }
}

fn test_build_that_never_ran_is_named() -> Result[Unit, Str] {
  let res := phase_with([{ node_id: "pm", attested: true, sealed: true, artifact: "h1", reason: "" }])
  let absent := orch.missing_producers(impl_graph_with_build(), res)
  if absent == "py-build" {
    Ok(())
  } else {
    Err(str.concat("a build node that never produced must be named, got: ", absent))
  }
}

fn test_denied_build_still_counts_as_missing() -> Result[Unit, Str] {
  let res := phase_with([{ node_id: "py-build", attested: false, sealed: false, artifact: "", reason: "denied" }])
  if orch.missing_producers(impl_graph_with_build(), res) == "py-build" {
    Ok(())
  } else {
    Err("a build that ran but was denied produced nothing for QA to judge")
  }
}

# The negative controls: a build that DID produce must let QA run, and a graph
# with no build at all (a docs-only sprint) must never be blocked.
fn test_produced_build_lets_qa_run() -> Result[Unit, Str] {
  let res := phase_with([{ node_id: "py-build", attested: true, sealed: true, artifact: "h2", reason: "" }])
  if orch.missing_producers(impl_graph_with_build(), res) == "" {
    Ok(())
  } else {
    Err("a build that produced an artifact must not block QA")
  }
}

fn test_graph_without_a_build_is_not_blocked() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "docs", role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [] }
  if orch.missing_producers(gph, phase_with([])) == "" {
    Ok(())
  } else {
    Err("a sprint with no build node has no producer to wait for")
  }
}

# lex-llm returns a failed call as the answer text "[provider error: ...]".
# Gating that as content produced 12 of tzpin2's 19 denials -- an HTTP 500
# refused for "producing no fenced files to check", blamed on the test author,
# and counted in the failure-mode summary as a pipeline defect.
fn test_provider_error_is_recognised() -> Result[Unit, Str] {
  if orch.is_provider_error("[provider error: HTTP 500]") {
    Ok(())
  } else {
    Err("a failed model call must be recognised as infrastructure, not judged as content")
  }
}

fn test_leading_whitespace_does_not_hide_it() -> Result[Unit, Str] {
  if orch.is_provider_error("\n  [provider error: connection refused]") {
    Ok(())
  } else {
    Err("a provider error preceded by whitespace is still a provider error")
  }
}

# The controls: real work must not be mistaken for an outage, including work
# that merely mentions the phrase.
fn test_real_output_is_not_an_outage() -> Result[Unit, Str] {
  if orch.is_provider_error("```test_convert.py\ndef test_ok():\n    assert 1 == 1\n```") {
    Err("a real answer must never be classified as a provider failure")
  } else {
    Ok(())
  }
}

fn test_prose_mentioning_the_phrase_is_not_an_outage() -> Result[Unit, Str] {
  if orch.is_provider_error("The service returns 502 when the upstream [provider error] path is hit.") {
    Err("a node discussing provider errors is still producing content")
  } else {
    Ok(())
  }
}

# The per-step trail exists so a node can be audited without re-running it.
# Before it, loom kept llm_start as "{}", llm_done as the final answer and
# llm_usage as the SUM over every step -- so "was one call near the context
# limit?" was unanswerable from a finished run, and 563,011 summed prompt tokens
# over 38 steps said nothing about the largest call among them.
fn test_usage_step_keeps_its_own_numbers() -> Result[Unit, Str] {
  let row := runner.step_row_json(3, "usage", ",\"prompt_tokens\":14807,\"completion_tokens\":900,\"total_tokens\":15707")
  if str.contains(row, "14807") and str.contains(row, "\"i\":3") {
    Ok(())
  } else {
    Err(str.concat("a per-call usage row must carry that call's own prompt size and its position: ", row))
  }
}

# A tool row names the tool and the call it belongs to. NOT its arguments:
# lex-llm does not pass those into the step, and the change that added this
# claimed otherwise. The filename a build wrote is still not visible here.
fn test_a_tool_row_names_the_tool_and_its_call() -> Result[Unit, Str] {
  let row := runner.step_row_json(7, "tool_exec", ",\"tool\":\"py_check\",\"call_id\":\"call_42\"")
  if str.contains(row, "py_check") and str.contains(row, "call_42") {
    Ok(())
  } else {
    Err(str.concat("a tool row must name the tool and the call it belongs to: ", row))
  }
}

# The orchestrator compared `v == "PASS"` while the gate compared
# `str.to_upper(str.trim(v))`, so a model answering "pass" was read as claiming
# failure by one and success by the other. tzstep2 hit it as
# `verdict is 'passed', expected 'PASS'`.
fn test_claimed_pass_is_case_insensitive() -> Result[Unit, Str] {
  if orch.claimed_pass_of("{\"verdict\":\"pass\"}") {
    Ok(())
  } else {
    Err("the orchestrator read \"pass\" as NOT a pass while the gate read it as one — they must agree")
  }
}

fn test_claimed_pass_rejects_a_fail() -> Result[Unit, Str] {
  if orch.claimed_pass_of("{\"verdict\":\"FAIL\"}") {
    Err("a FAIL must never be read as a claimed pass")
  } else {
    Ok(())
  }
}

fn test_lowercase_pass_is_read_as_a_pass() -> Result[Unit, Str] {
  if orch.verdict_fail_is_final("spec json-verdict-pass", "{\"verdict\":\"pass\"}") {
    Err("a lowercase pass must not be read as a final failure")
  } else {
    Ok(())
  }
}

fn test_lowercase_fail_is_read_as_a_fail() -> Result[Unit, Str] {
  if orch.verdict_fail_is_final("spec json-verdict-pass", "{\"verdict\":\"fail\"}") {
    Ok(())
  } else {
    Err("a lowercase fail must still be final")
  }
}

# wrap_tool has always seen the arguments and the result and recorded neither.
# So loom could say py_check ran and returned ok, but never WHICH FILE it wrote
# -- and the filename is the fact three separate diagnoses needed. The
# fence-labelling failure was only found by reading a /tmp scratch directory
# that happened not to have been cleaned yet.
fn test_an_op_call_carries_the_filename() -> Result[Unit, Str] {
  let row := runner.op_call_json_full("loom-py-build", "py_check", true, "{\"filename\":\"convert.py\"}", "{\"ok\":\"true\"}")
  if str.contains(row, "convert.py") {
    Ok(())
  } else {
    Err(str.concat("a tool call must record what it was asked to do: ", row))
  }
}

fn test_an_op_call_carries_the_result() -> Result[Unit, Str] {
  let row := runner.op_call_json_full("a", "py_check", false, "{}", "COMPILE_FAIL convert.py")
  if str.contains(row, "COMPILE_FAIL") {
    Ok(())
  } else {
    Err(str.concat("a tool call must record what came back: ", row))
  }
}

# The control: the fields are bounded, so a build's whole source is not stored
# twice in the trail.
fn test_recorded_arguments_are_bounded() -> Result[Unit, Str] {
  let long := str.join(list.map(list.range(0, 200), fn (i :: Int) -> Str {
    "0123456789"
  }), "")
  if str.len(runner.clip(long, 300)) == 300 {
    Ok(())
  } else {
    Err(str.concat("arguments must be clipped, got length ", int.to_str(str.len(runner.clip(long, 300)))))
  }
}

# A test author must see the wire contract, and nothing else from the PRD.
#
# #282 cut test authors down to the sprint goal alone, because a document-shaped
# PRD broke them. That created a gap: the builder specifies from the PRD, the
# test author from the raw goal. tzfixed iter-1 is what that costs -- the
# service returned {"result": "1752235200"}, the correct epoch, and the test
# asserted with a helper accepting only numeric leaves, so correct code failed
# and QA blamed the implementation.
fn prd_with_schema() -> Str {
  str.join(["## Goal\nConvert timestamps.\n\n## Response Schema\n{\"result\": string, \"from_tz\": string}\n\n## Out of Scope\nNo auth.\n"], "")
}

fn test_the_schema_is_extracted() -> Result[Unit, Str] {
  let got := orch.response_schema_of(prd_with_schema())
  if str.contains(got, "\"result\": string") {
    Ok(())
  } else {
    Err(str.concat("the wire contract must reach the test author, got: ", got))
  }
}

# The control that keeps #282's fix intact: only the schema travels, never the
# surrounding document.
fn test_only_the_schema_travels() -> Result[Unit, Str] {
  let got := orch.response_schema_of(prd_with_schema())
  if str.contains(got, "Out of Scope") {
    Err("the rest of the PRD must not ride along — a document-shaped handoff is what broke test authors in the first place")
  } else {
    if str.contains(got, "Convert timestamps") {
      Err("the goal section must not ride along either")
    } else {
      Ok(())
    }
  }
}

fn test_a_prd_without_a_schema_yields_nothing() -> Result[Unit, Str] {
  if str.is_empty(orch.response_schema_of("## Goal\nA CLI tool.\n\n## Out of Scope\nNothing.\n")) {
    Ok(())
  } else {
    Err("a product with no structured response must not manufacture a contract")
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_first_failure_is_never_stalled(), test_identical_denial_is_stalled(), test_different_denial_and_changed_artifact_is_not_stalled(), test_unchanged_artifact_is_stalled_even_with_different_wording(), test_well_formed_fail_is_final(), test_malformed_verdict_is_retryable(), test_pass_verdict_is_not_final_failure(), test_other_gates_are_unaffected(), test_unexpected_verdict_value_is_retryable(), test_lowercase_fail_is_still_final(), test_affected_subgraph_is_node_plus_descendants(), test_unknown_producing_node_reruns_everything(), test_producing_node_identifies_the_artifact_author(), test_unattested_node_is_not_the_producer(), test_failed_impl_node_cannot_report_success(), test_all_attested_reports_success(), test_merge_keeps_untouched_nodes_and_takes_fresh_ones(), test_bounce_reaches_the_test_author(), test_bounce_still_includes_the_failing_builder(), test_test_author_roles_are_recognised(), test_other_roles_are_unaffected(), test_build_that_never_ran_is_named(), test_denied_build_still_counts_as_missing(), test_produced_build_lets_qa_run(), test_graph_without_a_build_is_not_blocked(), test_provider_error_is_recognised(), test_leading_whitespace_does_not_hide_it(), test_real_output_is_not_an_outage(), test_prose_mentioning_the_phrase_is_not_an_outage(), test_usage_step_keeps_its_own_numbers(), test_a_tool_row_names_the_tool_and_its_call(), test_lowercase_pass_is_read_as_a_pass(), test_lowercase_fail_is_read_as_a_fail(), test_claimed_pass_is_case_insensitive(), test_claimed_pass_rejects_a_fail(), test_an_op_call_carries_the_filename(), test_an_op_call_carries_the_result(), test_recorded_arguments_are_bounded(), test_the_schema_is_extracted(), test_only_the_schema_travels(), test_a_prd_without_a_schema_yields_nothing()]
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

