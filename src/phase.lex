import "std.str" as str

# ── Types ────────────────────────────────────────────────────────────────────
# Re-exported so callers import only this module.
type Phase = Intake | Design | Implementation | QA | Demo | Retro | Digest

type Evidence = GraphValidated | GraphRefined | QaAttested | QaFailed | DigestComplete | NoEvidence

type TransitionError = IllegalMove(Str) | WrongEvidence(Str)

fn advance(from :: Phase, to :: Phase, ev :: Evidence) -> Result[Phase, TransitionError]
  examples {
    advance(Intake, Design, NoEvidence) => Ok(Design),
    advance(Design, Implementation, GraphValidated) => Ok(Implementation),
    advance(Design, Design, GraphRefined) => Ok(Design),
    advance(Implementation, QA, NoEvidence) => Ok(QA),
    advance(QA, Implementation, QaFailed) => Ok(Implementation),
    advance(QA, Demo, QaAttested) => Ok(Demo),
    advance(Demo, Retro, NoEvidence) => Ok(Retro),
    advance(Retro, Digest, NoEvidence) => Ok(Digest),
    advance(Digest, Intake, DigestComplete) => Ok(Intake),
    advance(Design, Implementation, NoEvidence) => Err(WrongEvidence("Design → Implementation requires GraphValidated")),
    advance(QA, Demo, NoEvidence) => Err(WrongEvidence("QA → Demo requires QaAttested")),
    advance(Digest, Intake, NoEvidence) => Err(WrongEvidence("Digest → Intake requires DigestComplete")),
    advance(Intake, QA, NoEvidence) => Err(IllegalMove("illegal transition: Intake → QA")),
    advance(Demo, Design, NoEvidence) => Err(IllegalMove("illegal transition: Demo → Design")),
    advance(QA, Intake, NoEvidence) => Err(IllegalMove("illegal transition: QA → Intake"))
  }
{
  match from {
    Intake => match to {
      Design => Ok(Design),
      _ => Err(IllegalMove(illegal_msg(from, to))),
    },
    Design => match to {
      Implementation => match ev {
        GraphValidated => Ok(Implementation),
        _ => Err(WrongEvidence("Design → Implementation requires GraphValidated")),
      },
      Design => match ev {
        GraphRefined => Ok(Design),
        _ => Err(WrongEvidence("Design → Design (re-plan) requires GraphRefined")),
      },
      _ => Err(IllegalMove(illegal_msg(from, to))),
    },
    Implementation => match to {
      QA => Ok(QA),
      _ => Err(IllegalMove(illegal_msg(from, to))),
    },
    QA => match to {
      Implementation => match ev {
        QaFailed => Ok(Implementation),
        _ => Err(WrongEvidence("QA → Implementation requires QaFailed")),
      },
      Demo => match ev {
        QaAttested => Ok(Demo),
        _ => Err(WrongEvidence("QA → Demo requires QaAttested")),
      },
      _ => Err(IllegalMove(illegal_msg(from, to))),
    },
    Demo => match to {
      Retro => Ok(Retro),
      _ => Err(IllegalMove(illegal_msg(from, to))),
    },
    Retro => match to {
      Digest => Ok(Digest),
      _ => Err(IllegalMove(illegal_msg(from, to))),
    },
    Digest => match to {
      Intake => match ev {
        DigestComplete => Ok(Intake),
        _ => Err(WrongEvidence("Digest → Intake requires DigestComplete")),
      },
      _ => Err(IllegalMove(illegal_msg(from, to))),
    },
  }
}

fn illegal_msg(from :: Phase, to :: Phase) -> Str {
  str.join(["illegal transition: ", phase_name(from), " → ", phase_name(to)], "")
}

fn phase_name(p :: Phase) -> Str {
  match p {
    Intake => "Intake",
    Design => "Design",
    Implementation => "Implementation",
    QA => "QA",
    Demo => "Demo",
    Retro => "Retro",
    Digest => "Digest",
  }
}

# ── Convenience predicates (pure) ─────────────────────────────────────────────
fn is_terminal(p :: Phase) -> Bool
  examples {
    is_terminal(Digest) => true,
    is_terminal(Intake) => false
  }
{
  match p {
    Digest => true,
    _ => false,
  }
}

fn requires_graph(p :: Phase) -> Bool
  examples {
    requires_graph(Design) => true,
    requires_graph(QA) => false
  }
{
  match p {
    Design => true,
    Implementation => true,
    _ => false,
  }
}

