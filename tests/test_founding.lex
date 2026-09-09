# test_founding.lex -- the founding-plan gate's pure parts: stage codec and
# transition, the plan's Total in cents, the board's budget override.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "../src/company" as company

import "../src/company_runner" as cr

fn test_founding_stage_roundtrips_and_leads_to_ideation() -> Result[Unit, Str] {
  let ctx := { idx: 1, last_verdict: "passed", digest_summary: "", accepted_count: 1, bounced_count: 0, spend_cents: 0 }
  let cfg := { id: "c", goal: "g", model: "m", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
  if company.stage_from_str("founding") == company.Founding and company.stage_to_str(company.Founding) == "founding" and company.next_stage(company.Founding, ctx, cfg, false) == company.Ideation and company.next_stage(company.Founding, ctx, cfg, true) == company.Sunset {
    Ok(())
  } else {
    Err("Founding must round-trip through its string and step to Ideation (or Sunset when told to stop)")
  }
}

fn plan() -> Str {
  "# Founding plan: X\n\n## Idea\nA thing.\n\n## Budget\n| Item | EUR / month | Notes |\n|---|---|---|\n| Model inference | 120 | LiteLLM |\n| Hosting | 25.50 | one VM |\n| Marketing | 100 | ads |\n| Total | 245.50 | |\n\n## Resources\n- a VM\n"
}

fn test_plan_total_is_read_from_the_budget_table() -> Result[Unit, Str] {
  let c := cr.plan_total_cents(plan())
  if c == 24550 {
    Ok(())
  } else {
    Err(str.concat("expected 24550 cents from the Total row, got ", int.to_str(c)))
  }
}

fn test_plan_without_a_total_yields_zero() -> Result[Unit, Str] {
  if cr.plan_total_cents("## Budget\n| Item | EUR |\n|---|---|\n| Hosting | 25 |\n") == 0 and cr.euros_to_cents("€1,250") == 125000 and cr.euros_to_cents("abc") == 0 {
    Ok(())
  } else {
    Err("no Total row must yield 0; euros_to_cents must strip currency and thousands separators")
  }
}

fn test_board_reason_can_override_the_budget() -> Result[Unit, Str] {
  if cr.budget_override_cents("approved, but budget_eur=80 for the first month") == 8000 and cr.budget_override_cents("fine as it is") == 0 and cr.budget_override_cents("budget_eur=abc") == 0 {
    Ok(())
  } else {
    Err("budget_eur=N in the reason must override in cents; anything else must not")
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_founding_stage_roundtrips_and_leads_to_ideation(), test_plan_total_is_read_from_the_budget_table(), test_plan_without_a_total_yields_zero(), test_board_reason_can_override_the_budget()]
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

