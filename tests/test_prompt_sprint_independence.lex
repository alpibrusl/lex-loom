# test_prompt_sprint_independence.lex -- a system prompt must not depend on the
# sprint it was first rendered for (#312).
#
# The bug this pins: `launch` failed twelve consecutive times in company tzc4
# while calling its tool correctly every time. The tool reported
#
#   bash: line 1: cd: /tmp/loom-py-work-: No such file or directory
#
# -- an empty sprint id interpolated into the path. The prompt was fine when
# first rendered; it was rendered ONCE by the improve loop
# (src/improver.lex, roles.for_role(role, model, "", "")) with an empty
# sprint id, persisted verbatim into agent_pool, and replayed in every later
# sprint. `sprint_id` was threaded correctly everywhere EXCEPT through the
# frozen text, so no amount of correct threading downstream could help.
#
# Any prompt containing a sprint-specific path is wrong the moment it is
# stored, so the invariant is not "render it with the right sprint" but
# "prompts do not vary by sprint at all" -- the tool, which knows its own
# sprint, resolves paths instead. That is exactly what this asserts.

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

import "../src/roles" as roles

import "../src/lex_skill" as lexskill

fn get_str(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# The two prompts that take a sprint id must render identically for different
# sprints. If they don't, whatever differs is precisely what goes stale.
fn test_launch_prompt_does_not_vary_by_sprint() -> Result[Unit, Str] {
  if roles.launch_system_prompt("sprint-alpha") == roles.launch_system_prompt("sprint-beta") {
    Ok(())
  } else {
    Err("launch_system_prompt varies by sprint id, so the text stored in agent_pool goes stale in the next sprint")
  }
}

fn test_deploy_prompt_does_not_vary_by_sprint() -> Result[Unit, Str] {
  if roles.deploy_system_prompt("sprint-alpha") == roles.deploy_system_prompt("sprint-beta") {
    Ok(())
  } else {
    Err("deploy_system_prompt varies by sprint id, so the text stored in agent_pool goes stale in the next sprint")
  }
}

# NEGATIVE CONTROL. The two tests above pass trivially if the comparison is
# broken (both sides identical for the wrong reason), so this reproduces the
# ORIGINAL shape -- a path interpolated into prompt text -- and requires the
# same comparison to REJECT it. Without this, the suite could not tell a fixed
# prompt from a comparison that never fails.
fn stale_shaped_prompt(sprint_id :: Str) -> Str {
  str.join(["run the server with cmd=\"cd ", lexskill.py_work_dir(sprint_id), " && python3 app.py\""], "")
}

fn test_the_check_rejects_an_interpolated_path() -> Result[Unit, Str] {
  if stale_shaped_prompt("sprint-alpha") == stale_shaped_prompt("sprint-beta") {
    Err("the sprint-independence comparison cannot fail: it accepted a prompt with a sprint path interpolated into it")
  } else {
    Ok(())
  }
}

# The launch prompt must not tell the model to cd anywhere: run_server already
# runs the command inside the sprint work dir. A `cd` in the prompt is how the
# broken path reached the shell in the first place.
fn test_launch_prompt_names_no_absolute_path() -> Result[Unit, Str] {
  let p := roles.launch_system_prompt("sprint-alpha")
  if str.contains(p, "/tmp/") {
    Err("the launch prompt names an absolute /tmp path again")
  } else {
    if str.contains(p, "cd ") {
      Err("the launch prompt tells the model to cd; run_server owns the working directory")
    } else {
      Ok(())
    }
  }
}

# The other half of the fix: having taken the path OUT of the prompt, the tool
# must put it back. A language keyword resolves to THIS sprint's real dir.
#
# This asserts on resolve_work_dir directly rather than through the tool. The
# first version of this test went through tool.execute and was vacuous: with
# HETZNER_HOST unset the tool refuses before the directory is ever used, so it
# returned the same refusal whether or not the keyword resolved. Deleting the
# resolution left it green.
fn test_keyword_resolves_to_this_sprints_dir() -> Result[Unit, Str] {
  let got := roles.resolve_work_dir("python", "sprint-alpha")
  if got == lexskill.py_work_dir("sprint-alpha") {
    Ok(())
  } else {
    Err(str.concat("\"python\" did not resolve to this sprint's python work dir, got: ", got))
  }
}

# Resolution must be per-sprint, not merely non-empty: a constant would satisfy
# the test above while reproducing the very staleness this fixes.
fn test_keyword_resolution_differs_between_sprints() -> Result[Unit, Str] {
  if roles.resolve_work_dir("python", "sprint-alpha") == roles.resolve_work_dir("python", "sprint-beta") {
    Err("the same keyword resolved identically for two different sprints, so the resolution ignores the sprint")
  } else {
    Ok(())
  }
}

fn test_every_language_keyword_resolves() -> Result[Unit, Str] {
  let unresolved := list.filter(["lex", "python", "py", "node", "ts", "typescript"], fn (k :: Str) -> Bool {
    roles.resolve_work_dir(k, "sprint-alpha") == k
  })
  if list.is_empty(unresolved) {
    Ok(())
  } else {
    Err(str.concat("these language keywords were passed through as literal paths: ", str.join(unresolved, ", ")))
  }
}

# ...and an agent that names a real directory outright is still obeyed, so the
# keyword support is an addition rather than a replacement.
fn test_an_explicit_path_is_passed_through() -> Result[Unit, Str] {
  if roles.resolve_work_dir("/tmp/some-real-dir", "sprint-alpha") == "/tmp/some-real-dir" {
    Ok(())
  } else {
    Err("an explicit work_dir path was rewritten instead of passed through")
  }
}

fn suite() -> [env, net, io, proc] List[Result[Unit, Str]] {
  [test_launch_prompt_does_not_vary_by_sprint(), test_deploy_prompt_does_not_vary_by_sprint(), test_the_check_rejects_an_interpolated_path(), test_launch_prompt_names_no_absolute_path(), test_keyword_resolves_to_this_sprints_dir(), test_keyword_resolution_differs_between_sprints(), test_every_language_keyword_resolves(), test_an_explicit_path_is_passed_through()]
}

fn run_all() -> [env, net, io, proc] Unit {
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

