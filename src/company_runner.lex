# company_runner.lex — the auto loop-back runner (#53, #56).
#
# Runs a Company as a *series of iterating looms*: iteration 1 seeds from the
# goal; each subsequent iteration inherits the prior one's tightened specs
# (carried forward) and improved agent pool, and runs the full sprint pipeline.
# The loop continues until the company's `stop_when` condition (C2) holds or
# `max_iterations` is reached — automating what was a manual re-invoke before.

import "std.str" as str

import "std.int" as int

import "std.io" as io

import "lex-orm/src/connection" as conn

import "lex-trail/src/log" as tlog

import "./orchestrator" as orch

import "./cast" as cast

import "./company" as company

import "./roles" as roles

import "./agent/runner" as runner

import "./transport" as tr

type CompanyRunResult = { company_id :: Str, iterations :: Int, last_verdict :: Str, stopped_by :: Str }

# Run one iteration, then recurse to the next unless we should stop.
# C8 — the agent-first "board". Ask the strategist to review the finished
# iteration and steer: continue | revise (pivot the goal) | stop. Every decision
# is trail-recorded under the company id so direction changes are auditable.
fn decide_next(db :: conn.ConnDb, ccfg :: company.CompanyCfg, current_goal :: Str, ctx :: company.IterCtx) -> [env, io, time, crypto, sql, fs_read, fs_write, net, concurrent, llm, proc, random] company.StrategistDecision {
  let agent := roles.strategist_agent(ccfg.model)
  let prompt := str.join(["MISSION:\n", ccfg.goal, "\n\nCURRENT GOAL:\n", current_goal, "\n\nLAST RESULT:\nverdict=", ctx.last_verdict, "\ndigest: ", ctx.digest_summary, "\n\nDecide the company's next move."], "")
  let reply := runner.step(db, agent, prompt)
  let decision := company.parse_strategist_decision(reply)
  let __t := tr.trail(db, ccfg.id, "goal_decision", str.join(["{\"iter\":", int.to_str(ctx.idx), ",\"decision\":\"", decision.decision, "\",\"reason\":\"", company.json_escape(decision.reason), "\"}"], ""))
  decision
}

fn run_iterations(db :: conn.ConnDb, ccfg :: company.CompanyCfg, k :: Int, parent_sprint :: Str, api_max :: Int, prev_ctx :: company.IterCtx, current_goal :: Str, evolve :: Bool) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] CompanyRunResult {
  let sprint_id := company.iteration_sprint_id(ccfg.id, k)
  let __carry := if k > 1 {
    let n := company.carry_specs_forward(db, str.concat(parent_sprint, "-next"), sprint_id)
    io.print(str.join(["[company] carried ", int.to_str(n), " tightened spec(s) into ", sprint_id], ""))
  } else {
    ()
  }
  let __rec := company.record_iteration(db, { company_id: ccfg.id, idx: k, sprint_id: sprint_id, parent_sprint_id: parent_sprint, status: "running" })
  let __p1 := io.print(str.join(["[company] iter ", int.to_str(k), " sprint=", sprint_id, " goal=", current_goal], ""))
  let trail_none :: Option[tlog.Log] := None
  let entry_ctx := { idx: k, last_verdict: prev_ctx.last_verdict, digest_summary: prev_ctx.digest_summary, accepted_count: prev_ctx.accepted_count, bounced_count: prev_ctx.bounced_count }
  let scfg := { id: sprint_id, request: current_goal, model: ccfg.model, db: db, api_calls_max: api_max, roster: cast.empty_roster(), trail_log: trail_none, review_transitions: false, depth: 0, iter_ctx: Some(entry_ctx) }
  let result := orch.run_sprint(scfg)
  let mem_n := company.persist_iteration_memory(db, sprint_id)
  let __pm := if mem_n > 0 {
    io.print(str.join(["[company] persisted lessons to ", int.to_str(mem_n), " agent(s) for next iteration"], ""))
  } else {
    ()
  }
  let ctx := company.derive_ctx(db, sprint_id, k, result.success)
  let __fin := company.finish_iteration(db, ccfg.id, k, if result.success {
    "success"
  } else {
    "failed"
  })
  let __p2 := io.print(str.join(["[company] iter ", int.to_str(k), " done verdict=", ctx.last_verdict, " accepted=", int.to_str(ctx.accepted_count), " bounced=", int.to_str(ctx.bounced_count)], ""))
  let decision := if evolve {
    decide_next(db, ccfg, current_goal, ctx)
  } else {
    { decision: "continue", goal: "", reason: "" }
  }
  let __pd := if evolve {
    io.print(str.join(["[company] strategist: ", decision.decision, " — ", decision.reason], ""))
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
  let new_stage := company.next_stage(cur_stage, ctx, ccfg, decision.decision == "stop")
  let __ss := if new_stage == cur_stage {
    ()
  } else {
    let __sv := company.save_stage(db, ccfg.id, new_stage)
    let __st := tr.trail(db, ccfg.id, "stage_transition", str.join(["{\"iter\":", int.to_str(k), ",\"from\":\"", company.stage_to_str(cur_stage), "\",\"to\":\"", company.stage_to_str(new_stage), "\"}"], ""))
    io.print(str.join(["[company] stage: ", company.stage_to_str(cur_stage), " -> ", company.stage_to_str(new_stage)], ""))
  }
  if decision.decision == "stop" {
    { company_id: ccfg.id, iterations: k, last_verdict: ctx.last_verdict, stopped_by: "strategist" }
  } else {
    if stop {
      { company_id: ccfg.id, iterations: k, last_verdict: ctx.last_verdict, stopped_by: "condition" }
    } else {
      if k >= ccfg.max_iterations {
        { company_id: ccfg.id, iterations: k, last_verdict: ctx.last_verdict, stopped_by: "max_iterations" }
      } else {
        run_iterations(db, ccfg, k + 1, sprint_id, api_max, ctx, next_goal, evolve)
      }
    }
  }
}

# Persist the company, then run its iterations from 1.
fn run_company(db :: conn.ConnDb, ccfg :: company.CompanyCfg, api_max :: Int, evolve :: Bool) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] CompanyRunResult {
  let __save := company.save_company(db, ccfg)
  let __p0 := io.print(str.join(["[company] start id=", ccfg.id, " max_iterations=", int.to_str(ccfg.max_iterations), " stop_when='", ccfg.stop_when, "' evolve=", if evolve {
    "on"
  } else {
    "off"
  }], ""))
  let init_ctx := { idx: 1, last_verdict: "", digest_summary: "", accepted_count: 0, bounced_count: 0 }
  let res := run_iterations(db, ccfg, 1, "", api_max, init_ctx, ccfg.goal, evolve)
  let __pe := io.print(str.join(["[company] done iterations=", int.to_str(res.iterations), " stopped_by=", res.stopped_by, " last_verdict=", res.last_verdict], ""))
  res
}

