# test_pm_keeps_the_goal.lex — a PRD narrows the goal; it does not rewrite it,
# and it does not invent a wire contract the goal never asked for.
#
# formcolocal built a working product at iteration 9 -- POST /f/demo stores to
# SQLite and answers 200, a missing field answers 400 naming it, verified by
# curl -- and QA failed it three iterations running. The build was never the
# problem. The PRD was:
#
#   POST /f/demo 200  body: "ok"
#   POST /f/demo 400  body: "missing: email"
#   In-memory store entry shape: { name, email, ts }
#
# The goal said "a short plain-text success message" and "400 naming the
# missing field", and the build answered "Form submitted." and "Missing field:
# email" -- correct by the goal, failing by the PRD. The goal also said
# "stores the submission in a local SQLite database with a timestamp", which
# the PRD replaced with an in-memory vector and then wrote acceptance criteria
# against.
#
# Loom's Response Schema section exists because build and test_author are
# different agents who only agree if the wire shape is pinned. That is true of
# JSON and false of prose: pinning a plain-text body turns a human-readable
# message into an oracle that any reasonable wording fails.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "../src/roles" as roles

fn expect_contains(hay :: Str, needle :: Str, what :: Str) -> Result[Unit, Str] {
  if str.contains(str.to_lower(hay), str.to_lower(needle)) {
    Ok(())
  } else {
    Err(str.join([what, ": the prompt never says ", needle], ""))
  }
}

fn test_the_schema_section_is_for_structured_data_only() -> Result[Unit, Str] {
  expect_contains(roles.pm_system_prompt(), "STRUCTURED DATA ONLY", "response schema")
}

# The distinction that matters: what the message conveys, not what it says.
fn test_plain_text_is_described_not_pinned() -> Result[Unit, Str] {
  let p := roles.pm_system_prompt()
  match expect_contains(p, "PLAIN TEXT", "response schema") {
    Err(e) => Err(e),
    Ok(_) => expect_contains(p, "never what it must SAY", "response schema"),
  }
}

fn test_the_goal_may_not_be_revised() -> Result[Unit, Str] {
  expect_contains(roles.pm_system_prompt(), "THE GOAL IS NOT YOURS TO REVISE", "pm")
}

# Narrowing scope stays the PM's job -- the guard must not forbid the thing the
# role is for.
fn test_narrowing_scope_is_still_allowed() -> Result[Unit, Str] {
  expect_contains(roles.pm_system_prompt(), "Narrowing what is IN SCOPE is your job", "pm")
}

# The PM must still pin JSON, which is why the section exists at all.
fn test_json_is_still_pinned_exactly() -> Result[Unit, Str] {
  expect_contains(roles.pm_system_prompt(), "pin the EXACT wire shape", "response schema")
}

# A prompt is read by every company loom runs, so the lesson may name what
# happened but not who it happened to.
fn test_the_lesson_names_no_company() -> Result[Unit, Str] {
  let p := str.to_lower(roles.pm_system_prompt())
  if str.contains(p, "formcolocal") {
    Err("the PM prompt names a tenant")
  } else {
    if str.contains(p, "formco") {
      Err("the PM prompt names a tenant")
    } else {
      Ok(())
    }
  }
}

fn run_all() -> [io] Int {
  let results := [("the schema section is for structured data only", test_the_schema_section_is_for_structured_data_only()), ("plain text is described, not pinned", test_plain_text_is_described_not_pinned()), ("the goal may not be revised", test_the_goal_may_not_be_revised()), ("narrowing scope is still allowed", test_narrowing_scope_is_still_allowed()), ("json is still pinned exactly", test_json_is_still_pinned_exactly()), ("the lesson names no company", test_the_lesson_names_no_company())]
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

