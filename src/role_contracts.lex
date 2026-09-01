# role_contracts.lex — what a role OWES, declared by the role itself.
#
# Every node already has a gate, but the Architect chooses it per graph, and the
# Architect is a model. Found live (tzlaunch iter-3): bin/check_imports.py
# exists, works, and catches exactly the defect that sank the run --
# `FastAPIError: Invalid args for response field` on a module that py_compile
# happily accepted -- and the Architect simply did not attach it to that
# py_build node. A check an LLM has to remember to opt into is not a validation,
# it is a suggestion.
#
# So the contract belongs to the ROLE, not to the graph. A py_build owes a
# module; a test author owes a test file. The orchestrator enforces it for every
# node, whatever gate the Architect wrote.
#
# MECHANISM, NOT POLICY. Nothing here knows about Python, timestamps, HTTP or
# tzconvert. A contract is globs over the files a node produced, and the check
# is `ls`. Supporting a new language is a row in deliverables_for plus its work
# dir -- no change to the enforcement path. tests/test_role_contracts.lex fails
# if a language is ever added with a build kind but no contract, or with a build
# kind but no matching test author, which is how Lex and Python ended up with an
# independent test author and Node/TS did not.

import "std.str" as str

import "std.list" as list

# `patterns`: any match satisfies the contract. `exclude`: matches that do not
# count (a build's own test files are not the build's deliverable). `what`: the
# phrase the agent is shown when the deliverable is missing.
type Deliverable = { patterns :: List[Str], exclude :: List[Str], what :: Str }

fn no_contract() -> List[Deliverable] {
  []
}

# Add a language here and in lex_skill's work dirs; the enforcement path below
# does not change.
fn deliverables_for(role :: Str) -> List[Deliverable] {
  if role == "build" {
    [{ patterns: ["*.lex"], exclude: ["*_test.lex"], what: "a Lex source file (not a test)" }]
  } else {
    if role == "test_author" {
      [{ patterns: ["*_test.lex"], exclude: [], what: "a Lex test file (*_test.lex)" }]
    } else {
      if role == "py_build" {
        [{ patterns: ["*.py"], exclude: ["test_*.py", "*_test.py", "conftest.py", "_*.py"], what: "a Python module (not a test, not a scratch _*.py)" }]
      } else {
        if role == "py_test_author" {
          [{ patterns: ["test_*.py", "*_test.py"], exclude: [], what: "a pytest file (test_*.py or *_test.py)" }]
        } else {
          if role == "ts_build" {
            [{ patterns: ["*.ts", "*.mts"], exclude: ["*.test.ts", "*_test.ts"], what: "a TypeScript module (not a test)" }]
          } else {
            if role == "ts_test_author" {
              [{ patterns: ["*.test.ts", "*_test.ts"], exclude: [], what: "a Node test file (*.test.ts or *_test.ts)" }]
            } else {
              no_contract()
            }
          }
        }
      }
    }
  }
}

fn has_contract(role :: Str) -> Bool {
  not list.is_empty(deliverables_for(role))
}

# `ls` over the patterns, minus the exclusions, must find something. Deliberately
# the dullest check that can express the contract: no language runtime, no
# parsing, nothing that can itself fail for an interesting reason.
fn check_cmd(d :: Deliverable) -> Str {
  let pats := str.join(d.patterns, " ")
  let filters := list.fold(d.exclude, "", fn (acc :: Str, e :: Str) -> Str {
    str.join([acc, " | grep -v -e ", shell_glob_to_grep(e)], "")
  })
  str.join(["n=$(ls -1 ", pats, " 2>/dev/null", filters, " | wc -l); [ \"$n\" -gt 0 ]"], "")
}

# `test_*.py` -> `'^test_.*\.py$'`. Only `*` is meaningful in these patterns.
fn shell_glob_to_grep(glob :: Str) -> Str {
  let escaped := str.replace(glob, ".", "\\.")
  let starred := str.replace(escaped, "*", ".*")
  str.join(["'^", starred, "$'"], "")
}

fn missing_message(role :: Str, d :: Deliverable) -> Str {
  str.join(["role contract: a ", role, " node must produce ", d.what, ", and none was found. Write it with your check tool so it lands on disk, and restate it in a fenced block labelled with its filename. Describing the work is not producing it."], "")
}

