# test_role_contracts.lex — a role's deliverable is enforced by the ROLE, and
# the mechanism is language-neutral.
#
# The generality guard is the point of this file. Four of the fixes made while
# chasing tzconvert were Python-specific by nature (they patch Python tooling),
# and the repo had already drifted the same way once: Lex and Python each got an
# independent test author and Node/TS never did, so a TS sprint had no way to
# author tests separately from the build at all. Nobody noticed because nothing
# asserted the symmetry.
#
# test_every_language_is_complete fails if a build kind is ever added without a
# contract, or without a matching test author, or with a test author that has no
# contract. Adding Go means adding those rows or turning this red.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.process" as proc

import "../src/role_contracts" as contracts

import "../src/role_kinds" as role_kinds

import "../src/metaspec" as metaspec

import "../src/role_tools" as role_tools

import "../src/agent/runner" as runner

import "lex-llm/src/message" as llm_msg

import "../src/lex_skill" as lexskill

fn seed(dir :: Str, filename :: Str, body :: Str) -> [io, proc] Unit {
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, "; mkdir -p ", dir], "")])
  let __w := io.write(str.join([dir, "/", filename], ""), body)
  ()
}

fn contract_holds(role :: Str, sprint :: Str) -> [io, proc] Bool {
  let seed_dir := runner.tool_work_dir_for_role(role, sprint)
  list.fold(contracts.deliverables_for(role), true, fn (acc :: Bool, d :: contracts.Deliverable) -> [io, proc] Bool {
    if acc {
      match runner.verify_shell_on_output_from(contracts.check_cmd(d), "", str.join(["rc-", role, "-", sprint], ""), seed_dir) {
        Ok(_) => true,
        Err(_) => false,
      }
    } else {
      false
    }
  })
}

# ── the same story in all three languages ────────────────────────────────────
fn test_py_build_needs_a_module() -> [io, proc] Result[Unit, Str] {
  let __s := seed(lexskill.py_work_dir("rc-pyb-bad"), "test_only.py", "def test_x():\n    assert 1\n")
  if contract_holds("py_build", "rc-pyb-bad") {
    Err("a py_build that produced only a test file has not produced a module")
  } else {
    Ok(())
  }
}

fn test_py_build_accepts_a_module() -> [io, proc] Result[Unit, Str] {
  let __s := seed(lexskill.py_work_dir("rc-pyb-good"), "server.py", "def convert(x):\n    return x\n")
  if contract_holds("py_build", "rc-pyb-good") {
    Ok(())
  } else {
    Err("a real module must satisfy the py_build contract")
  }
}

fn test_py_test_author_needs_a_test() -> [io, proc] Result[Unit, Str] {
  let __s := seed(lexskill.py_work_dir("rc-pyt-bad"), "server.py", "def convert(x):\n    return x\n")
  if contract_holds("py_test_author", "rc-pyt-bad") {
    Err("a test author that produced only the implementation has not produced tests")
  } else {
    Ok(())
  }
}

fn test_lex_build_needs_a_source_file() -> [io, proc] Result[Unit, Str] {
  let __s := seed(lexskill.work_dir("rc-lexb-bad"), "app_test.lex", "fn t() -> Int {\n  1\n}\n")
  if contract_holds("build", "rc-lexb-bad") {
    Err("a Lex build that produced only a test file has not produced a source file")
  } else {
    Ok(())
  }
}

fn test_lex_test_author_needs_a_test() -> [io, proc] Result[Unit, Str] {
  let __s := seed(lexskill.work_dir("rc-lext-good"), "app_test.lex", "fn t() -> Int {\n  1\n}\n")
  if contract_holds("test_author", "rc-lext-good") {
    Ok(())
  } else {
    Err("a *_test.lex file must satisfy the Lex test author contract")
  }
}

fn test_ts_build_needs_a_module() -> [io, proc] Result[Unit, Str] {
  let __s := seed(lexskill.ts_work_dir("rc-tsb-bad"), "app.test.ts", "const x: number = 1;\n")
  if contract_holds("ts_build", "rc-tsb-bad") {
    Err("a ts_build that produced only a test file has not produced a module")
  } else {
    Ok(())
  }
}

fn test_ts_test_author_needs_a_test() -> [io, proc] Result[Unit, Str] {
  let __s := seed(lexskill.ts_work_dir("rc-tst-good"), "convert.test.ts", "const x: number = 1;\n")
  if contract_holds("ts_test_author", "rc-tst-good") {
    Ok(())
  } else {
    Err("a *.test.ts file must satisfy the Node test author contract")
  }
}

# A role with no contract must never be blocked by one — most of the roster
# writes prose and owes no file at all.
fn test_prose_roles_owe_nothing() -> Result[Unit, Str] {
  if contracts.has_contract("pm") {
    Err("pm writes prose and must owe no file")
  } else {
    if contracts.has_contract("demo") {
      Err("demo writes prose and must owe no file")
    } else {
      Ok(())
    }
  }
}

# ── the generality guard ─────────────────────────────────────────────────────
fn test_author_kind_for(build_kind :: Str) -> Str {
  if build_kind == "build" {
    "test_author"
  } else {
    str.concat(str.replace(build_kind, "_build", ""), "_test_author")
  }
}

# Every build kind must have a contract, a test author, and that test author
# must have a contract. Adding a language without all three turns this red.
fn test_every_language_is_complete() -> Result[Unit, Str] {
  list.fold(list.filter(role_kinds.known_kinds(), fn (k :: Str) -> Bool {
    runner.is_build_kind(k)
  }), Ok(()), fn (acc :: Result[Unit, Str], k :: Str) -> Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => if not contracts.has_contract(k) {
        Err(str.join(["build kind '", k, "' has no deliverable contract — declare one in role_contracts.lex"], ""))
      } else {
        let ta := test_author_kind_for(k)
        if not list_has(role_kinds.known_kinds(), ta) {
          Err(str.join(["build kind '", k, "' has no matching test author '", ta, "' — a language without one cannot author tests independently of the build"], ""))
        } else {
          if not contracts.has_contract(ta) {
            Err(str.join(["test author '", ta, "' has no deliverable contract"], ""))
          } else {
            Ok(())
          }
        }
      },
    }
  })
}

fn list_has(xs :: List[Str], x :: Str) -> Bool {
  list.fold(xs, false, fn (acc :: Bool, y :: Str) -> Bool {
    if acc {
      true
    } else {
      y == x
    }
  })
}

# A test author must hold its own language's check tool and nothing else: giving
# a Python task the Lex tools makes the agent read Lex docs before writing code.
fn test_each_test_author_holds_only_its_own_tool() -> Result[Unit, Str] {
  if list_has(role_tools.tools_for("ts_test_author"), "ts_check") {
    if list_has(role_tools.tools_for("ts_test_author"), "lex_guidelines") {
      Err("a TS test author must not hold the Lex tools")
    } else {
      Ok(())
    }
  } else {
    Err("a TS test author must hold ts_check")
  }
}

# metaspec routes a graph's test author by build language. It defaulted to the
# Lex author for anything it did not recognise, so a TS graph would have been
# handed lex_guidelines — the exact defect that made a Python agent read Lex
# docs before writing code. The mapping must be TOTAL over build kinds.
fn test_test_author_mapping_is_total() -> Result[Unit, Str] {
  list.fold(list.filter(role_kinds.known_kinds(), fn (k :: Str) -> Bool {
    runner.is_build_kind(k)
  }), Ok(()), fn (acc :: Result[Unit, Str], k :: Str) -> Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => if metaspec.test_author_kind_for_build(k) == test_author_kind_for(k) {
        Ok(())
      } else {
        Err(str.join(["build kind '", k, "' routes to test author '", metaspec.test_author_kind_for_build(k), "', not '", test_author_kind_for(k), "' — an unrecognised language silently gets the Lex author and its tools"], ""))
      },
    }
  })
}

# A bounced test author must be told to RE-DERIVE, never to make its tests
# pass. The critique was gated on the literal kind "test_author", so
# py_test_author -- which does effectively all the work in these runs -- fell
# through to the BUILDER's critique: "fix your code where it is genuinely
# wrong ... repair until ok='true'". Given to a test author that is an
# instruction to edit the oracle until it agrees with the code.
fn bounce_input() -> Str {
  "<<<LOOM_BOUNCE>>>spec text<<<LOOM_SEP>>>prior tests<<<LOOM_SEP>>>QA said FAIL"
}

fn critique_text(kind :: Str) -> Str {
  list.fold(runner.conv_from_msg(kind, bounce_input()), "", fn (acc :: Str, m :: llm_msg.Message) -> Str {
    match m {
      UserMsg(t) => t,
      _ => acc,
    }
  })
}

fn test_every_test_author_kind_gets_the_rederivation_critique() -> Result[Unit, Str] {
  list.fold(["test_author", "py_test_author", "ts_test_author"], Ok(()), fn (acc :: Result[Unit, Str], k :: Str) -> Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => if str.contains(critique_text(k), "Re-derive every expected value") {
        Ok(())
      } else {
        Err(str.join(["a bounced ", k, " is not told to re-derive — it falls through to the builder critique, which tells it to make its tests pass"], ""))
      },
    }
  })
}

# The negative control: a builder must still get the builder's critique.
fn test_a_builder_still_gets_the_builder_critique() -> Result[Unit, Str] {
  if str.contains(critique_text("py_build"), "Re-derive every expected value") {
    Err("a build node must not be told to re-derive expected values — that is the test author's instruction")
  } else {
    Ok(())
  }
}

fn run_all() -> [io, proc] Int {
  let results := [("py_build needs a module", test_py_build_needs_a_module()), ("py_build accepts a module", test_py_build_accepts_a_module()), ("py test author needs a test", test_py_test_author_needs_a_test()), ("lex build needs a source file", test_lex_build_needs_a_source_file()), ("lex test author needs a test", test_lex_test_author_needs_a_test()), ("ts_build needs a module", test_ts_build_needs_a_module()), ("ts test author needs a test", test_ts_test_author_needs_a_test()), ("prose roles owe nothing", test_prose_roles_owe_nothing()), ("every language is complete", test_every_language_is_complete()), ("each test author holds only its own tool", test_each_test_author_holds_only_its_own_tool()), ("test author mapping is total", test_test_author_mapping_is_total()), ("every test author kind gets the re-derivation critique", test_every_test_author_kind_gets_the_rederivation_critique()), ("a builder still gets the builder critique", test_a_builder_still_gets_the_builder_critique())]
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

