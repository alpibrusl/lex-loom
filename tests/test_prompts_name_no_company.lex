# test_prompts_name_no_company.lex — loom is the tool; a company is a tenant.
# No prompt may name one.
#
# The strategist's stack guard used to end with "Found live: FormCo
# (2026-09-12, lex-web-api path) had its goal rewritten to 'ship a pytest
# suite' after two slow iterations." True, and useful to a maintainer -- but a
# system prompt is shipped to the strategist of EVERY company loom runs, so one
# tenant's name and failure history were being read by every other tenant's
# model. On a shared install that is a privacy leak, not untidiness.
#
# The same rule lex-soft holds to: the core is mechanism, never a product. A
# comment may name where a bug was found; a string a model reads may not.
#
# Ids come from the manifests in examples/ plus the companies that have really
# run here, so the check keeps working as examples come and go. Add an id when
# a company runs and its manifest does not live in this repo.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.process" as proc

import "../src/roles" as roles

# Companies that have run on this install whose manifests are not (or are no
# longer) in examples/ -- their names must never appear in a prompt either.
fn departed_company_ids() -> List[Str] {
  ["formco", "formcolocal"]
}

fn ids_declared_in_examples() -> [proc] List[Str] {
  match proc.run("bash", ["-c", "grep -h '^id' examples/*.company.toml 2>/dev/null | sed 's/.*= *\"//; s/\".*//'"]) {
    Err(_) => [],
    Ok(r) => list.filter(list.map(str.split(r.stdout, "\n"), fn (l :: Str) -> Str {
      str.trim(l)
    }), fn (l :: Str) -> Bool {
      str.len(l) > 2
    }),
  }
}

fn forbidden_ids() -> [proc] List[Str] {
  list.concat(departed_company_ids(), ids_declared_in_examples())
}

# Every prompt a model is actually handed. A prompt missing from this list is
# a prompt this rule does not cover, so add one whenever a role gains its own.
fn every_prompt() -> [proc] List[(Str, Str)] {
  [("strategist", roles.strategist_system_prompt()), ("architect", roles.architect_system_prompt()), ("pm", roles.pm_system_prompt()), ("qa", roles.qa_system_prompt()), ("py_qa", roles.py_qa_system_prompt()), ("py_build", roles.py_build_system_prompt()), ("ts_build", roles.ts_build_system_prompt()), ("lex directive", roles.architect_language_directive("lex")), ("python directive", roles.architect_language_directive("python")), ("node directive", roles.architect_language_directive("node"))]
}

fn named_in(prompt :: Str, ids :: List[Str]) -> List[Str] {
  list.filter(ids, fn (id :: Str) -> Bool {
    str.contains(str.to_lower(prompt), str.to_lower(id))
  })
}

fn test_no_prompt_names_a_company() -> [proc] Result[Unit, Str] {
  let ids := forbidden_ids()
  list.fold(every_prompt(), Ok(()), fn (acc :: Result[Unit, Str], p :: (Str, Str)) -> Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => match p {
        (name, text) => {
          let hits := named_in(text, ids)
          if list.is_empty(hits) {
            Ok(())
          } else {
            Err(str.join(["the ", name, " prompt names a company: ", str.join(hits, ", ")], ""))
          }
        },
      },
    }
  })
}

# A check that found nothing because it was looking for nothing would pass
# forever. This fails if the id list or the prompt list empties out.
fn test_the_check_is_looking_at_something() -> [proc] Result[Unit, Str] {
  if list.len(forbidden_ids()) > 2 {
    if list.len(every_prompt()) > 6 {
      Ok(())
    } else {
      Err("the prompt list shrank -- this rule now covers almost nothing")
    }
  } else {
    Err("no company ids to look for -- examples/ lost its manifests and the check is vacuous")
  }
}

fn run_all() -> [proc, io] Int {
  let results := [("no prompt names a company", test_no_prompt_names_a_company()), ("the check is looking at something", test_the_check_is_looking_at_something())]
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

