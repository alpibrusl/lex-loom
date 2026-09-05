# test_launch_entrypoint.lex — launch must be told what the build wrote, and
# the trail must keep enough of a failure to identify it (#320).
#
# In company tzc5 launch ran eight times and failed eight times, every one with
#
#   <python>: can't open file '
#
# The build had written tzconvert.py; launch tried main.py, then app.py. The
# work dir was correct by then (#312), so this is a pure information gap: the
# entry point was being guessed from the build's prose, which does not reliably
# name it.
#
# The second half of the same story is that the trail could not tell me this.
# The recorded result was clipped to its first 300 characters, so the path —
# the one fact identifying the bug — was cut off mid-string, and I had to list
# the directory by hand. A trail exists to make that unnecessary.

import "std.str" as str

import "std.list" as list

import "std.proc" as proc

import "std.io" as io

import "../src/orchestrator" as orch

import "../src/agent/runner" as runner

import "../src/lex_skill" as lexskill

fn test_the_listing_names_the_files_that_exist() -> [proc] Result[Unit, Str] {
  let sprint := "t-entrypoint/iter-1"
  let dir := lexskill.py_work_dir(sprint)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf '", dir, "' && mkdir -p '", dir, "' && touch '", dir, "/tzconvert.py' '", dir, "/test_convert.py'"], "")])
  let listing := orch.launch_file_listing(sprint)
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf '", dir, "'"], "")])
  if str.contains(listing, "tzconvert.py") {
    Ok(())
  } else {
    Err(str.concat("the listing does not name the file the build wrote, got: ", listing))
  }
}

# The names launch actually guessed must NOT appear when they do not exist —
# a listing that mentioned every conventional name would satisfy the test above
# while reproducing the bug exactly.
fn test_the_listing_does_not_invent_conventional_names() -> [proc] Result[Unit, Str] {
  let sprint := "t-entrypoint-2/iter-1"
  let dir := lexskill.py_work_dir(sprint)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf '", dir, "' && mkdir -p '", dir, "' && touch '", dir, "/tzconvert.py'"], "")])
  let listing := orch.launch_file_listing(sprint)
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf '", dir, "'"], "")])
  let invented := list.filter(["main.py", "app.py"], fn (name :: Str) -> Bool {
    str.contains(listing, name)
  })
  if list.is_empty(invented) {
    Ok(())
  } else {
    Err("the listing names files that do not exist, which is what launch was already doing on its own")
  }
}

# __pycache__ is not an entry point and only crowds the list.
fn test_pycache_is_not_offered() -> [proc] Result[Unit, Str] {
  let sprint := "t-entrypoint-3/iter-1"
  let dir := lexskill.py_work_dir(sprint)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf '", dir, "' && mkdir -p '", dir, "/__pycache__' && touch '", dir, "/tzconvert.py'"], "")])
  let listing := orch.launch_file_listing(sprint)
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf '", dir, "'"], "")])
  if str.contains(listing, "__pycache__") {
    Err("__pycache__ is offered as something to launch")
  } else {
    Ok(())
  }
}

# An absent work dir must yield nothing rather than an error string that would
# be pasted into the model's input as if it were a file list.
fn test_a_missing_work_dir_yields_nothing() -> [proc] Result[Unit, Str] {
  let listing := orch.launch_file_listing("t-entrypoint-does-not-exist/iter-9")
  if str.is_empty(listing) {
    Ok(())
  } else {
    Err(str.concat("a missing work dir produced text that would be handed to the model as a file list: ", listing))
  }
}

# --- the trail half -------------------------------------------------------
fn long_result() -> Str {
  str.join(["{\"ok\":false,\"error\":\"server did not respond within 20s on port 8081. The server itself said:", str.join(list.map([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20], fn (i :: Int) -> Str {
    " padding padding padding padding padding padding"
  }), ""), "python: can't open file '/tmp/loom-py-work-tzc5_iter-3/main.py'\"}"], "")
}

# The head alone is not enough: what went wrong is at the end.
fn test_the_trail_keeps_the_end_of_a_long_failure() -> Result[Unit, Str] {
  let kept := runner.clip_ends(long_result(), 700)
  if str.contains(kept, "can't open file '/tmp/loom-py-work-tzc5_iter-3/main.py'") {
    Ok(())
  } else {
    Err("the recorded result still loses the tail, which is where the cause is")
  }
}

fn test_the_trail_still_keeps_the_beginning() -> Result[Unit, Str] {
  let kept := runner.clip_ends(long_result(), 700)
  if str.contains(kept, "server did not respond within 20s") {
    Ok(())
  } else {
    Err("the recorded result lost the head, which says what was attempted")
  }
}

# And it must SAY something was dropped, or a clipped record reads as a
# complete one and the next reader trusts it as the whole story.
fn test_a_clipped_result_admits_it_is_clipped() -> Result[Unit, Str] {
  let kept := runner.clip_ends(long_result(), 700)
  if str.contains(kept, "omitted") {
    Ok(())
  } else {
    Err("a clipped result does not say anything was omitted, so it reads as complete")
  }
}

# It must still be ONE line: the evidence file is tab-separated, one record per
# line, and an embedded newline would split one call into two bogus records.
fn test_a_clipped_result_stays_one_line() -> Result[Unit, Str] {
  let kept := runner.clip_ends(long_result(), 700)
  if str.contains(kept, "\n") or str.contains(kept, "\t") {
    Err("the clipped result contains a newline or tab and would corrupt the tab-separated trail")
  } else {
    Ok(())
  }
}

# Short results must pass through untouched, or every ordinary record grows an
# elision marker it does not need.
fn test_a_short_result_is_untouched() -> Result[Unit, Str] {
  let short := "{\"ok\":true}"
  if runner.clip_ends(short, 700) == short {
    Ok(())
  } else {
    Err("a result that fits was rewritten anyway")
  }
}

fn suite() -> [proc] List[Result[Unit, Str]] {
  [test_the_listing_names_the_files_that_exist(), test_the_listing_does_not_invent_conventional_names(), test_pycache_is_not_offered(), test_a_missing_work_dir_yields_nothing(), test_the_trail_keeps_the_end_of_a_long_failure(), test_the_trail_still_keeps_the_beginning(), test_a_clipped_result_admits_it_is_clipped(), test_a_clipped_result_stays_one_line(), test_a_short_result_is_untouched()]
}

fn run_all() -> [proc] Unit {
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

