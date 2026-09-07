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

import "lex-schema/json_value" as jv

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

# --- the GATE path: same rule as the contract, one choke point (#332) --------
# #329 closed the fence hole for the role contract and missed the Architect's
# gate, which took the same path. tzc11's build was denied for `setup` and
# `verify` modules that existed only in its prose; they reached disk twenty
# minutes later, in the retry.
fn test_a_build_gate_ignores_fenced_prose() -> [io, proc, random] Result[Unit, Str] {
  let sprint := str.concat("t-gate-prose/", crypto.random_str_hex(4))
  let __s := seed_dir(sprint, "")
  let r := runner.verify_shell_for_role("python3 $LOOM_ROOT/bin/check_imports.py .", "py_build", "```python\nimport definitely_not_a_module\n```\n", str.concat("t-gate-prose-", crypto.random_str_hex(4)), lexskill.py_work_dir(sprint))
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf '", lexskill.py_work_dir(sprint), "'"], "")])
  match r {
    Ok(_) => Err("with nothing on disk a build gate passed — it can only have judged the fenced prose, or nothing"),
    Err(e) => if str.contains(e, "definitely_not_a_module") {
      Err("the build gate judged a module that exists only in prose — the tzc11 denial")
    } else {
      Ok(())
    },
  }
}

fn test_a_build_gate_judges_the_disk() -> [io, proc, random] Result[Unit, Str] {
  let sprint := str.concat("t-gate-disk/", crypto.random_str_hex(4))
  let __s := seed_dir(sprint, "server.py")
  let r := runner.verify_shell_for_role("python3 $LOOM_ROOT/bin/check_imports.py .", "py_build", "", str.concat("t-gate-disk-", crypto.random_str_hex(4)), lexskill.py_work_dir(sprint))
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf '", lexskill.py_work_dir(sprint), "'"], "")])
  match r {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a build that IS on disk failed its gate with no prose at all: ", e)),
  }
}

# A prose role's gate must still see its fences: a docs node's Dockerfile
# exists nowhere but in its answer.
fn test_a_prose_role_gate_still_sees_fences() -> [io, proc, random] Result[Unit, Str] {
  let r := runner.verify_shell_for_role("test -f Dockerfile", "docs", "```Dockerfile\nFROM python:3.12\n```\n", str.concat("t-gate-fence-", crypto.random_str_hex(4)), "")
  match r {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a docs node's fenced Dockerfile stopped satisfying its gate: ", e)),
  }
}

# --- `python` means python3 inside a gate (#333) --------------------------
# tzc11's Architect wrote a devops gate as `python -c '...'`; this host has no
# `python`, only `python3`, and the gate failed eight times on exit 127.
fn test_a_gate_may_say_python() -> [io, proc, random] Result[Unit, Str] {
  match runner.verify_shell_for_role("python -c 'print(1)'", "devops", "```notes.md\nhello\n```\n", str.concat("t-py-", crypto.random_str_hex(4)), "") {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a gate that says `python` fails on a host with only python3: ", e)),
  }
}

# --- the build can remove a file it wrote (#333) ----------------------------
# check_imports holds the build to every module in the directory, and the
# build had no way to remove one: tzc10's force42.py and tzc11's setup.py /
# probe.py cost six and four denials respectively, with no move available.
fn test_py_check_can_delete_a_file_it_wrote() -> [env, io, net, proc, random, fs_write] Result[Unit, Str] {
  let sprint := str.concat("t-del/", crypto.random_str_hex(4))
  let tool := lexskill.make_py_check_tool("/tmp/loom-lexcheck-evidence-test.json", sprint)
  let __w := tool.execute(JObj([("filename", JStr("probe.py")), ("code", JStr("print(1)\n"))]))
  let before := listing(sprint)
  let __d := tool.execute(JObj([("filename", JStr("probe.py")), ("code", JStr("")), ("delete", JBool(true))]))
  let after := listing(sprint)
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf '", lexskill.py_work_dir(sprint), "'"], "")])
  if not str.contains(before, "probe.py") {
    Err("setup failed: the write did not land, so the delete proved nothing")
  } else {
    if str.contains(after, "probe.py") {
      Err("delete:true left the file on disk — the build still has no way to recover from a bad scratch file")
    } else {
      Ok(())
    }
  }
}

# #340: a filename with a folder in it must land. tzc14's build wrote
# tests/test_convert.py, the write failed silently, py_compile reported "No
# such file", and the builder spent its remaining budget on bootstrap scripts.
fn test_py_check_writes_into_a_subdirectory() -> [env, io, net, proc, random, fs_write] Result[Unit, Str] {
  let sprint := str.concat("t-sub/", crypto.random_str_hex(4))
  let tool := lexskill.make_py_check_tool("/tmp/loom-lexcheck-evidence-test.json", sprint)
  let r := tool.execute(JObj([("filename", JStr("tests/test_x.py")), ("code", JStr("def test_x():\n    assert 1 == 1\n"))]))
  let on_disk := match proc.run("bash", ["-c", str.join(["test -f '", lexskill.py_work_dir(sprint), "/tests/test_x.py' && echo yes || echo no"], "")]) {
    Ok(o) => str.trim(o.stdout),
    Err(_) => "?",
  }
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf '", lexskill.py_work_dir(sprint), "'"], "")])
  let ok := match r {
    Ok(res) => match jv.get_field(res, "ok") {
      Some(JStr(v)) => v,
      _ => "missing",
    },
    Err(_) => "err",
  }
  if on_disk == "yes" and ok == "true" {
    Ok(())
  } else {
    Err(str.join(["py_check could not write into a subdirectory (on_disk=", on_disk, " ok=", ok, ") -- the tzc14 builder's 'directory creation doesn't persist'"], ""))
  }
}

fn suite() -> [env, io, net, proc, random, fs_write] List[Result[Unit, Str]] {
  [test_clearing_keeps_the_previous_build(), test_a_prose_only_build_fails_its_contract(), test_a_build_on_disk_passes_with_no_prose_at_all(), test_a_non_build_role_still_counts_fenced_output(), test_a_build_gate_ignores_fenced_prose(), test_a_build_gate_judges_the_disk(), test_a_prose_role_gate_still_sees_fences(), test_a_gate_may_say_python(), test_py_check_can_delete_a_file_it_wrote(), test_py_check_writes_into_a_subdirectory()]
}

fn run_all() -> [env, io, net, proc, random, fs_write] Unit {
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

