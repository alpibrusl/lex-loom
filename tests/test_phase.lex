import "std.list" as list

import "std.str" as str

import "std.int" as int

import "../src/phase" as phase

# ── Helpers ───────────────────────────────────────────────────────────────────
fn ok_phase(expected :: phase.Phase, r :: Result[phase.Phase, phase.TransitionError]) -> Result[Unit, Str] {
  match r {
    Err(IllegalMove(msg)) => Err(str.concat("unexpected InvalidTransition: ", msg)),
    Err(WrongEvidence(msg)) => Err(str.concat("unexpected WrongEvidence: ", msg)),
    Ok(p) => if phase.phase_name(p) == phase.phase_name(expected) {
      Ok(())
    } else {
      Err(str.join(["expected ", phase.phase_name(expected), " got ", phase.phase_name(p)], ""))
    },
  }
}

fn expect_wrong_ev(r :: Result[phase.Phase, phase.TransitionError]) -> Result[Unit, Str] {
  match r {
    Err(WrongEvidence(_)) => Ok(()),
    Err(IllegalMove(msg)) => Err(str.concat("expected WrongEvidence, got InvalidTransition: ", msg)),
    Ok(p) => Err(str.concat("expected error, got Ok: ", phase.phase_name(p))),
  }
}

fn expect_invalid(r :: Result[phase.Phase, phase.TransitionError]) -> Result[Unit, Str] {
  match r {
    Err(IllegalMove(_)) => Ok(()),
    Err(WrongEvidence(msg)) => Err(str.concat("expected InvalidTransition, got WrongEvidence: ", msg)),
    Ok(p) => Err(str.concat("expected error, got Ok: ", phase.phase_name(p))),
  }
}

# ── Legal transition tests ────────────────────────────────────────────────────
fn test_intake_to_design() -> Result[Unit, Str] {
  ok_phase(phase.Design, phase.advance(phase.Intake, phase.Design, phase.NoEvidence))
}

fn test_design_to_impl() -> Result[Unit, Str] {
  ok_phase(phase.Implementation, phase.advance(phase.Design, phase.Implementation, phase.GraphValidated))
}

fn test_design_replan() -> Result[Unit, Str] {
  ok_phase(phase.Design, phase.advance(phase.Design, phase.Design, phase.GraphRefined))
}

fn test_impl_to_qa() -> Result[Unit, Str] {
  ok_phase(phase.QA, phase.advance(phase.Implementation, phase.QA, phase.NoEvidence))
}

fn test_qa_fail_bounce() -> Result[Unit, Str] {
  ok_phase(phase.Implementation, phase.advance(phase.QA, phase.Implementation, phase.QaFailed))
}

fn test_qa_to_demo() -> Result[Unit, Str] {
  ok_phase(phase.Demo, phase.advance(phase.QA, phase.Demo, phase.QaAttested))
}

fn test_demo_to_retro() -> Result[Unit, Str] {
  ok_phase(phase.Retro, phase.advance(phase.Demo, phase.Retro, phase.NoEvidence))
}

fn test_retro_to_digest() -> Result[Unit, Str] {
  ok_phase(phase.Digest, phase.advance(phase.Retro, phase.Digest, phase.NoEvidence))
}

fn test_digest_to_intake() -> Result[Unit, Str] {
  ok_phase(phase.Intake, phase.advance(phase.Digest, phase.Intake, phase.DigestComplete))
}

# ── Wrong evidence tests ──────────────────────────────────────────────────────
fn test_design_impl_no_evidence() -> Result[Unit, Str] {
  expect_wrong_ev(phase.advance(phase.Design, phase.Implementation, phase.NoEvidence))
}

fn test_design_replan_no_evidence() -> Result[Unit, Str] {
  expect_wrong_ev(phase.advance(phase.Design, phase.Design, phase.NoEvidence))
}

fn test_qa_demo_no_evidence() -> Result[Unit, Str] {
  expect_wrong_ev(phase.advance(phase.QA, phase.Demo, phase.NoEvidence))
}

fn test_digest_intake_no_evidence() -> Result[Unit, Str] {
  expect_wrong_ev(phase.advance(phase.Digest, phase.Intake, phase.NoEvidence))
}

# ── Illegal transition tests ──────────────────────────────────────────────────
fn test_intake_to_qa_illegal() -> Result[Unit, Str] {
  expect_invalid(phase.advance(phase.Intake, phase.QA, phase.NoEvidence))
}

fn test_demo_to_design_illegal() -> Result[Unit, Str] {
  expect_invalid(phase.advance(phase.Demo, phase.Design, phase.NoEvidence))
}

fn test_impl_to_demo_illegal() -> Result[Unit, Str] {
  expect_invalid(phase.advance(phase.Implementation, phase.Demo, phase.NoEvidence))
}

# ── Predicate tests ───────────────────────────────────────────────────────────
fn test_digest_is_terminal() -> Result[Unit, Str] {
  if phase.is_terminal(phase.Digest) {
    Ok(())
  } else {
    Err("Digest should be terminal")
  }
}

fn test_qa_not_terminal() -> Result[Unit, Str] {
  if phase.is_terminal(phase.QA) {
    Err("QA should not be terminal")
  } else {
    Ok(())
  }
}

fn test_design_requires_graph() -> Result[Unit, Str] {
  if phase.requires_graph(phase.Design) {
    Ok(())
  } else {
    Err("Design should require graph")
  }
}

fn test_retro_no_graph() -> Result[Unit, Str] {
  if phase.requires_graph(phase.Retro) {
    Err("Retro should not require graph")
  } else {
    Ok(())
  }
}

# ── Suite ─────────────────────────────────────────────────────────────────────
fn suite() -> List[Result[Unit, Str]] {
  [test_intake_to_design(), test_design_to_impl(), test_design_replan(), test_impl_to_qa(), test_qa_fail_bounce(), test_qa_to_demo(), test_demo_to_retro(), test_retro_to_digest(), test_digest_to_intake(), test_design_impl_no_evidence(), test_design_replan_no_evidence(), test_qa_demo_no_evidence(), test_digest_intake_no_evidence(), test_intake_to_qa_illegal(), test_demo_to_design_illegal(), test_impl_to_demo_illegal(), test_digest_is_terminal(), test_qa_not_terminal(), test_design_requires_graph(), test_retro_no_graph()]
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

