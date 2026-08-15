# company_runner.lex — the auto loop-back runner (#53, #56).
#
# Runs a Company as a *series of iterating looms*: iteration 1 seeds from the
# goal; each subsequent iteration inherits the prior one's tightened specs
# (carried forward) and improved agent pool, and runs the full sprint pipeline.
# The loop continues until the company's `stop_when` condition (C2) holds or
# `max_iterations` is reached — automating what was a manual re-invoke before.

import "std.str" as str

import "std.env" as env

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
fn strategist_prompt(mission :: Str, shipped :: Str, notes :: List[Str], operate :: Str, product_signals :: Str, economics :: Str, distribution :: Str, build_status :: Str, current_goal :: Str, ctx :: company.IterCtx) -> Str {
  str.join(["MISSION:\n", mission, "\n\nSHIPPED SO FAR:\n", shipped, "\n\nBOARD NOTES (advisory guidance from the human board member — weigh seriously, but ground your decision in LAST RESULT):\n", board_notes_section(notes), "\n\nOPERATE SIGNALS (real observations from OUTSIDE the build sandbox — e.g. is a launched server actually still responding between iterations. A shipped, QA-passed feature that these signals show isn't actually live is evidence against 'continue', independent of the last QA verdict):\n", operate, "\n\nPRODUCT SIGNALS (self-reported by the product's own /loom/usage endpoint — real usage, not just liveness; weigh as informative context, not verified fact):\n", product_signals, "\n\nREAL ECONOMICS (revenue read from a human-configured, read-only source, compared against estimated LLM spend — loom never touches payments itself):\n", economics, "\n\nDISTRIBUTION (real posts published via the Content Creator's publish_content tool, and real view counts read back from the product itself — not a self-reported claim of having written content, actual reach):\n", distribution, "\n\nLEX BUILD STATUS (ground truth from the sprint graphs actually run, not a self-report — if MISSION describes a Lex server, an x402/payment gate, or any other Lex-side integration, this is the ONLY reliable signal of whether that integration was ever actually attempted, independent of how much Python-side work has shipped):\n", build_status, "\n\nCURRENT GOAL:\n", current_goal, "\n\nLAST RESULT:\nverdict=", ctx.last_verdict, "\ndigest: ", ctx.digest_summary, "\n\nDecide the company's next move."], "")
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
  let prompt := strategist_prompt(ccfg.goal, shipped, notes, operate, product_signals, economics, distribution, build_status, current_goal, ctx)
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

fn run_iterations(db :: conn.ConnDb, ccfg :: company.CompanyCfg, k :: Int, parent_sprint :: Str, api_max :: Int, prev_ctx :: company.IterCtx, current_goal :: Str, evolve :: Bool) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] CompanyRunResult {
  let sprint_id := company.iteration_sprint_id(ccfg.id, k)
  let __carry := if k > 1 {
    let n := company.carry_specs_forward(db, str.concat(parent_sprint, "-next"), sprint_id)
    io.print(str.join(["[company] carried ", int.to_str(n), " tightened spec(s) into ", sprint_id], ""))
  } else {
    ()
  }
  let __rec := company.record_iteration(db, { company_id: ccfg.id, idx: k, sprint_id: sprint_id, parent_sprint_id: parent_sprint, status: "running", goal: current_goal })
  let __p1 := io.print(str.join(["[company] iter ", int.to_str(k), " sprint=", sprint_id, " goal=", current_goal], ""))
  let trail_none :: Option[tlog.Log] := None
  let entry_ctx := { idx: k, last_verdict: prev_ctx.last_verdict, digest_summary: prev_ctx.digest_summary, accepted_count: prev_ctx.accepted_count, bounced_count: prev_ctx.bounced_count, spend_cents: prev_ctx.spend_cents }
  let exec_mode := match env.get("EXEC_MODE") {
    Some(m) => if str.is_empty(m) {
      "inline"
    } else {
      m
    },
    None => "inline",
  }
  let scfg := { id: sprint_id, request: current_goal, model: ccfg.model, db: db, api_calls_max: api_max, roster: cast.empty_roster(), trail_log: trail_none, review_transitions: false, depth: 0, iter_ctx: Some(entry_ctx), exec_mode: exec_mode, policy_isolation: ccfg.policy_isolation }
  let result := orch.run_sprint(scfg)
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
  let __save := company.save_company(db, ccfg)
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
    if company.is_dormant(stage0, ccfg.wake_when, resume.prev_ctx) {
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

