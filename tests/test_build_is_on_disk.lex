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

import "lex-schema/error" as e

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

# #345: the Lex build eval lost 2/5 to probe.lex/probe1.lex -- scratch files
# that never compiled, left in a work dir whose compiles gate checks every
# file. lex_check can now remove a file, and the denial says so.
fn test_lex_check_can_delete_a_file_it_wrote() -> [env, io, net, proc, random, fs_write] Result[Unit, Str] {
  let sprint := str.concat("t-ldel/", crypto.random_str_hex(4))
  let tool := lexskill.make_lex_check_tool("/tmp/loom-lexcheck-evidence-test.json", sprint)
  let __w := tool.execute(JObj([("filename", JStr("probe.lex")), ("code", JStr("fn p() -> Int {\n  1\n}\n"))]))
  let d := lexskill.work_dir(sprint)
  let before := match proc.run("bash", ["-c", str.join(["ls -A '", d, "' 2>/dev/null | tr '\\n' ' '"], "")]) {
    Ok(r) => r.stdout,
    Err(_) => "",
  }
  let __d := tool.execute(JObj([("filename", JStr("probe.lex")), ("code", JStr("")), ("delete", JBool(true))]))
  let after := match proc.run("bash", ["-c", str.join(["ls -A '", d, "' 2>/dev/null | tr '\\n' ' '"], "")]) {
    Ok(r) => r.stdout,
    Err(_) => "",
  }
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf '", d, "'"], "")])
  if not str.contains(before, "probe.lex") {
    Err("setup failed: the lex_check write did not land, so the delete proved nothing")
  } else {
    if str.contains(after, "probe.lex") {
      Err("lex_check delete:true left the file on disk -- the Lex build still cannot recover from a bad probe")
    } else {
      Ok(())
    }
  }
}

fn test_compile_denial_names_the_way_out() -> [env, io, net, proc, random, fs_write] Result[Unit, Str] {
  let sprint := str.concat("t-lprobe/", crypto.random_str_hex(4))
  let d := lexskill.work_dir(sprint)
  let __seed := proc.run("bash", ["-c", str.join(["rm -rf '", d, "' && mkdir -p '", d, "' && printf 'fn main() -> Int {\\n  1\\n}\\n' > '", d, "/main.lex' && printf 'fn broken( {\\n' > '", d, "/probe.lex'"], "")])
  let r := runner.verify_compiles_at("", "build", sprint)
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf '", d, "'"], "")])
  match r {
    Ok(_) => Err("a work dir holding a broken probe.lex passed the compiles gate"),
    Err(msg) => if str.contains(msg, "delete:true") {
      Ok(())
    } else {
      Err(str.concat("the compile denial does not tell the builder it may delete the probe: ", str.slice(msg, 0, 200)))
    },
  }
}

# #364: after a passing iteration the product carries into the next one.
fn test_carry_forward_copies_the_product_and_skips_scratch() -> [env, io, net, proc, random, fs_write] Result[Unit, Str] {
  let tag := crypto.random_str_hex(4)
  let prev := str.join(["t-carry-", tag, "/iter-1"], "")
  let next := str.join(["t-carry-", tag, "/iter-2"], "")
  let pd := lexskill.py_work_dir(prev)
  let nd := lexskill.py_work_dir(next)
  let __seed := proc.run("bash", ["-c", str.join(["rm -rf '", pd, "' '", nd, "' && mkdir -p '", pd, "/tests' '", pd, "/__pycache__' && printf 'def add(a, b):\\n    return a + b\\n' > '", pd, "/app.py' && printf 'from app import add\\ndef test_add():\\n    assert add(1, 1) == 2\\n' > '", pd, "/tests/test_app.py' && : > '", pd, "/_scratch.py' && : > '", pd, "/__pycache__/app.cpython-314.pyc'"], "")])
  let n := runner.carry_artifact_forward(prev, next)
  let after := match proc.run("bash", ["-c", str.join(["cd '", nd, "' 2>/dev/null && find . -type f | sort | tr '\\n' ' '"], "")]) {
    Ok(r) => str.trim(r.stdout),
    Err(_) => "?",
  }
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf '", pd, "' '", nd, "'"], "")])
  if str.contains(after, "./app.py") and str.contains(after, "./tests/test_app.py") and n == 2 {
    if str.contains(after, "_scratch") or str.contains(after, "__pycache__") {
      Err(str.concat("scratch or cache files were carried into the next iteration: ", after))
    } else {
      Ok(())
    }
  } else {
    Err(str.join(["the previous iteration's product did not reach the next work dir (n=", int.to_str(n), "): ", after], ""))
  }
}

fn test_carry_forward_leaves_an_existing_work_dir_alone() -> [env, io, net, proc, random, fs_write] Result[Unit, Str] {
  let tag := crypto.random_str_hex(4)
  let prev := str.join(["t-carry2-", tag, "/iter-1"], "")
  let next := str.join(["t-carry2-", tag, "/iter-2"], "")
  let pd := lexskill.py_work_dir(prev)
  let nd := lexskill.py_work_dir(next)
  let __seed := proc.run("bash", ["-c", str.join(["rm -rf '", pd, "' '", nd, "' && mkdir -p '", pd, "' '", nd, "' && printf 'x = 1\\n' > '", pd, "/app.py' && printf 'y = 2\\n' > '", nd, "/own.py'"], "")])
  let n := runner.carry_artifact_forward(prev, next)
  let after := match proc.run("bash", ["-c", str.join(["ls '", nd, "' | tr '\\n' ' '"], "")]) {
    Ok(r) => str.trim(r.stdout),
    Err(_) => "?",
  }
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf '", pd, "' '", nd, "'"], "")])
  if n == 0 and after == "own.py" {
    Ok(())
  } else {
    Err(str.join(["an existing work dir was written over by the carry (n=", int.to_str(n), "): ", after], ""))
  }
}

fn read_field(r :: Result[jv.Json, e.Errors], field :: Str) -> Str {
  match r {
    Ok(res) => match jv.get_field(res, field) {
      Some(JStr(v)) => v,
      _ => "",
    },
    Err(_) => "err",
  }
}

fn test_read_file_reads_the_work_dir_and_refuses_escapes() -> [env, io, net, proc, random, fs_write] Result[Unit, Str] {
  let sprint := str.concat("t-read/", crypto.random_str_hex(4))
  let d := lexskill.py_work_dir(sprint)
  let __seed := proc.run("bash", ["-c", str.join(["rm -rf '", d, "' && mkdir -p '", d, "/pkg' && printf 'def add(a, b):\\n    return a + b\\n' > '", d, "/pkg/app.py' && head -c 20000 /dev/zero | tr '\\0' 'x' > '", d, "/big.py'"], "")])
  let tool := lexskill.make_read_file_tool(sprint)
  let ok_read := tool.execute(JObj([("filename", JStr("pkg/app.py"))]))
  let escape := tool.execute(JObj([("filename", JStr("../../etc/passwd"))]))
  let big := tool.execute(JObj([("filename", JStr("big.py"))]))
  let missing := tool.execute(JObj([("filename", JStr("nope.py"))]))
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf '", d, "'"], "")])
  if read_field(ok_read, "ok") == "true" and str.contains(read_field(ok_read, "content"), "def add(a, b)") {
    if read_field(escape, "ok") == "false" and read_field(missing, "ok") == "false" {
      if str.contains(read_field(big, "content"), "cut at 12000") and str.len(read_field(big, "content")) < 12100 {
        Ok(())
      } else {
        Err("a 20000-byte file was not cut at 12000 characters")
      }
    } else {
      Err("read_file followed a '..' path or reported a missing file as ok")
    }
  } else {
    Err(str.concat("read_file could not read a file the build wrote: ", read_field(ok_read, "content")))
  }
}

fn suite() -> [env, io, net, proc, random, fs_write] List[Result[Unit, Str]] {
  [test_clearing_keeps_the_previous_build(), test_a_prose_only_build_fails_its_contract(), test_a_build_on_disk_passes_with_no_prose_at_all(), test_a_non_build_role_still_counts_fenced_output(), test_a_build_gate_ignores_fenced_prose(), test_a_build_gate_judges_the_disk(), test_a_prose_role_gate_still_sees_fences(), test_a_gate_may_say_python(), test_py_check_can_delete_a_file_it_wrote(), test_py_check_writes_into_a_subdirectory(), test_lex_check_can_delete_a_file_it_wrote(), test_compile_denial_names_the_way_out(), test_carry_forward_copies_the_product_and_skips_scratch(), test_carry_forward_leaves_an_existing_work_dir_alone(), test_read_file_reads_the_work_dir_and_refuses_escapes()]
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

