# company_runner.lex — the auto loop-back runner (#53, #56).
#
# Runs a Company as a *series of iterating looms*: iteration 1 seeds from the
# goal; each subsequent iteration inherits the prior one's tightened specs
# (carried forward) and improved agent pool, and runs the full sprint pipeline.
# The loop continues until the company's `stop_when` condition (C2) holds or
# `max_iterations` is reached — automating what was a manual re-invoke before.

import "std.str" as str

import "std.env" as env

import "./needs" as needs

import "std.int" as int

import "std.io" as io

import "lex-orm/src/connection" as conn

import "lex-trail/src/log" as tlog

import "./orchestrator" as orch

import "./graph" as graph_sprint

import "lex-schema/json_value" as jv

import "std.list" as list

import "./cast" as cast

import "./defaults" as defaults

import "./company" as company

import "./events" as events

import "./roles" as roles

import "./agent/runner" as runner

import "./transport" as tr

import "./delegation" as delegation

import "./manager" as manager

import "./budget" as budget

import "./economy_binding" as eb

import "./org" as org

type CompanyRunResult = { company_id :: Str, iterations :: Int, last_verdict :: Str, stopped_by :: Str }

# Run one iteration, then recurse to the next unless we should stop.
# C8 — the agent-first "board". Ask the strategist to review the finished
# iteration and steer: continue | revise (pivot the goal) | stop. Every decision
# is trail-recorded under the company id so direction changes are auditable.
fn board_notes_section(notes :: List[Str]) -> Str {
  if list.is_empty(notes) {
    "(none)"
  } else {
    str.join(list.map(notes, fn (n :: Str) -> Str {
      str.concat("- ", n)
    }), "\n")
  }
}

# Pure prompt construction, split out from decide_next so it's testable
# without a real LLM call or a live DB (#86).
fn strategist_prompt(mission :: Str, shipped :: Str, notes :: List[Str], operate :: Str, product_signals :: Str, economics :: Str, distribution :: Str, build_status :: Str, mgmt :: Str, current_goal :: Str, ctx :: company.IterCtx) -> Str {
  str.join(["MISSION:\n", mission, "\n\nSHIPPED SO FAR:\n", shipped, "\n\nBOARD NOTES (advisory guidance from the human board member — weigh seriously, but ground your decision in LAST RESULT):\n", board_notes_section(notes), "\n\nOPERATE SIGNALS (real observations from OUTSIDE the build sandbox — e.g. is a launched server actually still responding between iterations. A shipped, QA-passed feature that these signals show isn't actually live is evidence against 'continue', independent of the last QA verdict):\n", operate, "\n\nPRODUCT SIGNALS (self-reported by the product's own /loom/usage endpoint — real usage, not just liveness; weigh as informative context, not verified fact):\n", product_signals, "\n\nREAL ECONOMICS (revenue read from a human-configured, read-only source, compared against estimated LLM spend — loom never touches payments itself):\n", economics, "\n\nDISTRIBUTION (real posts published via the Content Creator's publish_content tool, and real view counts read back from the product itself — not a self-reported claim of having written content, actual reach):\n", distribution, "\n\nLEX BUILD STATUS (ground truth from the sprint graphs actually run, not a self-report — if MISSION describes a Lex server, an x402/payment gate, or any other Lex-side integration, this is the ONLY reliable signal of whether that integration was ever actually attempted, independent of how much Python-side work has shipped):\n", build_status, mgmt, "\n\nNOTE ON GOALS: goals describe WHAT the product does, never HOW it is laid out -- no file paths, directory names, port numbers or commands (the server reads PORT from the environment; tests are collected from the work dir root); and never the pipeline's gates or checkers (derived-values gate, collect-gated, smoke-import gate): the pipeline runs those on its own and QA must not be asked to. Every iteration builds from an EMPTY work dir; nothing from earlier iterations is on disk. A revise goal must describe the complete product to build and verify this iteration, not a change to something that no longer exists.\n\nCURRENT GOAL:\n", current_goal, "\n\nLAST RESULT:\nverdict=", ctx.last_verdict, "\ndigest: ", ctx.digest_summary, "\n\nDecide the company's next move."], "")
}

# Pure, testable: whether pending notes should be marked consumed given the
# decision that was just made (#90 — OP6 item 1).
fn should_consume_notes(notes :: List[Str], decision :: company.StrategistDecision) -> Bool {
  if list.is_empty(notes) {
    false
  } else {
    decision.decision != "continue"
  }
}

# Every other role in this codebase gets a bounded retry on empty/malformed
# output (Architect: max_design_retries; build/qa/etc: max_node_retries) --
# the Strategist alone got zero, so a single transient glitch (found live,
# pdfx2 iter-19) permanently ended the company. This gives it the same
# bounded chance to recover; parse_strategist_decision's "stop" fallback is
# unchanged once retries are exhausted.
fn max_strategist_retries() -> Int {
  2
}

fn strategist_reply_with_retry(db :: conn.ConnDb, agent :: runner.AgentDef, prompt :: Str, cost_owner :: Str, attempt :: Int) -> [env, io, time, crypto, sql, fs_read, fs_write, net, concurrent, llm, proc, random, approval] Str {
  let reply := runner.step(db, agent, prompt, cost_owner, "")
  if company.strategist_reply_is_parseable(reply) {
    reply
  } else {
    if attempt >= max_strategist_retries() {
      reply
    } else {
      let retry_prompt := str.join([prompt, "\n\nYour previous reply was not valid JSON. Output ONLY the JSON object described above — no prose, no markdown fences, nothing else."], "")
      strategist_reply_with_retry(db, agent, retry_prompt, cost_owner, attempt + 1)
    }
  }
}

fn decide_next(db :: conn.ConnDb, ccfg :: company.CompanyCfg, current_goal :: Str, ctx :: company.IterCtx) -> [env, io, time, crypto, sql, fs_read, fs_write, net, concurrent, llm, proc, random, approval] company.StrategistDecision {
  let agent := roles.strategist_agent(ccfg.model)
  let shipped := company.shipped_summary(db, ccfg.id)
  let notes := company.pending_board_notes(db, ccfg.id)
  let operate := company.operate_section(db, ccfg.id)
  let product_signals := company.product_signals_section(db, ccfg.id)
  let economics := company.real_economics_section(db, ccfg.id)
  let distribution := company.distribution_section(db, ccfg.id)
  let build_status := company.build_status_section(db, ccfg.id)
  let mgmt := manager.reports_section(db, ccfg.id)
  let prompt := strategist_prompt(ccfg.goal, shipped, notes, operate, product_signals, economics, distribution, build_status, mgmt, current_goal, ctx)
  let reply := strategist_reply_with_retry(db, agent, prompt, company.strategist_cost_owner(ccfg.id, ctx.idx), 0)
  let __sc := company.record_strategist_cost(db, ccfg.id, ctx.idx)
  let decision := company.parse_strategist_decision(reply)
  let __t := tr.trail(db, ccfg.id, "goal_decision", str.join(["{\"iter\":", int.to_str(ctx.idx), ",\"decision\":\"", decision.decision, "\",\"reason\":\"", company.json_escape(decision.reason), "\"}"], ""))
  let __mc := if should_consume_notes(notes, decision) {
    company.mark_board_notes_consumed(db, ccfg.id)
  } else {
    Ok(())
  }
  decision
}

# #80: pop the next pending backlog item (if any) and mark it active, emitting
# the same trail event either call site would. Shared by the mid-loop "stop"
# branch and the resume-from-Sunset entry point so both grow the feature set
# instead of leaving a queued item orphaned.
fn graduate_backlog(db :: conn.ConnDb, company_id :: Str, at_iter :: Int) -> [sql, fs_write, time, random, crypto, io] Option[company.BacklogItem] {
  match company.next_backlog_item(db, company_id) {
    None => None,
    Some(item) => {
      let __md := match company.active_backlog_item(db, company_id) {
        None => (),
        Some(prev) => {
          let __mp := company.mark_backlog_status(db, company_id, prev.idx, "done")
          ()
        },
      }
      let __mb := company.mark_backlog_status(db, company_id, item.idx, "active")
      let __bt := tr.trail(db, company_id, "backlog_advanced", str.join(["{\"iter\":", int.to_str(at_iter), ",\"goal\":\"", company.json_escape(item.goal), "\"}"], ""))
      let __bp := io.print(str.join(["[company] backlog: graduating to \"", item.goal, "\""], ""))
      Some(item)
    },
  }
}

# ORG2 (lex-loom#217): drain offered assignments before the iteration's main
# sprint. Each becomes an ORDINARY sprint node under this iteration's sprint
# id — cast from the pool (cast.select_roster, so ORG1's node_cast authority
# trail applies), gated, attested, trail-recorded like any other work. The
# artifact lands back on the assignment; a failed one is `returned` and the
# return escalates up the reporting lines.
fn drain_assignments(db :: conn.ConnDb, ccfg :: company.CompanyCfg, sprint_id :: Str, api_max :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let offered := delegation.load_for_drain(db, ccfg.id)
  if list.is_empty(offered) {
    ()
  } else {
    let __p := io.print(str.join(["[company] draining ", int.to_str(list.len(offered)), " delegated assignment(s)"], ""))
    let __each := list.map(offered, fn (a :: delegation.Assignment) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
      let request := delegation.prompt_for_assignment(a)
      let __acc := delegation.set_status(db, a.id, "accepted", "", "")
      let node := delegation.node_for(a)
      let g := { id: sprint_id, phase: Implementation, nodes: [node], edges: [] }
      let roster := cast.select_roster(db, g, request, ccfg.model, sprint_id)
      let worker := list.fold(roster, "", fn (acc :: Str, e :: cast.RosterEntry) -> Str {
        if str.is_empty(acc) and e.node_id == node.id {
          e.pool_agent_id
        } else {
          acc
        }
      })
      let __w := delegation.set_worker(db, a.id, worker)
      let trail_none :: Option[tlog.Log] := None
      let acfg := { id: sprint_id, request: request, model: ccfg.model, db: db, api_calls_max: api_max, roster: roster, trail_log: trail_none, review_transitions: false, depth: 0, iter_ctx: None, exec_mode: "inline", policy_isolation: ccfg.policy_isolation }
      let pr := orch.run_phase(g, Implementation, "", [], acfg)
      let outcome := list.fold(pr.outcomes, None, fn (acc :: Option[orch.NodeOutcome], o :: orch.NodeOutcome) -> Option[orch.NodeOutcome] {
        match acc {
          Some(_) => acc,
          None => if o.node_id == node.id {
            Some(o)
          } else {
            None
          },
        }
      })
      match outcome {
        None => {
          let __r := delegation.set_status(db, a.id, "returned", "", "no outcome recorded")
          ()
        },
        Some(o) => if o.attested {
          let __d := delegation.set_status(db, a.id, "done", o.artifact, "")
          let __t := tr.trail(db, ccfg.id, "assignment_done", str.join(["{\"assignment\":\"", a.id, "\",\"to\":\"", a.to_role, "\",\"artifact\":\"", o.artifact, "\"}"], ""))
          io.print(str.join(["[company] assignment ", delegation.node_id_for(a), " (", a.kind, " -> ", a.to_role, ") done, artifact ", str.slice(o.artifact, 0, 12)], ""))
        } else {
          let chain := org.escalation_chain(org.load_org(db, ccfg.id), a.to_role)
          let chain_str := if list.is_empty(chain) {
            "(flat — no reporting line)"
          } else {
            str.join(chain, " -> ")
          }
          let __r := delegation.set_status(db, a.id, "returned", "", o.reason)
          let __t := tr.trail(db, ccfg.id, "assignment_returned", str.join(["{\"assignment\":\"", a.id, "\",\"to\":\"", a.to_role, "\",\"reason\":\"", company.json_escape(o.reason), "\",\"escalates_to\":\"", company.json_escape(chain_str), "\"}"], ""))
          io.print(str.join(["[company] assignment ", delegation.node_id_for(a), " RETURNED (", str.slice(o.reason, 0, 80), ") — escalation path: ", chain_str], ""))
        },
      }
    })
    ()
  }
}

# Every iteration builds from an EMPTY work dir; nothing sealed earlier is on
# disk (the company workspace holds the bootstrap skeleton, not the product).
# The strategist writes revise goals as if the product carried forward --
# tzc15 iter 3 "store both as static content served by the FastAPI server",
# tzc18 iter 3 "fix the tzconvert test suite so QA passes" -- and the sprint
# then produced only the delta: nothing to launch, QA fail, iteration lost.
# Until artifacts carry forward (#364) the goal states the premise (#365).
fn iteration_goal(goal :: Str, k :: Int, carried :: Str) -> Str {
  if k <= 1 {
    goal
  } else {
    if str.is_empty(str.trim(carried)) {
      str.join([goal, "\n\nNOTE: this iteration starts from an EMPTY work dir. Nothing built or tested in earlier iterations is on disk. Build everything this goal needs to run and be verified -- the server, its tests, its requirements -- not only the change described above."], "")
    } else {
      str.join([goal, "\n\nNOTE: the work dir ALREADY HOLDS the previous iteration's product (it passed its verdict). These files are on disk:\n", carried, "\nModify this product: read files before rewriting them, keep what works, change what the goal asks, keep the tests passing."], "")
    }
  }
}

# ── Founding stage: the plan-approval gate ───────────────────────────────────
# A company whose manifest says [policy] founding = true (env FOUNDING=1)
# builds nothing until the founder has approved a plan. Iteration 1 is a
# fixed one-node sprint (no architect): the `founder` role writes plan.md,
# gated by bin/check_founding_plan.py (sections by name, the budget Total
# recomputed). A passing plan becomes an attention item for the oracle
# `founder` and the company PARKS. The board decides through the one decide
# path (board.decide / attention_resolve_cmd / loom-cloud): approved -> the
# plan's Total (or a `budget_eur=N` override in the reason) becomes the
# company's `total` spend envelope, stage -> Ideation, and the product
# iterations begin; rejected -> Sunset. Nothing here is offered to the
# Architect: the founding graph is drawn by this file, not by a model.
fn founding_enabled() -> [env] Bool {
  match env.get("FOUNDING") {
    None => false,
    Some(v) => {
      let t := str.to_lower(str.trim(v))
      t == "1" or t == "true" or t == "yes"
    },
  }
}

fn founding_sprint_id(company_id :: Str) -> Str {
  str.concat(company_id, "/founding")
}

# Founding applies while the stage says so, or on a fresh company that asked
# for it (no iteration has run yet).
fn in_founding(db :: conn.ConnDb, ccfg :: company.CompanyCfg, k :: Int, prev_ctx :: company.IterCtx) -> [env, sql] Bool {
  match company.load_stage(db, ccfg.id) {
    Founding => true,
    Ideation => founding_enabled() and k == 1 and str.is_empty(prev_ctx.last_verdict),
    _ => false,
  }
}

fn founding_graph(sprint_id :: Str) -> graph_sprint.SprintGraph {
  { id: sprint_id, phase: Implementation, nodes: [{ id: "plan", role: "founder", gate: "spec sh \"python3 $LOOM_ROOT/bin/check_founding_plan.py .\"", expand: None, activate_when: "" }], edges: [] }
}

fn founding_request(ccfg :: company.CompanyCfg) -> Str {
  str.join(["MISSION: ", ccfg.goal, "\n\nWrite the founding plan the founder must approve before any work starts (plan.md: Idea, Budget in EUR per month with a recomputed Total, Resources, Human actions, Success metric, Timeline)."], "")
}

# The plan's monthly Total in cents, from its Budget table; 0 when absent.
fn plan_total_cents(plan :: Str) -> Int {
  list.fold(str.split(plan, "\n"), 0, fn (acc :: Int, line :: Str) -> Int {
    if acc > 0 {
      acc
    } else {
      let t := str.trim(line)
      let rest := match str.strip_prefix(t, "|") {
        None => "",
        Some(r) => str.to_lower(str.trim(r)),
      }
      if str.starts_with(rest, "total") {
        let cells := str.split(t, "|")
        match list.head(list.tail(list.tail(cells))) {
          None => acc,
          Some(c) => euros_to_cents(c),
        }
      } else {
        acc
      }
    }
  })
}

# "1 250", "1,250.50", "€250" -> cents; 0 when no digits.
fn euros_to_cents(cell :: Str) -> Int {
  let digits := str.join(list.filter(list.map(str.split(str.replace(str.replace(str.trim(cell), ",", ""), "€", ""), "."), fn (p :: Str) -> Str {
    str.replace(p, " ", "")
  }), fn (p :: Str) -> Bool {
    not str.is_empty(p)
  }), ".")
  let parts := str.split(digits, ".")
  let whole := match list.head(parts) {
    None => 0,
    Some(w) => match str.to_int(w) {
      Some(v) => v,
      None => 0,
    },
  }
  let frac := match list.head(list.tail(parts)) {
    None => 0,
    Some(f) => match str.to_int(str.slice(str.concat(f, "00"), 0, 2)) {
      Some(v) => v,
      None => 0,
    },
  }
  whole * 100 + frac
}

# `budget_eur=250` anywhere in the board's reason overrides the plan's Total.
fn budget_override_cents(reason :: Str) -> Int {
  list.fold(str.split(reason, " "), 0, fn (acc :: Int, tok :: Str) -> Int {
    if acc > 0 {
      acc
    } else {
      match str.strip_prefix(str.trim(tok), "budget_eur=") {
        None => acc,
        Some(n) => match str.to_int(str.trim(n)) {
          Some(v) => v * 100,
          None => acc,
        },
      }
    }
  })
}

fn run_founding(db :: conn.ConnDb, ccfg :: company.CompanyCfg, k :: Int, api_max :: Int, prev_ctx :: company.IterCtx, evolve :: Bool) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] CompanyRunResult {
  let sid := founding_sprint_id(ccfg.id)
  let __st := if company.load_stage(db, ccfg.id) == Founding {
    ()
  } else {
    let __sv := company.save_stage(db, ccfg.id, Founding)
    let __tr := tr.trail(db, ccfg.id, "stage_transition", str.join(["{\"iter\":", int.to_str(k), ",\"from\":\"ideation\",\"to\":\"founding\"}"], ""))
    ()
  }
  match tr.attention_for_node(db, sid, "plan") {
    Some(item) => if item.verdict == "approved" {
      founding_approved(db, ccfg, k, api_max, prev_ctx, evolve, item)
    } else {
      if item.verdict == "rejected" {
        let __sv := company.save_stage(db, ccfg.id, Sunset)
        let __fi := company.finish_iteration(db, ccfg.id, k, "failed")
        let __t := tr.trail(db, ccfg.id, "founding_rejected", str.join(["{\"attention\":\"", item.id, "\",\"by\":\"", item.resolved_by, "\",\"reason\":", jv.stringify(JStr(item.rejection_reason)), "}"], ""))
        let __p := io.print(str.join(["[company] founding plan REJECTED by ", item.resolved_by, ": ", item.rejection_reason, " -- company sunset"], ""))
        { company_id: ccfg.id, iterations: k, last_verdict: "founding_rejected", stopped_by: "founding_rejected" }
      } else {
        let __p := io.print(str.join(["[company] PARKED: founding plan awaits the board (attention ", item.id, "; approve with VERDICT=approved [REASON='budget_eur=N'], or reject)"], ""))
        { company_id: ccfg.id, iterations: k, last_verdict: prev_ctx.last_verdict, stopped_by: "parked" }
      }
    },
    None => founding_plan_sprint(db, ccfg, k, api_max, prev_ctx, sid),
  }
}

fn founding_plan_sprint(db :: conn.ConnDb, ccfg :: company.CompanyCfg, k :: Int, api_max :: Int, prev_ctx :: company.IterCtx, sid :: Str) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] CompanyRunResult {
  let request := founding_request(ccfg)
  let __rec := company.record_iteration(db, { company_id: ccfg.id, idx: k, sprint_id: sid, parent_sprint_id: "", status: "running", goal: request })
  let __p1 := io.print(str.join(["[company] founding: writing the plan for the founder's approval (sprint ", sid, ")"], ""))
  let g := founding_graph(sid)
  let roster := cast.select_roster(db, g, request, ccfg.model, sid)
  let trail_none :: Option[tlog.Log] := None
  let scfg := { id: sid, request: request, model: ccfg.model, db: db, api_calls_max: api_max, roster: roster, trail_log: trail_none, review_transitions: false, depth: 0, iter_ctx: None, exec_mode: defaults.resolved_exec_mode(), policy_isolation: ccfg.policy_isolation }
  let pr := orch.run_phase(g, Implementation, "", [], scfg)
  let plan := list.fold(pr.outcomes, None, fn (acc :: Option[orch.NodeOutcome], o :: orch.NodeOutcome) -> Option[orch.NodeOutcome] {
    match acc {
      Some(_) => acc,
      None => if o.node_id == "plan" and o.attested {
        Some(o)
      } else {
        None
      },
    }
  })
  match plan {
    None => {
      let __fi := company.finish_iteration(db, ccfg.id, k, "failed")
      let __t := tr.trail(db, ccfg.id, "founding_plan_denied", str.join(["{\"iter\":", int.to_str(k), "}"], ""))
      let __p := io.print("[company] founding: the plan did not pass its checker; nothing to approve -- company stops")
      { company_id: ccfg.id, iterations: k, last_verdict: "founding_failed", stopped_by: "founding_failed" }
    },
    Some(o) => match tr.push_attention(db, sid, "plan", "human founder blocking", "founder", o.artifact) {
      Err(e) => {
        let __fi := company.finish_iteration(db, ccfg.id, k, "failed")
        let __p := io.print(str.concat("[company] founding: could not queue the plan for approval: ", e))
        { company_id: ccfg.id, iterations: k, last_verdict: "founding_failed", stopped_by: "founding_failed" }
      },
      Ok(aid) => {
        let __fi := company.finish_iteration(db, ccfg.id, k, "parked")
        let __t := tr.trail(db, ccfg.id, "founding_plan_ready", str.join(["{\"attention\":\"", aid, "\",\"artifact\":\"", o.artifact, "\"}"], ""))
        let __pt := tr.trail(db, ccfg.id, "company_parked", str.join(["{\"iter\":", int.to_str(k), ",\"sprint\":\"", sid, "\"}"], ""))
        let __p := io.print(str.join(["[company] PARKED: founding plan ready for the board (attention ", aid, ", artifact ", str.slice(o.artifact, 0, 12), "). Approve: ATTENTION_ID=", aid, " VERDICT=approved [REASON='budget_eur=N'] RESOLVER_ID=<you> attention_resolve_cmd"], ""))
        { company_id: ccfg.id, iterations: k, last_verdict: prev_ctx.last_verdict, stopped_by: "parked" }
      },
    },
  }
}

fn founding_approved(db :: conn.ConnDb, ccfg :: company.CompanyCfg, k :: Int, api_max :: Int, prev_ctx :: company.IterCtx, evolve :: Bool, item :: tr.AttentionRow) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] CompanyRunResult {
  let plan := match tr.artifact_get(db, item.artifact_hash) {
    Ok(c) => c,
    Err(_) => "",
  }
  let override := budget_override_cents(item.rejection_reason)
  let cents := if override > 0 {
    override
  } else {
    plan_total_cents(plan)
  }
  let __env := if cents > 0 {
    match budget.set_envelope(db, ccfg.id, "total", cents, item.resolved_by) {
      Ok(_) => io.print(str.join(["[company] founding approved by ", item.resolved_by, ": total envelope set to ", int.to_str(cents), "c", if override > 0 {
        " (board override)"
      } else {
        " (the plan's Total)"
      }], "")),
      Err(m) => io.print(str.concat("[company] founding approved, but the envelope could not be set: ", m)),
    }
  } else {
    io.print(str.join(["[company] founding approved by ", item.resolved_by, " (no budget figure found; envelope unchanged)"], ""))
  }
  let __sv := company.save_stage(db, ccfg.id, Ideation)
  let __st := tr.trail(db, ccfg.id, "stage_transition", str.join(["{\"iter\":", int.to_str(k), ",\"from\":\"founding\",\"to\":\"ideation\"}"], ""))
  let __ta := tr.trail(db, ccfg.id, "founding_approved", str.join(["{\"attention\":\"", item.id, "\",\"by\":\"", item.resolved_by, "\",\"envelope_cents\":", int.to_str(cents), "}"], ""))
  let __fi := company.finish_iteration(db, ccfg.id, k, "success")
  if k >= ccfg.max_iterations {
    { company_id: ccfg.id, iterations: k, last_verdict: "founding_approved", stopped_by: "max_iterations" }
  } else {
    run_iterations(db, ccfg, k + 1, "", api_max, prev_ctx, ccfg.goal, evolve)
  }
}

fn run_iterations(db :: conn.ConnDb, ccfg :: company.CompanyCfg, k :: Int, parent_sprint :: Str, api_max :: Int, prev_ctx :: company.IterCtx, current_goal :: Str, evolve :: Bool) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] CompanyRunResult {
  if in_founding(db, ccfg, k, prev_ctx) {
    run_founding(db, ccfg, k, api_max, prev_ctx, evolve)
  } else {
    let missing := needs.missing_at(needs.parse_needs(needs_spec()), k)
    if list.is_empty(missing) {
      run_iterations_budgeted(db, ccfg, k, parent_sprint, api_max, prev_ctx, current_goal, evolve)
    } else {
      match park_on_need(db, ccfg.id, k, missing) {
        Err(e) => {
          let __p := io.print(str.concat("[company] need: could not park the company: ", e))
          { company_id: ccfg.id, iterations: k - 1, last_verdict: prev_ctx.last_verdict, stopped_by: "need_failed" }
        },
        Ok(_) => { company_id: ccfg.id, iterations: k - 1, last_verdict: prev_ctx.last_verdict, stopped_by: "parked" },
      }
    }
  }
}

# [needs] env from the manifest, flattened by bootstrap-company.sh to NEEDS.
fn needs_spec() -> [env] Str {
  match env.get("NEEDS") {
    Some(v) => v,
    None => "",
  }
}

# A founder-provided need is missing for iteration k: park the company on a
# board decision that names the exact variable, the same way the founding
# plan parks (#451, the smallest slice of docs/needs-ledger.md). No iteration
# is recorded -- nothing ran -- so the resume re-enters at the same k and
# re-checks: a yes without the value parks again, it does not proceed. The
# value never leaves the runner machine; only the name is in the note.
fn park_on_need(db :: conn.ConnDb, company_id :: Str, k :: Int, missing :: List[Str]) -> [env, io, sql, fs_read, fs_write, time, random, crypto, vcs] Result[Str, Str] {
  let name := match list.head(missing) {
    Some(n) => n,
    None => "",
  }
  let sid := company.iteration_sprint_id(company_id, k)
  let text := str.join(["# Need: ", name, "\n\nThe company cannot start iteration ", int.to_str(k), " until `", name, "` is set on the runner machine -- the machine running bin/cloud-company-runner.sh. Set it there, then answer yes; the company re-checks and resumes. A yes without the value parks again. Values never leave that machine; only the name travels here.\n\nMissing at this iteration: ", str.join(missing, ", "), "\n"], "")
  match tr.artifact_put(db, sid, str.concat("need:", name), text) {
    Err(e) => Err(str.concat("could not store the need note: ", e)),
    Ok(hash) => match tr.push_attention(db, sid, str.concat("need:", name), "human founder blocking", "founder", hash) {
      Err(e) => Err(str.concat("could not queue the board decision: ", e)),
      Ok(aid) => {
        let __t := tr.trail(db, company_id, "need_missing", str.join(["{\"need\":\"", name, "\",\"iter\":", int.to_str(k), ",\"attention\":\"", aid, "\"}"], ""))
        let __pt := tr.trail(db, company_id, "company_parked", str.join(["{\"iter\":", int.to_str(k), ",\"sprint\":\"", sid, "\",\"need\":\"", name, "\"}"], ""))
        let __p := io.print(str.join(["[company] PARKED: need ", name, " missing (attention ", aid, "): set ", name, " on the runner machine, then approve. Resume: ATTENTION_ID=", aid, " VERDICT=approved then bin/run-company.sh"], ""))
        Ok(aid)
      },
    },
  }
}

fn run_iterations_budgeted(db :: conn.ConnDb, ccfg :: company.CompanyCfg, k :: Int, parent_sprint :: Str, api_max :: Int, prev_ctx :: company.IterCtx, current_goal :: Str, evolve :: Bool) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] CompanyRunResult {
  match budget.check_scope(db, ccfg.id, "total") {
    Exhausted => {
      let __esc := budget.escalate_exhausted(db, ccfg.id, "total", "pm")
      let __p := io.print(str.join(["[budget] ", ccfg.id, ": total spend envelope EXHAUSTED — refusing to start iteration ", int.to_str(k), " (no overdraft); escalated to the board"], ""))
      { company_id: ccfg.id, iterations: k - 1, last_verdict: prev_ctx.last_verdict, stopped_by: "budget" }
    },
    _ => run_iterations_funded(db, ccfg, k, parent_sprint, api_max, prev_ctx, current_goal, evolve),
  }
}

fn run_iterations_funded(db :: conn.ConnDb, ccfg :: company.CompanyCfg, k :: Int, parent_sprint :: Str, api_max :: Int, prev_ctx :: company.IterCtx, current_goal :: Str, evolve :: Bool) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] CompanyRunResult {
  let sprint_id := company.iteration_sprint_id(ccfg.id, k)
  let carried_files := if k > 1 and prev_ctx.last_verdict == "passed" {
    runner.carry_artifact_forward(parent_sprint, sprint_id)
  } else {
    0
  }
  let carried_listing := if carried_files > 0 {
    orch.launch_file_listing(sprint_id)
  } else {
    ""
  }
  let __pc := if carried_files > 0 {
    let __t := tr.trail(db, sprint_id, "product_carried_forward", str.join(["{\"from\":\"", parent_sprint, "\",\"files\":", int.to_str(carried_files), "}"], ""))
    io.print(str.join(["[company] carried ", int.to_str(carried_files), " product file(s) from ", parent_sprint, " into ", sprint_id], ""))
  } else {
    ()
  }
  let current_goal := iteration_goal(current_goal, k, carried_listing)
  let __carry := if k > 1 {
    let n := company.carry_specs_forward(db, str.concat(parent_sprint, "-next"), sprint_id)
    io.print(str.join(["[company] carried ", int.to_str(n), " tightened spec(s) into ", sprint_id], ""))
  } else {
    ()
  }
  let __rec := company.record_iteration(db, { company_id: ccfg.id, idx: k, sprint_id: sprint_id, parent_sprint_id: parent_sprint, status: "running", goal: current_goal })
  let __assignments := drain_assignments(db, ccfg, sprint_id, api_max)
  let __reviews := manager.review_assignments(db, ccfg, sprint_id, api_max)
  let __reports := manager.record_reports(db, ccfg.id)
  let __p1 := io.print(str.join(["[company] iter ", int.to_str(k), " sprint=", sprint_id, " goal=", current_goal], ""))
  let trail_none :: Option[tlog.Log] := None
  let entry_ctx := { idx: k, last_verdict: prev_ctx.last_verdict, digest_summary: prev_ctx.digest_summary, accepted_count: prev_ctx.accepted_count, bounced_count: prev_ctx.bounced_count, spend_cents: prev_ctx.spend_cents }
  let exec_mode := defaults.resolved_exec_mode()
  let scfg := { id: sprint_id, request: current_goal, model: ccfg.model, db: db, api_calls_max: api_max, roster: cast.empty_roster(), trail_log: trail_none, review_transitions: false, depth: 0, iter_ctx: Some(entry_ctx), exec_mode: exec_mode, policy_isolation: ccfg.policy_isolation }
  let result := orch.run_sprint(scfg)
  let drained := tr.drain_sprint_jobs(db, sprint_id)
  let __pd := if drained > 0 {
    let __t := tr.trail(db, sprint_id, "sprint_drained", str.join(["{\"failed_jobs\":", int.to_str(drained), "}"], ""))
    io.print(str.join(["[company] drained ", int.to_str(drained), " unfinished job(s) left by ", sprint_id], ""))
  } else {
    ()
  }
  let mem_n := company.persist_iteration_memory(db, sprint_id)
  let __pm := if mem_n > 0 {
    io.print(str.join(["[company] persisted lessons to ", int.to_str(mem_n), " agent(s) for next iteration"], ""))
  } else {
    ()
  }
  let __cost := match company.record_iteration_cost(db, ccfg.id, sprint_id) {
    Ok(_) => (),
    Err(m) => io.print(str.join(["[company] cost recording failed: ", m], "")),
  }
  let ctx := company.derive_ctx(db, ccfg.id, sprint_id, k, result.success)
  let __fin := company.finish_iteration(db, ccfg.id, k, if result.parked {
    "parked"
  } else {
    if result.success {
      "success"
    } else {
      "failed"
    }
  })
  let __sync := if result.success {
    match company.find_build_artifact(db, sprint_id) {
      None => io.print(str.join(["[company] WARNING: no build artifact found for ", sprint_id, " -- nothing synced to $LOOM_WORKSPACE/", ccfg.id, "/ despite a passing sprint (found live: this used to fail silently)"], "")),
      Some(content) => match company.sync_project_dir(ccfg.id, sprint_id, content) {
        Ok(_) => io.print(str.join(["[company] synced build output to $LOOM_WORKSPACE/", ccfg.id, "/"], "")),
        Err(m) => io.print(str.join(["[company] project sync failed: ", m], "")),
      },
    }
  } else {
    ()
  }
  let __liveness := if result.success {
    match company.check_and_record_liveness(db, ccfg.id, k, sprint_id) {
      Ok(_) => (),
      Err(m) => io.print(str.join(["[company] liveness check failed: ", m], "")),
    }
  } else {
    ()
  }
  let __revenue := if result.success {
    match company.check_and_record_revenue(db, ccfg.id, k) {
      Ok(_) => (),
      Err(m) => io.print(str.join(["[company] revenue check failed: ", m], "")),
    }
  } else {
    ()
  }
  let brand_n := if result.success {
    company.persist_brand_memory(db, sprint_id)
  } else {
    0
  }
  let __pb := if brand_n > 0 {
    io.print(str.join(["[company] persisted brand identity to ", int.to_str(brand_n), " agent(s) for next iteration"], ""))
  } else {
    ()
  }
  let __p2 := io.print(str.join(["[company] iter ", int.to_str(k), " done verdict=", ctx.last_verdict, " accepted=", int.to_str(ctx.accepted_count), " bounced=", int.to_str(ctx.bounced_count), " est_spend=", company.format_cents(ctx.spend_cents)], ""))
  let decision := if evolve and not result.parked {
    decide_next(db, ccfg, current_goal, ctx)
  } else {
    { decision: "continue", goal: "", reason: "" }
  }
  let __pd := if evolve and not result.parked {
    io.print(str.join(["[company] strategist: ", decision.decision, " — ", decision.reason], ""))
  } else {
    ()
  }
  let __ab := if decision.decision == "add" {
    let __a := company.append_backlog(db, ccfg.id, decision.goal)
    let __bt := tr.trail(db, ccfg.id, "backlog_added", str.join(["{\"iter\":", int.to_str(k), ",\"goal\":\"", company.json_escape(decision.goal), "\"}"], ""))
    io.print(str.join(["[company] backlog: queued \"", decision.goal, "\""], ""))
  } else {
    ()
  }
  let next_goal := if decision.decision == "revise" {
    decision.goal
  } else {
    current_goal
  }
  let stop := if str.is_empty(str.trim(ccfg.stop_when)) {
    false
  } else {
    company.eval_condition(ccfg.stop_when, ctx)
  }
  let cur_stage := company.load_stage(db, ccfg.id)
  let new_stage := if result.parked {
    cur_stage
  } else {
    company.next_stage(cur_stage, ctx, ccfg, decision.decision == "stop")
  }
  let __ss := if new_stage == cur_stage {
    ()
  } else {
    let __sv := company.save_stage(db, ccfg.id, new_stage)
    let __st := tr.trail(db, ccfg.id, "stage_transition", str.join(["{\"iter\":", int.to_str(k), ",\"from\":\"", company.stage_to_str(cur_stage), "\",\"to\":\"", company.stage_to_str(new_stage), "\"}"], ""))
    io.print(str.join(["[company] stage: ", company.stage_to_str(cur_stage), " -> ", company.stage_to_str(new_stage)], ""))
  }
  let dormant := company.is_dormant(new_stage, ccfg.wake_when, ctx)
  if result.parked {
    let __pt := tr.trail(db, ccfg.id, "company_parked", str.join(["{\"iter\":", int.to_str(k), ",\"sprint\":\"", sprint_id, "\"}"], ""))
    let __pp := io.print(str.join(["[company] PARKED at iter ", int.to_str(k), " — a blocking human gate awaits the board (resolve via attention_resolve_cmd or /api/attention; the scheduler resumes it after)"], ""))
    { company_id: ccfg.id, iterations: k, last_verdict: ctx.last_verdict, stopped_by: "parked" }
  } else {
    if decision.decision == "stop" {
      if k >= ccfg.max_iterations {
        { company_id: ccfg.id, iterations: k, last_verdict: ctx.last_verdict, stopped_by: "max_iterations" }
      } else {
        match graduate_backlog(db, ccfg.id, k) {
          None => { company_id: ccfg.id, iterations: k, last_verdict: ctx.last_verdict, stopped_by: "strategist" },
          Some(item) => run_iterations(db, ccfg, k + 1, sprint_id, api_max, ctx, item.goal, evolve),
        }
      }
    } else {
      if stop {
        { company_id: ccfg.id, iterations: k, last_verdict: ctx.last_verdict, stopped_by: "condition" }
      } else {
        if dormant {
          let __dt := tr.trail(db, ccfg.id, "company_dormant", str.join(["{\"iter\":", int.to_str(k), ",\"stage\":\"", company.stage_to_str(new_stage), "\"}"], ""))
          let __dp := io.print(str.join(["[company] dormant (stage=", company.stage_to_str(new_stage), ", wake_when not met)"], ""))
          { company_id: ccfg.id, iterations: k, last_verdict: ctx.last_verdict, stopped_by: "dormant" }
        } else {
          if k >= ccfg.max_iterations {
            { company_id: ccfg.id, iterations: k, last_verdict: ctx.last_verdict, stopped_by: "max_iterations" }
          } else {
            run_iterations(db, ccfg, k + 1, sprint_id, api_max, ctx, next_goal, evolve)
          }
        }
      }
    }
  }
}

# Launch (or refuse to launch) the next iteration given a resume point and the
# goal it should run — shared by the fresh/dormant-woken path and the
# resume-from-Sunset path so both respect max_iterations identically.
fn proceed(db :: conn.ConnDb, ccfg :: company.CompanyCfg, api_max :: Int, evolve :: Bool, resume :: company.ResumePoint, goal :: Str) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] CompanyRunResult {
  if resume.start_idx > ccfg.max_iterations {
    let __mp := io.print("[company] max_iterations already reached — nothing to do")
    { company_id: ccfg.id, iterations: resume.start_idx - 1, last_verdict: resume.prev_ctx.last_verdict, stopped_by: "max_iterations" }
  } else {
    let res := run_iterations(db, ccfg, resume.start_idx, resume.parent_sprint, api_max, resume.prev_ctx, goal, evolve)
    let __pe := io.print(str.join(["[company] done iterations=", int.to_str(res.iterations), " stopped_by=", res.stopped_by, " last_verdict=", res.last_verdict], ""))
    res
  }
}

# Persist the company (an upsert — preserves stage across invocations, C10),
# then resume from wherever the last invocation left off. A dormant company
# (Maintenance, wake_when unmet) is a cheap no-op. A Sunset company is terminal
# UNLESS a backlog item is queued (#80) — the strategist's earlier "stop" meant
# "this goal is done", not "the company is done"; a pending feature reactivates
# it (reverting the stage to Growth, since PMF was already established).
fn run_company(db :: conn.ConnDb, ccfg :: company.CompanyCfg, api_max :: Int, evolve :: Bool) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] CompanyRunResult {
  let result := run_company_loop(db, ccfg, api_max, evolve)
  let reaped := roles.reap_company_servers(ccfg.id)
  let __rp := if reaped > 0 {
    io.print(str.join(["[company] end id=", ccfg.id, " stopped ", int.to_str(reaped), " server(s) this company launched"], ""))
  } else {
    ()
  }
  result
}

# The company loop proper; run_company wraps it so that whatever the exit
# (sunset, dormant, stop_when, max_iterations) the company's launched servers
# are stopped afterwards (#338).
fn run_company_loop(db :: conn.ConnDb, ccfg :: company.CompanyCfg, api_max :: Int, evolve :: Bool) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] CompanyRunResult {
  let __save := company.save_company(db, ccfg)
  let __fund := match eb.fund_from_total_envelope(db, ccfg.id) {
    Err(e) => io.print(str.join(["[company] economy: treasury NOT opened: ", e], "")),
    Ok(None) => io.print("[company] economy: no total budget envelope, no treasury"),
    Ok(Some(t)) => {
      let __t := tr.trail(db, ccfg.id, "treasury_opened", str.join(["{\"company\":\"", ccfg.id, "\",\"balance_cents\":", int.to_str(t.balance_cents), ",\"committed_cents\":", int.to_str(t.committed_cents), "}"], ""))
      io.print(str.join(["[company] economy: treasury ", ccfg.id, " balance=", int.to_str(t.balance_cents), "c committed=", int.to_str(t.committed_cents), "c"], ""))
    },
  }
  let stage0 := company.load_stage(db, ccfg.id)
  let resume := company.resume_point(db, ccfg.id)
  let __p0 := io.print(str.join(["[company] start id=", ccfg.id, " stage=", company.stage_to_str(stage0), " resume_at=iter-", int.to_str(resume.start_idx), " max_iterations=", int.to_str(ccfg.max_iterations), " stop_when='", ccfg.stop_when, "' evolve=", if evolve {
    "on"
  } else {
    "off"
  }], ""))
  let done := resume.start_idx - 1
  if stage0 == Sunset {
    match graduate_backlog(db, ccfg.id, done) {
      None => {
        let __sp := io.print("[company] already sunset — nothing to do")
        { company_id: ccfg.id, iterations: done, last_verdict: resume.prev_ctx.last_verdict, stopped_by: "sunset" }
      },
      Some(item) => {
        let __rs := company.save_stage(db, ccfg.id, Growth)
        let __rt := tr.trail(db, ccfg.id, "stage_transition", str.join(["{\"iter\":", int.to_str(done), ",\"from\":\"sunset\",\"to\":\"growth\"}"], ""))
        let __rp := io.print("[company] reactivating from sunset via queued backlog item")
        proceed(db, ccfg, api_max, evolve, resume, item.goal)
      },
    }
  } else {
    if company.is_dormant(stage0, ccfg.wake_when, resume.prev_ctx) and not events.has_wake_eligible(db, ccfg.id, ccfg.wake_when) {
      let __dt := tr.trail(db, ccfg.id, "company_dormant", str.join(["{\"iter\":", int.to_str(done), ",\"stage\":\"", company.stage_to_str(stage0), "\"}"], ""))
      let __dp := io.print(str.join(["[company] dormant (stage=", company.stage_to_str(stage0), ", wake_when not met)"], ""))
      { company_id: ccfg.id, iterations: done, last_verdict: resume.prev_ctx.last_verdict, stopped_by: "dormant" }
    } else {
      let resume_goal := if str.is_empty(resume.last_goal) {
        ccfg.goal
      } else {
        resume.last_goal
      }
      proceed(db, ccfg, api_max, evolve, resume, resume_goal)
    }
  }
}

# ── C7: portfolio — advance every active track's own company loop ────────────
# A "concurrent" portfolio, in the sense this scope targets: multiple product
# tracks coexist and each advances when the portfolio is invoked, sharing the
# same staff pool/memory. Not true in-process parallelism — each track's own
# company loop is already resumable and dormancy-aware (C10), so running them
# one after another here is enough for a track to make steady, independent
# progress across repeated portfolio invocations (e.g. cron).
type TrackRunResult = { track_id :: Str, result :: CompanyRunResult }

type PortfolioRunResult = { portfolio_id :: Str, tracks :: List[TrackRunResult] }

fn run_one_track(db :: conn.ConnDb, portfolio_id :: Str, model :: Str, api_max :: Int, max_iterations :: Int, evolve :: Bool, t :: company.Track) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] TrackRunResult {
  let cid := company.track_company_id(portfolio_id, t.track_id)
  let ccfg := { id: cid, goal: t.goal, model: model, max_iterations: max_iterations, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
  let __p := io.print(str.join(["[portfolio] track ", t.track_id, " -> ", cid], ""))
  let res := run_company(db, ccfg, api_max, evolve)
  let __done := if company.load_stage(db, cid) == Sunset {
    company.mark_track_status(db, portfolio_id, t.track_id, "done")
  } else {
    Ok(())
  }
  { track_id: t.track_id, result: res }
}

fn run_tracks(db :: conn.ConnDb, portfolio_id :: Str, model :: Str, api_max :: Int, max_iterations :: Int, evolve :: Bool, ts :: List[company.Track]) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] List[TrackRunResult] {
  list.map(ts, fn (t :: company.Track) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] TrackRunResult {
    run_one_track(db, portfolio_id, model, api_max, max_iterations, evolve, t)
  })
}

# Seed any tracks not already present (idempotent — see company.add_track),
# then advance every currently-active track by one company-loop invocation.
fn run_portfolio(db :: conn.ConnDb, portfolio_id :: Str, model :: Str, api_max :: Int, max_iterations :: Int, evolve :: Bool, seed :: List[(Str, Str)]) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] PortfolioRunResult {
  let __seed := list.map(seed, fn (p :: (Str, Str)) -> [sql, fs_write, time] Unit {
    match p {
      (track_id, goal) => {
        let __a := company.add_track(db, portfolio_id, track_id, goal)
        ()
      },
    }
  })
  let ts := company.active_tracks(db, portfolio_id)
  let __p0 := io.print(str.join(["[portfolio] id=", portfolio_id, " active_tracks=", int.to_str(list.len(ts))], ""))
  let results := run_tracks(db, portfolio_id, model, api_max, max_iterations, evolve, ts)
  let __pe := io.print(str.join(["[portfolio] done — ", int.to_str(list.len(results)), " track(s) advanced"], ""))
  { portfolio_id: portfolio_id, tracks: results }
}

