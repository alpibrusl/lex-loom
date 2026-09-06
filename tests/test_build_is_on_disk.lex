# test_build_is_on_disk.lex — a build is the files on disk, and a re-run must
# not destroy them (#329).
#
# Company tzc9, iteration 2: the build wrote server.py at 16:44 through
# py_check; QA denied it at 16:54 with a specific bug to fix; the bounce re-run
# began by wiping the work dir ("so stale files don't leak in"), then emitted
# its code as markdown instead of writing it. The gate scratch is seeded from
# the work dir AND every fenced block, so `ls *.py` counted file2.py..file13.py
# extracted from prose and the node was ACCEPTED while the directory held one
# test file. QA and launch then honestly found nothing.

import "std.str" as str

import "std.list" as list

import "std.proc" as proc

import "std.crypto" as crypto

import "../src/agent/runner" as runner

import "../src/orchestrator" as orch

import "../src/lex_skill" as lexskill

fn seed_dir(sprint :: Str, files :: Str) -> [proc] Unit {
  let d := lexskill.py_work_dir(sprint)
  let __ := proc.run("bash", ["-c", str.join(["rm -rf '", d, "' && mkdir -p '", d, "/__pycache__' && cd '", d, "' && for f in ", files, "; do echo 'X = 1' > \"$f\"; done"], "")])
  ()
}

fn listing(sprint :: Str) -> [proc] Str {
  match proc.run("bash", ["-c", str.join(["ls -A '", lexskill.py_work_dir(sprint), "' 2>/dev/null | tr '\\n' ' '"], "")]) {
    Err(_) => "",
    Ok(r) => r.stdout,
  }
}

# --- B1: the wipe keeps the build and removes only scratch ------------------
fn test_clearing_keeps_the_previous_build() -> [proc, random] Result[Unit, Str] {
  let sprint := str.concat("t-keep/", crypto.random_str_hex(4))
  let __s := seed_dir(sprint, "server.py app.py test_app.py _probe.py _check.py")
  let __c := runner.clear_work_dir("py_build", sprint)
  let after := listing(sprint)
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf '", lexskill.py_work_dir(sprint), "'"], "")])
  if not str.contains(after, "server.py") {
    Err("clearing the work dir before a re-run deleted server.py — the repair target QA just denied")
  } else {
    if str.contains(after, "_probe.py") or str.contains(after, "__pycache__") {
      Err(str.concat("scratch and caches were kept: ", after))
    } else {
      Ok(())
    }
  }
}

# --- B2: a build contract counts disk, not fenced prose ---------------------
fn prose_only_build() -> Str {
  "Here is the implementation:\n\n```python\nfrom fastapi import FastAPI\napp = FastAPI()\n```\n\nand a helper:\n\n```python\ndef helper():\n    return 1\n```\n"
}

fn test_a_prose_only_build_fails_its_contract() -> [io, proc, random] Result[Unit, Str] {
  let sprint := str.concat("t-prose/", crypto.random_str_hex(4))
  let __s := seed_dir(sprint, "")
  let r := orch.and_contract("py_build", prose_only_build(), sprint, str.concat("t-prose-", crypto.random_str_hex(4)), Ok(()))
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf '", lexskill.py_work_dir(sprint), "'"], "")])
  match r {
    Ok(_) => Err("a build that wrote nothing to disk satisfied its contract on fenced markdown — this accepted tzc9's empty iteration"),
    Err(_) => Ok(()),
  }
}

fn test_a_build_on_disk_passes_with_no_prose_at_all() -> [io, proc, random] Result[Unit, Str] {
  let sprint := str.concat("t-disk/", crypto.random_str_hex(4))
  let __s := seed_dir(sprint, "server.py")
  let r := orch.and_contract("py_build", "", sprint, str.concat("t-disk-", crypto.random_str_hex(4)), Ok(()))
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf '", lexskill.py_work_dir(sprint), "'"], "")])
  match r {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a build that IS on disk failed its contract: ", e)),
  }
}

# Roles whose output is prose by design must keep counting fences: the change
# is scoped to the nodes that produce the disk, not a blanket.
fn test_a_non_build_role_still_counts_fenced_output() -> [io, proc, random] Result[Unit, Str] {
  let sprint := str.concat("t-fence/", crypto.random_str_hex(4))
  let __s := seed_dir(sprint, "")
  let out := "```python\n# test_x.py\ndef test_one():\n    assert 1 == 1\n```\n"
  let r := orch.and_contract("py_test_author", str.concat("```test_x.py\ndef test_one():\n    assert 1 == 1\n```\n", out), sprint, str.concat("t-fence-", crypto.random_str_hex(4)), Ok(()))
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf '", lexskill.py_work_dir(sprint), "'"], "")])
  match r {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a test author's fenced test file stopped satisfying its contract: ", e)),
  }
}

fn suite() -> [io, proc, random] List[Result[Unit, Str]] {
  [test_clearing_keeps_the_previous_build(), test_a_prose_only_build_fails_its_contract(), test_a_build_on_disk_passes_with_no_prose_at_all(), test_a_non_build_role_still_counts_fenced_output()]
}

fn run_all() -> [io, proc, random] Unit {
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

