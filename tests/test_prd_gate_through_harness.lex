# test_prd_gate_through_harness.lex — run the gate the way the ORCHESTRATOR
# runs it, not the way I run it by hand.
#
# The pm scored 0/20 against a gate whose checker accepted 46 of the same 46
# artifacts when called directly. `lex run` takes each argument as JSON, so a
# Str argument arrives quoted; the gate string quoted it too, and
# `""/tmp/goal.txt""` made lex refuse the ARGUMENT. The harness reports that as
# "gate command failed", which is indistinguishable from the role producing bad
# work -- a tooling fault wearing a role's failure as a costume, for the second
# time in two days (the deterministic launch scored 0/20 the same way).
#
# #511 claimed an end-to-end check and it was hand-built: I set LOOM_ROOT, cd'd
# to a work dir and called the shim. That reproduces the SHAPE of the harness
# and not the harness, and every difference between them is exactly where this
# class of bug lives. This test calls verify_shell_on_output_from, which is the
# function the orchestrator calls, with a fenced artifact of the kind the pm
# really emits.

import "std.str" as str

import "std.io" as io

import "std.list" as list

import "../src/agent/runner" as runner

import "../src/gates" as gates

# The declared gate, run through the SAME extraction the orchestrator uses.
#
# My first version of this test retyped the command as a Lex string and passed
# while the real gate was broken. `\"` in Lex source is one quote character, so
# the string became shell-level quoting that expands to a bare value -- whereas
# the declared gate carries a literal backslash-quote, which reaches the
# argument as a quote character and double-wraps it. The test was right about
# the shape and wrong about the bytes, which is the whole bug.
#
# So: write the gate as it is DECLARED (literal backslashes, `\\\"`), and take
# the command out of it with gates.shell_command rather than by hand. A test
# that retypes the answer cannot fail when the answer is wrong.
# The gate reads $LOOM_GOAL_FILE, and the HARNESS sets it from the goal passed
# in -- which is what production does since lex-loom#513.
#
# An earlier version read the variable from the ambient environment, and so
# passed only on a machine where someone had exported it. It passed for me for
# that reason and failed on CI, where it is unset, the contradiction check is
# skipped, and a PRD that swaps SQLite for an in-memory vector sails through. A
# test that depends on ambient state reports the state, not the code.
#
# The fix was briefly to name a file the test wrote. This is better: the test
# hands the harness a goal exactly as the orchestrator does, so the mechanism
# under test is the one that ships.
fn goal() -> Str {
  "Build the smallest form-submission server. It stores the submission in a local SQLite database with a timestamp, returns 200 with a short plain-text success message, and 400 naming the missing field."
}

fn pm_gate() -> Str {
  "spec sh \"bash $LOOM_ROOT/bin/check-prd.sh prd.md \\\"$LOOM_GOAL_FILE\\\"\""
}

fn pm_gate_cmd() -> Str {
  gates.shell_command(pm_gate())
}

fn fenced(body :: Str) -> Str {
  str.join(["Here is the PRD.\n\n```prd.md\n", body, "\n```\n"], "")
}

fn good_body() -> Str {
  str.join(["## Goal\nA minimal form-submission backend.\n\n", "## User Stories\n- As a developer, I want a valid POST stored and acknowledged.\n\n", "## Acceptance Criteria\n1. POST /f/demo with a urlencoded body carrying name and email returns HTTP 200 and a short success message.\n2. POST /f/demo missing email returns HTTP 400 and the message names the missing field.\n3. A valid submission is persisted to the SQLite store with a timestamp.\n\n", "## Out of Scope\nSpam filtering, dashboard, CSV.\n\n", "## Tech Notes\n- Persistence is a local SQLite database (not an in-memory or networked database).\n"], "")
}

fn reversed_body() -> Str {
  str.replace(good_body(), "3. A valid submission is persisted to the SQLite store with a timestamp.", "3. After a 200 response the in-memory vector length increases by exactly one.")
}

fn run_gate(body :: Str, scratch :: Str) -> [io, proc] Result[Unit, Str] {
  runner.verify_shell_on_output_from(pm_gate_cmd(), fenced(body), scratch, "", goal())
}

# The test that was missing. A good PRD must pass THROUGH THE HARNESS, not just
# past the checker.
fn test_a_good_prd_passes_the_gate_through_the_harness() -> [io, proc] Result[Unit, Str] {
  match run_gate(good_body(), "prdgate-good") {
    Ok(_) => Ok(()),
    Err(e) => Err(str.join(["a PRD the checker accepts was DENIED by the harness: ", e, " — the gate string and the wrapper disagree about quoting, and the role gets the blame"], "")),
  }
}

# And the gate must still be able to refuse through the same path, or the fix
# for the above is just "accept everything".
fn test_a_reversed_prd_is_refused_through_the_harness() -> [io, proc] Result[Unit, Str] {
  match run_gate(reversed_body(), "prdgate-bad") {
    Ok(_) => Err("the criteria swapped SQLite for an in-memory vector and the harness passed it"),
    Err(_) => Ok(()),
  }
}

# A gate that reports the same thing for "your work is wrong" and "my tooling
# is broken" costs a full measurement to tell apart. This asserts the argument
# error is GONE rather than merely that the gate passed -- if the wrapper
# regresses, the message says so by name.
fn test_the_gate_does_not_fail_on_its_own_arguments() -> [io, proc] Result[Unit, Str] {
  match run_gate(good_body(), "prdgate-args") {
    Ok(_) => Ok(()),
    Err(e) => if str.contains(e, "must be JSON") {
      Err(str.join(["the gate refused its own argument rather than the PRD: ", e], ""))
    } else {
      Err(str.join(["denied for some other reason: ", e], ""))
    },
  }
}

# THE ONE THAT COST A COMPANY RUN.
#
# formco3's pm emitted three fenced prd.md blocks in one artifact -- 9236,
# 8815 and a third, differing on 81 lines. extract_fenced collapsed them to
# one file, the gate checked that file, and the node was ACCEPTED. build-core
# then received the raw artifact, all three PRDs, and burned three attempts
# without writing a line.
#
# The gate and the build were reading different objects. This asserts they no
# longer disagree about how many specifications exist.
fn test_three_prd_blocks_are_refused_through_the_harness() -> [io, proc] Result[Unit, Str] {
  let three := str.join([fenced(good_body()), "\n", fenced(good_body()), "\n", fenced(good_body())], "")
  match runner.verify_shell_on_output_from(pm_gate_cmd(), three, "prdgate-three", "", goal()) {
    Ok(_) => Err("an artifact carrying three prd.md blocks was accepted; only the last reaches disk and the build is handed all three"),
    Err(e) => if str.contains(e, "fenced prd.md blocks") {
      Ok(())
    } else {
      Err(str.join(["refused, but not for the reason that matters: ", e], ""))
    },
  }
}

fn run_all() -> [io, proc] Int {
  let results := [("a good PRD passes the gate through the harness", test_a_good_prd_passes_the_gate_through_the_harness()), ("a reversed PRD is refused through the harness", test_a_reversed_prd_is_refused_through_the_harness()), ("the gate does not fail on its own arguments", test_the_gate_does_not_fail_on_its_own_arguments()), ("three prd blocks are refused through the harness", test_three_prd_blocks_are_refused_through_the_harness())]
  list.fold(results, 0, fn (fails :: Int, r :: (Str, Result[Unit, Str])) -> [io] Int {
    match r {
      (name, Ok(_)) => {
        let __ := io.print(str.concat("ok   ", name))
        fails
      },
      (name, Err(e)) => {
        let __ := io.print(str.join(["FAIL ", name, ": ", e], ""))
        fails + 1
      },
    }
  })
}

