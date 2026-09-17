# check_prd.lex — a PRD narrows the goal; it does not rewrite it.
#
# The pm gate is `spec non-empty`, which a PRD can never fail. That one fact
# explains two separate failures: loom's improvement loop never tightened the
# pm in twelve iterations (tightened_specs are keyed by the role whose GATE
# failed), and the eval suite cannot measure it (an accept rate against a gate
# that always passes is 5/5 forever). Meanwhile the pm caused five consecutive
# QA refusals (lex-loom#495, #496).
#
# This is check_research_report's shape -- named sections, per-section
# predicates, and a grounding check against something that actually happened --
# applied to the PRD. There the ledger is the URLs web_search really returned;
# here it is the GOAL the iteration was given.
#
# WHY THIS IS THE FIRST GATE CHECKER IN LEX. The other ten live in bin/*.py,
# 1502 lines of it, and CI strict-checks 189 .lex files and none of them: the
# gate logic was the only part of loom that nothing typechecked. `lex run`
# always exits 0 whatever main returns (lex-lang issue filed), so bin/check-prd.sh
# is a three-line shim that turns the printed verdict into an exit status. The
# logic is here, where `lex check --strict`, `lex test` and `lex fmt` reach it.

import "std.str" as str

import "std.list" as list

import "std.io" as io

# Sections the pm prompt promises. A PRD missing one is not a PRD.
fn required_sections() -> List[Str] {
  ["Goal", "User Stories", "Acceptance Criteria", "Out of Scope"]
}

# Mutually exclusive decisions, grouped. A PRD may narrow scope and may
# paraphrase freely -- "a short success message" is a fine rendering of "a short
# plain-text success message". What it may NOT do is pick a different member of
# a category the goal already decided.
#
# Found live: a goal saying "stores the submission in a local SQLite database
# with a timestamp" became acceptance criteria about "the in-memory vector
# length". The build followed the goal, QA judged against the PRD, and the
# iteration was lost to the gap.
#
# An earlier draft of this checker also required that every decision named in
# the goal be REPEATED in the PRD. It refused a perfectly good PRD for
# paraphrasing, which is the pm's job. Contradiction is checkable; vocabulary
# is not.
fn storage_terms() -> List[Str] {
  ["sqlite", "in-memory", "in memory", "postgres", "redis"]
}

fn section_of(text :: Str, heading :: Str) -> Str {
  let marker := str.join(["## ", heading], "")
  match list.head(list.tail(str.split(text, marker))) {
    None => "",
    Some(rest) => match list.head(str.split(rest, "\n## ")) {
      None => str.trim(rest),
      Some(body) => str.trim(body),
    },
  }
}

fn missing_sections(text :: Str) -> List[Str] {
  list.filter(required_sections(), fn (h :: Str) -> Bool {
    str.is_empty(section_of(text, h))
  })
}

# A criterion QA cannot point at is not a criterion.
fn numbered_criteria(text :: Str) -> Int {
  let body := section_of(text, "Acceptance Criteria")
  list.fold(str.split(body, "\n"), 0, fn (n :: Int, line :: Str) -> Int {
    let t := str.trim(line)
    if starts_with_digit(t) {
      n + 1
    } else {
      n
    }
  })
}

fn starts_with_digit(s :: Str) -> Bool {
  list.fold(["1", "2", "3", "4", "5", "6", "7", "8", "9"], false, fn (acc :: Bool, d :: Str) -> Bool {
    if acc {
      true
    } else {
      str.starts_with(s, d)
    }
  })
}

# A byte-exact plain-text body is not a contract, it is a guess at wording, and
# QA will fail a correct product for choosing different words. Found live: a
# PRD pinned `200 body: "ok"` and `400 body: "missing: email"`; the build
# answered "Form submitted." and "Missing field: email", satisfied the goal
# exactly, and was failed three iterations running.
fn pins_a_prose_body(text :: Str) -> Bool {
  let low := str.to_lower(text)
  if str.contains(low, "body: \"") {
    not str.contains(low, "body: \"{")
  } else {
    false
  }
}

# Sections where a PRD DECIDES. Tech Notes and Out of Scope are where it
# EXCLUDES, and the two readings of the same word are opposite.
#
# Live, on the first measurement of this gate: three consecutive pm attempts
# were refused for writing, in Tech Notes, "a local SQLite database (not an
# in-memory or networked database)" and "do not substitute an in-memory store".
# Every one of them had obeyed the goal exactly, and the last was quoting the
# goal back to warn the build off substituting. The checker was asking whether
# a category term APPEARED; the question is whether the PRD DECIDED it.
# Acceptance Criteria ALONE, because that is the section QA judges against and
# therefore the only place a wrong decision does damage. Goal and User Stories
# are prose the build reads for intent; Tech Notes and Out of Scope are where a
# PRD EXCLUDES things, and the two readings of the same word are opposite.
#
# Widening this to Goal + User Stories looked equally correct against the first
# fixtures and is not: #495's PRD restated SQLite in its Goal and then wrote
# criteria about "the in-memory vector length". Any rule that lets a correct
# Goal excuse wrong criteria misses the bug this check exists for.
fn decision_sections() -> List[Str] {
  ["Acceptance Criteria"]
}

fn decision_text(text :: Str) -> Str {
  str.to_lower(str.join(list.map(decision_sections(), fn (h :: Str) -> Str {
    section_of(text, h)
  }), "\n"))
}

# The grounding check: the goal is the ledger. A decision it made cannot be
# reversed here.
#
# A reversal needs BOTH halves -- the criteria name a different member of the
# category, AND they never name the goal's member. Criteria naming both are
# contrasting ("persisted to SQLite, not held in memory"), which is allowed and
# usually helpful. Both halves are load-bearing and each has its own test:
# without the section scope, an exclusion in Tech Notes reads as a decision;
# without the restates-goal half, an exclusion written INSIDE a criterion does.
fn contradicts_goal(text :: Str, goal :: Str) -> Str {
  let body := decision_text(text)
  let g := str.to_lower(goal)
  let chose_in_goal := list.filter(storage_terms(), fn (t :: Str) -> Bool {
    str.contains(g, t)
  })
  if list.is_empty(chose_in_goal) {
    ""
  } else {
    let restates_goal := list.fold(chose_in_goal, false, fn (acc :: Bool, c :: Str) -> Bool {
      if acc {
        true
      } else {
        str.contains(body, c)
      }
    })
    let conflicting := if restates_goal {
      []
    } else {
      list.filter(storage_terms(), fn (t :: Str) -> Bool {
        if str.contains(body, t) {
          not list.fold(chose_in_goal, false, fn (acc :: Bool, c :: Str) -> Bool {
            if acc {
              true
            } else {
              c == t
            }
          })
        } else {
          false
        }
      })
    }
    match list.head(conflicting) {
      None => "",
      Some(t) => str.join(["the PRD decides storage as `", t, "`; the goal decided `", str.join(chose_in_goal, ", "), "`"], ""),
    }
  }
}

# Ordered most-fundamental first. A PRD that changed WHAT THE THING IS gets told
# that, not told about its punctuation -- prd_bad does both, and the refusal the
# pm has to act on is the storage one.
fn verdict(text :: Str, goal :: Str) -> Str {
  let missing := missing_sections(text)
  if not list.is_empty(missing) {
    str.join(["REFUSE: required sections missing or empty: ", str.join(missing, ", ")], "")
  } else {
    let n := numbered_criteria(text)
    if n < 2 {
      "REFUSE: acceptance criteria are not a numbered list of at least two items. A criterion QA cannot point at is not a criterion."
    } else {
      let clash := contradicts_goal(text, goal)
      if not str.is_empty(clash) {
        str.join(["REFUSE: ", clash, ". Narrowing what is IN SCOPE is the pm's job; changing what the thing IS is not."], "")
      } else {
        if pins_a_prose_body(text) {
          "REFUSE: the PRD pins an exact plain-text response body. Describe what the message must CONVEY, not what it must SAY -- structured data is pinned exactly, prose is not."
        } else {
          str.join(["ACCEPT: ", int_str(list.len(required_sections())), " sections, ", int_str(n), " acceptance criteria"], "")
        }
      }
    }
  }
}

import "std.int" as int

fn int_str(n :: Int) -> Str {
  int.to_str(n)
}

# A PRD path and an optional goal path. With no goal the structural checks
# still run; the contradiction check needs the ledger to compare against.
fn main(prd_path :: Str, goal_path :: Str) -> [fs_read, io] Int {
  let text := match io.read(prd_path) {
    Err(_) => "",
    Ok(t) => t,
  }
  if str.is_empty(text) {
    let __ := io.print(str.join(["REFUSE: no PRD found at ", prd_path], ""))
    1
  } else {
    let goal := if str.is_empty(goal_path) {
      ""
    } else {
      match io.read(goal_path) {
        Err(_) => "",
        Ok(g) => g,
      }
    }
    let v := verdict(text, goal)
    let __ := io.print(v)
    if str.starts_with(v, "ACCEPT") {
      0
    } else {
      1
    }
  }
}

