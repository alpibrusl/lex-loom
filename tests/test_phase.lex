import "std.io"  as io
import "std.str" as str

import "../src/phase" as phase

# ── Helpers ───────────────────────────────────────────────────────────────────

fn pass(name :: Str) -> Unit {
  let __p := io.print(str.join(["  PASS  ", name], ""))
  ()
}

fn fail(name :: Str, detail :: Str) -> Unit {
  let __p := io.print(str.join(["  FAIL  ", name, " — ", detail], ""))
  ()
}

fn assert_phase(name :: Str, expected :: phase.Phase, r :: Result[phase.Phase, phase.TransitionError]) -> Unit {
  match r {
    Err(phase.InvalidTransition(msg)) => fail(name, str.join(["InvalidTransition: ", msg], "")),
    Err(phase.WrongEvidence(msg))     => fail(name, str.join(["WrongEvidence: ", msg], "")),
    Ok(p) =>
      if phase.phase_name(p) == phase.phase_name(expected) {
        pass(name)
      } else {
        fail(name, str.join(["expected ", phase.phase_name(expected), " got ", phase.phase_name(p)], ""))
      },
  }
}

fn assert_invalid(name :: Str, r :: Result[phase.Phase, phase.TransitionError]) -> Unit {
  match r {
    Err(_) => pass(name),
    Ok(p)  => fail(name, str.join(["expected error but got Ok(", phase.phase_name(p), ")"], "")),
  }
}

fn assert_wrong_ev(name :: Str, r :: Result[phase.Phase, phase.TransitionError]) -> Unit {
  match r {
    Err(phase.WrongEvidence(_)) => pass(name),
    Err(phase.InvalidTransition(msg)) => fail(name, str.join(["expected WrongEvidence but got InvalidTransition: ", msg], "")),
    Ok(p) => fail(name, str.join(["expected error but got Ok(", phase.phase_name(p), ")"], "")),
  }
}

# ── Legal transition tests ────────────────────────────────────────────────────

fn test_legal_transitions() -> Unit {
  let __1 := assert_phase("Intake → Design",             phase.Design,         phase.advance(phase.Intake,         phase.Design,         phase.NoEvidence))
  let __2 := assert_phase("Design → Implementation",     phase.Implementation, phase.advance(phase.Design,         phase.Implementation, phase.GraphValidated))
  let __3 := assert_phase("Design → Design (re-plan)",   phase.Design,         phase.advance(phase.Design,         phase.Design,         phase.GraphRefined))
  let __4 := assert_phase("Implementation → QA",         phase.QA,             phase.advance(phase.Implementation, phase.QA,             phase.NoEvidence))
  let __5 := assert_phase("QA → Implementation (fail)",  phase.Implementation, phase.advance(phase.QA,             phase.Implementation, phase.QaFailed))
  let __6 := assert_phase("QA → Demo",                   phase.Demo,           phase.advance(phase.QA,             phase.Demo,           phase.QaAttested))
  let __7 := assert_phase("Demo → Retro",                phase.Retro,          phase.advance(phase.Demo,           phase.Retro,          phase.NoEvidence))
  let __8 := assert_phase("Retro → Digest",              phase.Digest,         phase.advance(phase.Retro,          phase.Digest,         phase.NoEvidence))
  let __9 := assert_phase("Digest → Intake",             phase.Intake,         phase.advance(phase.Digest,         phase.Intake,         phase.DigestComplete))
  ()
}

# ── Wrong evidence tests ──────────────────────────────────────────────────────

fn test_wrong_evidence() -> Unit {
  let __1 := assert_wrong_ev("Design → Implementation without GraphValidated", phase.advance(phase.Design,  phase.Implementation, phase.NoEvidence))
  let __2 := assert_wrong_ev("Design → Design without GraphRefined",           phase.advance(phase.Design,  phase.Design,         phase.NoEvidence))
  let __3 := assert_wrong_ev("QA → Demo without QaAttested",                   phase.advance(phase.QA,      phase.Demo,           phase.NoEvidence))
  let __4 := assert_wrong_ev("QA → Implementation without QaFailed",           phase.advance(phase.QA,      phase.Implementation, phase.NoEvidence))
  let __5 := assert_wrong_ev("Digest → Intake without DigestComplete",         phase.advance(phase.Digest,  phase.Intake,         phase.NoEvidence))
  ()
}

# ── Illegal transition tests ──────────────────────────────────────────────────

fn test_illegal_transitions() -> Unit {
  let __1 := assert_invalid("Intake → QA",            phase.advance(phase.Intake,         phase.QA,     phase.NoEvidence))
  let __2 := assert_invalid("Intake → Intake",        phase.advance(phase.Intake,         phase.Intake, phase.NoEvidence))
  let __3 := assert_invalid("Demo → Design",          phase.advance(phase.Demo,           phase.Design, phase.NoEvidence))
  let __4 := assert_invalid("QA → Retro",             phase.advance(phase.QA,             phase.Retro,  phase.NoEvidence))
  let __5 := assert_invalid("Implementation → Demo",  phase.advance(phase.Implementation, phase.Demo,   phase.NoEvidence))
  let __6 := assert_invalid("Digest → Design",        phase.advance(phase.Digest,         phase.Design, phase.NoEvidence))
  ()
}

# ── Predicate tests ───────────────────────────────────────────────────────────

fn test_predicates() -> Unit {
  let __1 := if phase.is_terminal(phase.Digest) { pass("Digest is terminal") } else { fail("Digest is terminal", "returned false") }
  let __2 := if !phase.is_terminal(phase.QA)    { pass("QA is not terminal") } else { fail("QA is not terminal", "returned true") }
  let __3 := if phase.requires_graph(phase.Design)         { pass("Design requires graph") } else { fail("Design requires graph", "returned false") }
  let __4 := if !phase.requires_graph(phase.Retro)         { pass("Retro does not require graph") } else { fail("Retro does not require graph", "returned true") }
  ()
}

fn main() -> [io] Unit {
  let __p := io.print("phase tests")
  let __1 := test_legal_transitions()
  let __2 := test_wrong_evidence()
  let __3 := test_illegal_transitions()
  let __4 := test_predicates()
  ()
}
