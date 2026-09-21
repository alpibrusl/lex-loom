# test_seeded_work_dir.lex — a build starts from the skeleton loom already
# ships, not from nothing.
#
# bootstrap lays paths/<path>/ into the company WORKSPACE; the build agent
# works in /tmp/loom-*-work-<sprint>, which begins empty. Every iteration has
# therefore re-derived files loom already wrote, and formcolocal/iter-8 shows
# the bill: 293 build steps, a dozen guesses at the name of a package manifest
# (_lextoml.lex, lex.toml.lex, manifest.toml.lex, tmp_lex.toml.lex), and a
# server.lex that passed `lex check --strict` with NO `fn main` in it. The
# launch node booted it and got "runtime panic: no function `main`" -- after
# four nodes had already been attested. paths/lex-web-api/main.lex declares
# that entry point on line 114, and the agent never saw the file.
#
# deploy_scaffold.lex already states the rule this applies: deterministic
# infrastructure is code, not agent output.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.process" as proc

import "../src/agent/runner" as runner

import "../src/company_runner" as company_runner

import "../src/role_kinds" as role_kinds

fn sh(cmd :: Str) -> [proc] Str {
  match proc.run("bash", ["-c", cmd]) {
    Err(_) => "",
    Ok(r) => str.trim(r.stdout),
  }
}

fn root() -> Str {
  "/tmp/loom-seed-test-root"
}

fn make_fake_path() -> [proc] Unit {
  let __ := sh(str.join(["rm -rf '", root(), "'; mkdir -p '", root(), "/paths/lex-demo-api/tests'; ", "printf 'fn main() -> Unit { () }\\n' > '", root(), "/paths/lex-demo-api/main.lex'; ", "printf '[package]\\nname = \"demo\"\\n' > '", root(), "/paths/lex-demo-api/lex.toml'; ", "printf 'fn run_all() -> Int { 0 }\\n' > '", root(), "/paths/lex-demo-api/tests/test_app.lex'"], ""))
  ()
}

fn work_dir(sprint :: Str) -> Str {
  str.join(["/tmp/loom-lex-work-", str.replace(sprint, "/", "_")], "")
}

fn clear(sprint :: Str) -> [proc] Unit {
  let __ := sh(str.join(["rm -rf '", work_dir(sprint), "'"], ""))
  ()
}

# An empty work dir gets the skeleton -- including the entry point whose
# absence killed iteration 8.
fn test_an_empty_work_dir_gets_the_skeleton() -> [proc] Result[Unit, Str] {
  let sprint := "seedco/iter-1"
  let __m := make_fake_path()
  let __c := clear(sprint)
  let n := runner.seed_work_dir_from_path(sprint, "lex-demo-api", root(), "build")
  let has_main := sh(str.join(["grep -l '^fn main' '", work_dir(sprint), "'/main.lex 2>/dev/null | wc -l"], ""))
  let has_toml := sh(str.join(["test -f '", work_dir(sprint), "/lex.toml' && echo 1 || echo 0"], ""))
  let has_tests := sh(str.join(["test -f '", work_dir(sprint), "/tests/test_app.lex' && echo 1 || echo 0"], ""))
  let __c2 := clear(sprint)
  if n == 3 {
    if has_main == "1" {
      if has_toml == "1" {
        if has_tests == "1" {
          Ok(())
        } else {
          Err("the skeleton's tests directory did not come across")
        }
      } else {
        Err("no lex.toml was seeded -- the agent will invent one again")
      }
    } else {
      Err("no `fn main` was seeded -- this is exactly what iteration 8 died of")
    }
  } else {
    Err(str.concat("expected 3 skeleton files, seeded ", int_str(n)))
  }
}

import "std.int" as int

fn int_str(n :: Int) -> Str {
  int.to_str(n)
}

# A dir a build has already written to is never touched: seeding must not
# clobber work in progress, nor a product carried forward from a passing
# iteration.
fn test_a_non_empty_work_dir_is_left_alone() -> [proc] Result[Unit, Str] {
  let sprint := "seedco/iter-2"
  let __m := make_fake_path()
  let __c := clear(sprint)
  let __w := sh(str.join(["mkdir -p '", work_dir(sprint), "'; printf 'the real product\\n' > '", work_dir(sprint), "/server.lex'"], ""))
  let n := runner.seed_work_dir_from_path(sprint, "lex-demo-api", root(), "build")
  let body := sh(str.join(["cat '", work_dir(sprint), "/server.lex'"], ""))
  let toml := sh(str.join(["test -f '", work_dir(sprint), "/lex.toml' && echo 1 || echo 0"], ""))
  let __c2 := clear(sprint)
  if n == 0 {
    if body == "the real product" {
      if toml == "0" {
        Ok(())
      } else {
        Err("seeding wrote into a work dir that already had files")
      }
    } else {
      Err("seeding overwrote work in progress")
    }
  } else {
    Err(str.concat("a non-empty work dir reported files seeded: ", int_str(n)))
  }
}

# An unknown path has no skeleton to seed, and that is not an error.
fn test_an_unknown_path_seeds_nothing() -> [proc] Result[Unit, Str] {
  let sprint := "seedco/iter-3"
  let __m := make_fake_path()
  let __c := clear(sprint)
  let n := runner.seed_work_dir_from_path(sprint, "no-such-path", root(), "build")
  let __c2 := clear(sprint)
  if n == 0 {
    Ok(())
  } else {
    Err(str.concat("a path with no skeleton seeded files: ", int_str(n)))
  }
}

fn test_the_skeleton_goes_to_its_languages_work_dir() -> Result[Unit, Str] {
  if runner.build_role_for_language(role_kinds.language_of_path("lex-web-api")) == "build" {
    if runner.build_role_for_language(role_kinds.language_of_path("python-flask")) == "py_build" {
      if runner.build_role_for_language(role_kinds.language_of_path("research-report")) == "" {
        Ok(())
      } else {
        Err("a document path claimed a build work dir")
      }
    } else {
      Err("a python path does not seed the python work dir")
    }
  } else {
    Err("a lex path does not seed the lex work dir")
  }
}

# The agent has to be TOLD the files are there, or it writes its own anyway.
fn test_the_goal_says_the_skeleton_is_on_disk() -> Result[Unit, Str] {
  let g := company_runner.iteration_goal("Build the thing", 1, "", false, "main.lex\nlex.toml")
  if str.contains(g, "ALREADY HOLDS the vetted skeleton") {
    if str.contains(g, "do not invent your own") {
      Ok(())
    } else {
      Err("the goal does not tell the agent to leave the entry point alone")
    }
  } else {
    Err("a seeded iteration is not told its work dir has files")
  }
}

# A carried product still wins: it is the later, verdict-passed truth.
fn test_a_carried_product_outranks_the_skeleton() -> Result[Unit, Str] {
  let g := company_runner.iteration_goal("Add a field", 3, "server.lex", true, "main.lex")
  if str.contains(g, "previous iteration's product") {
    Ok(())
  } else {
    Err("a carried product was described as a skeleton")
  }
}

# The decision itself, named so a regression has to delete a rule with a test
# on it rather than quietly drop a call. (The wiring inside
# run_iterations_funded is still not unit-testable -- it needs a live company
# -- so the log line "[company] seeded N skeleton file(s)" is the evidence that
# it is actually called.)
fn test_a_carried_product_stops_the_seeding() -> Result[Unit, Str] {
  if str.is_empty(company_runner.seed_role_for(4, "lex-web-api")) {
    if company_runner.seed_role_for(0, "lex-web-api") == "build" {
      if company_runner.seed_role_for(0, "python-flask") == "py_build" {
        Ok(())
      } else {
        Err("a python path does not seed its own build dir")
      }
    } else {
      Err("an iteration with nothing carried does not seed at all")
    }
  } else {
    Err("a carried product would be overwritten by the skeleton")
  }
}

fn run_all() -> [proc, io] Int {
  let results := [("a carried product stops the seeding", test_a_carried_product_stops_the_seeding()), ("an empty work dir gets the skeleton", test_an_empty_work_dir_gets_the_skeleton()), ("a non-empty work dir is left alone", test_a_non_empty_work_dir_is_left_alone()), ("an unknown path seeds nothing", test_an_unknown_path_seeds_nothing()), ("the skeleton goes to its language's work dir", test_the_skeleton_goes_to_its_languages_work_dir()), ("the goal says the skeleton is on disk", test_the_goal_says_the_skeleton_is_on_disk()), ("a carried product outranks the skeleton", test_a_carried_product_outranks_the_skeleton())]
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

