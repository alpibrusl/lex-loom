# test_denial_leads_with_cause.lex — a denial must say WHY first (#326).
#
# The file listing in gate failures was added in #291, to diagnose a gate that
# reported NO TEST FILE while the test file sat right there. In company tzc8 it
# defeated its own purpose. The work dir held 24 files, so ~400 characters of
# filenames went into the message header AND again at the head of the captured
# gate output; the 1200-character budget was spent before reaching the reason,
# and the recorded denial contained nothing but the listing, twice:
#
#   gate command failed (the gate saw these files: __init__.py _final_check.py
#   _final_verify.py _init_tests.py … validators.py)
#   ##GATE_SAW:__init__.py _final_check.py _final_verify.py _init_tests.py _ru
#
# I could not tell why that node was denied. A diagnostic that crowds out the
# diagnosis is worse than none, because it looks like an explanation.

import "std.str" as str

import "std.list" as list

import "../src/agent/runner" as runner

fn long_listing() -> Str {
  str.join(["__init__.py", "_final_check.py", "_final_verify.py", "_init_tests.py", "_make_dirs.py", "_run_tests.py", "_setup_dirs.py", "_verify.py", "_verify_imports.py", "bootstrap.py", "check_all.py", "conftest.py", "legal_text.py", "main.py", "probe.py", "pyproject.toml", "rate_limit.py", "run_tests.py", "test_convert.py", "validators.py"], " ")
}

fn gate_output() -> Str {
  str.join(["##GATE_SAW:", long_listing(), "\ncheck_derived_values: expected values were PASTED, not derived.\n  test_app.py:37 a timestamp written as a literal\n"], "")
}

# The reason must survive. This is the whole bug: it did not.
fn test_the_cause_survives_a_long_listing() -> Result[Unit, Str] {
  let msg := runner.without_saw(gate_output(), long_listing())
  if str.contains(msg, "expected values were PASTED") {
    Ok(())
  } else {
    Err("the failure reason is gone; only the file listing remains, which is what made a real denial unreadable")
  }
}

# ...and the listing must not still be in there, or nothing was saved.
fn test_the_listing_is_not_repeated_in_the_body() -> Result[Unit, Str] {
  let msg := runner.without_saw(gate_output(), long_listing())
  if str.contains(msg, "_verify_imports.py") {
    Err("the listing is still in the body, so it still crowds out the reason")
  } else {
    Ok(())
  }
}

# A gate output with no listing must pass through untouched, or ordinary
# failures get mangled by a fix aimed at a different shape.
fn test_output_without_a_listing_is_untouched() -> Result[Unit, Str] {
  let plain := "check_imports: a module the build produced does not import."
  if runner.without_saw(plain, "") == plain {
    Ok(())
  } else {
    Err("gate output carrying no file listing was rewritten anyway")
  }
}

fn test_a_long_listing_is_capped() -> Result[Unit, Str] {
  let capped := runner.cap_listing(long_listing(), 12)
  if str.contains(capped, "and 8 more") {
    if str.contains(capped, "__init__.py") {
      Ok(())
    } else {
      Err("capping dropped the beginning of the listing rather than the end")
    }
  } else {
    Err("a 20-name listing was not capped, so it still costs the whole message budget")
  }
}

# The negative control: a cap that fired on everything would satisfy the test
# above while destroying short, useful listings — the exact case #291 needed.
fn test_a_short_listing_is_left_alone() -> Result[Unit, Str] {
  let short := "app.py test_app.py"
  if runner.cap_listing(short, 12) == short {
    Ok(())
  } else {
    Err("a two-file listing was capped, so the diagnostic #291 added is lost for the case it was built for")
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_the_cause_survives_a_long_listing(), test_the_listing_is_not_repeated_in_the_body(), test_output_without_a_listing_is_untouched(), test_a_long_listing_is_capped(), test_a_short_listing_is_left_alone()]
}

fn run_all() -> Unit {
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

