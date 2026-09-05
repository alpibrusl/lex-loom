# test_qa_tests_real_files.lex — QA must verify the build's files, not a copy
# it typed out itself (#323).
#
# In company tzc6 the QA node ran real tests — pytest collected five items and
# passed — against an implementation it had RE-CREATED from the build's prose
# output, in /tmp/qa_sprint, a directory of its own invention:
#
#   app_code = textwrap.dedent(''' from fastapi import ...
#   sys.path.insert(0, "/tmp/qa_sprint")
#
# Its verdict was therefore about a copy, not about the artifact that gets
# launched. The design forced this: run_code executed every snippet in a fresh
# mktemp dir with no access to the build, and the prompt's first instruction
# was "Extract every Python file from the Build output."
#
# These tests assert the mechanism, not the wording: a snippet must be able to
# reach the real files.

import "std.str" as str

import "std.list" as list

import "std.proc" as proc

import "std.io" as io

import "lex-schema/json_value" as jv

import "../src/roles" as roles

import "../src/orchestrator" as orch

import "../src/lex_skill" as lexskill

fn get_str(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn seed(sprint :: Str, body :: Str) -> [proc] Unit {
  let dir := lexskill.py_work_dir(sprint)
  let __ := proc.run("bash", ["-c", str.join(["rm -rf '", dir, "' && mkdir -p '", dir, "' && printf '%s' ", str.join(["'", body, "'"], ""), " > '", dir, "/app.py'"], "")])
  ()
}

fn cleanup(sprint :: Str) -> [proc] Unit {
  let __ := proc.run("bash", ["-c", str.join(["rm -rf '", lexskill.py_work_dir(sprint), "'"], "")])
  ()
}

fn run_snippet(sprint :: Str, code :: Str) -> [env, io, net, proc, fs_write] jv.Json {
  let tool := roles.make_run_code_tool("/tmp/loom-qa-evidence-test.json", sprint)
  match tool.execute(JObj([("code", JStr(code)), ("assertions", JStr(""))])) {
    Err(_) => JObj([("output", JStr("tool-level Err"))]),
    Ok(r) => r,
  }
}

# The whole point: a snippet must be able to IMPORT what the build wrote.
fn test_a_snippet_can_import_the_builds_module() -> [env, io, net, proc, fs_write] Result[Unit, Str] {
  let sprint := "t-qa-import/iter-1"
  let __s := seed(sprint, "MARKER = \"from-the-real-build\"\n")
  let out := run_snippet(sprint, "import app\nprint(app.MARKER)\n")
  let __c := cleanup(sprint)
  if str.contains(get_str(out, "output"), "from-the-real-build") {
    Ok(())
  } else {
    Err(str.concat("a QA snippet could not import the build's own module, so it can only test a copy: ", get_str(out, "output")))
  }
}

# ...and read it as a file, which is how a QA agent inspects source.
fn test_a_snippet_can_read_the_builds_file() -> [env, io, net, proc, fs_write] Result[Unit, Str] {
  let sprint := "t-qa-read/iter-1"
  let __s := seed(sprint, "MARKER = \"read-from-disk\"\n")
  let out := run_snippet(sprint, "print(open(\"app.py\").read())\n")
  let __c := cleanup(sprint)
  if str.contains(get_str(out, "output"), "read-from-disk") {
    Ok(())
  } else {
    Err(str.concat("a QA snippet could not open the build's file by name: ", get_str(out, "output")))
  }
}

# The snippet must NOT be written into the work dir: the test-author's gate
# counts the files it finds there, and a stray qa_snippet.py reads as sprawl.
fn test_the_snippet_does_not_litter_the_work_dir() -> [env, io, net, proc, fs_write] Result[Unit, Str] {
  let sprint := "t-qa-litter/iter-1"
  let __s := seed(sprint, "X = 1\n")
  let __r := run_snippet(sprint, "print(1)\n")
  let listing := orch.launch_file_listing(sprint)
  let __c := cleanup(sprint)
  if str.contains(listing, "qa_snippet") {
    Err("run_code left its snippet in the work dir, where the test-author gate counts it as sprawl")
  } else {
    Ok(())
  }
}

# A sprint with no work dir must still run rather than error: QA on a Lex-only
# or TS-only sprint has no python dir, and losing the tool entirely would be
# worse than running in a temp dir.
fn test_it_still_runs_without_a_python_work_dir() -> [env, io, net, proc, fs_write] Result[Unit, Str] {
  let out := run_snippet("t-qa-absent/iter-9", "print(6 * 7)\n")
  if str.contains(get_str(out, "output"), "42") {
    Ok(())
  } else {
    Err(str.concat("run_code stopped working when the sprint has no python work dir: ", get_str(out, "output")))
  }
}

# QA is told which files exist, by the same mechanism launch got in #320.
fn test_qa_roles_get_the_file_listing() -> Result[Unit, Str] {
  let missing := list.filter(["qa", "py_qa", "ts_qa", "launch", "deploy"], fn (role :: Str) -> Bool {
    not orch.needs_the_file_listing(role)
  })
  if list.is_empty(missing) {
    Ok(())
  } else {
    Err(str.concat("these roles act on the build's files but are not told what they are: ", str.join(missing, ", ")))
  }
}

# ...and roles that write the files are NOT given it: a build told which files
# already exist is being invited to edit around them rather than write freely.
fn test_writing_roles_do_not_get_the_listing() -> Result[Unit, Str] {
  let wrongly := list.filter(["py_build", "ts_build", "build", "py_test_author", "pm", "architect"], fn (role :: Str) -> Bool {
    orch.needs_the_file_listing(role)
  })
  if list.is_empty(wrongly) {
    Ok(())
  } else {
    Err(str.concat("roles that write files were handed a file listing: ", str.join(wrongly, ", ")))
  }
}

fn suite() -> [env, io, net, proc, fs_write] List[Result[Unit, Str]] {
  [test_a_snippet_can_import_the_builds_module(), test_a_snippet_can_read_the_builds_file(), test_the_snippet_does_not_litter_the_work_dir(), test_it_still_runs_without_a_python_work_dir(), test_qa_roles_get_the_file_listing(), test_writing_roles_do_not_get_the_listing()]
}

fn run_all() -> [env, io, net, proc, fs_write] Unit {
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

