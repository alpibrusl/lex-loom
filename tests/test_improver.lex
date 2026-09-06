# test_improver.lex — regression coverage for the improver's tool-capability
# grounding fix.
#
# Found live (pdfx2 company run): the improver rewrote the `qa` role's system
# prompt to demand things qa's real tools (lex_check, lex_run only) cannot
# do -- "start the binary and confirm it accepts connections", "persist the
# actual smoke-test result to artifacts/smoke/...". qa has no way to start a
# server or make an HTTP request; that's the `launch` role's job. The
# improver had zero visibility into what tools the role it was rewriting
# actually has, so nothing stopped it from inventing requirements beyond
# that role's real capabilities. tool_capability_note fixes this by telling
# the improver's own prompt exactly which tools the target role has.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "../src/improver" as improver

fn test_tool_capability_note_names_qa_tools() -> [env] Result[Unit, Str] {
  let note := improver.tool_capability_note("qa")
  if str.contains(note, "lex_check") {
    if str.contains(note, "lex_run") {
      Ok(())
    } else {
      Err(str.concat("expected lex_run named in the qa capability note: ", note))
    }
  } else {
    Err(str.concat("expected lex_check named in the qa capability note: ", note))
  }
}

fn test_tool_capability_note_names_py_qa_tools() -> [env] Result[Unit, Str] {
  let note := improver.tool_capability_note("py_qa")
  if str.contains(note, "run_code") {
    Ok(())
  } else {
    Err(str.concat("expected run_code named in the py_qa capability note: ", note))
  }
}

# The exact real failure: nothing in a naive capability note stops an
# improver from asking qa to "start a server" -- the note must explicitly
# warn against exceeding the listed tools, not just list them.
fn test_tool_capability_note_warns_against_exceeding_tools() -> [env] Result[Unit, Str] {
  let note := improver.tool_capability_note("qa")
  if str.contains(note, "do not") {
    Ok(())
  } else {
    Err(str.concat("expected an explicit warning against exceeding the listed tools: ", note))
  }
}

fn test_tool_capability_note_handles_toolless_roles() -> [env] Result[Unit, Str] {
  let note := improver.tool_capability_note("pm")
  if str.contains(note, "NO tools") {
    Ok(())
  } else {
    Err(str.concat("expected the no-tools wording for a toolless role: ", note))
  }
}

fn test_improvement_prompt_includes_capability_note() -> [env] Result[Unit, Str] {
  let prompt := improver.improvement_prompt("qa", "old prompt", "lesson learned", [])
  if str.contains(prompt, "lex_check") {
    Ok(())
  } else {
    Err(str.concat("expected the improvement prompt to include the qa capability note: ", prompt))
  }
}

# --- an improvement may not install its own gate on an invented file (#330) ---
fn base_qa_prompt() -> Str {
  "You are the QA agent for a Python sprint. The build's files ALREADY EXIST on disk. Call run_code with assertions that import the build's files by their real names — `import app`, `open(\"app.py\")`, `subprocess.run([\"pytest\", \"-q\"])`. Verdict is PASS only if exit_code=0."
}

# The exact shape tzc10's improver produced, condensed.
fn corrupted_qa_prompt() -> Str {
  str.concat(base_qa_prompt(), "\n\nPRECONDITION (check first, before any other test):\nBefore any assertion you MUST verify the launch node produced an attested artifact. In run_code:\ncandidates = glob.glob(\".launch_attested\") + glob.glob(\"launch_ok.json\") + glob.glob(\"*.launch_status\")\nassert attested, \"PRECONDITION FAILED: no launch-attested artifact found. Refusing to QA a dead binary.\"\nIf this fails, emit FAIL immediately. Do NOT proceed to functional tests.")
}

fn test_the_tzc10_corruption_is_rejected() -> Result[Unit, Str] {
  match improver.installs_a_gate_on_an_invented_artifact(base_qa_prompt(), corrupted_qa_prompt()) {
    Some(why) => if str.contains(why, ".launch_attested") {
      Ok(())
    } else {
      Err(str.concat("rejected, but not for the invented marker: ", why))
    },
    None => Err("the prompt that made QA refuse a launched, accepted build was accepted as an improvement"),
  }
}

# Mentioning a file as an example is not installing a gate.
fn test_citing_a_file_without_refusing_is_fine() -> Result[Unit, Str] {
  let improved := str.concat(base_qa_prompt(), "\n\nFor example, if the build wrote main.py, run `python3 -m pytest -q` and read main.py to confirm the endpoint exists.")
  match improver.installs_a_gate_on_an_invented_artifact(base_qa_prompt(), improved) {
    None => Ok(()),
    Some(why) => Err(str.concat("an improvement that merely cites main.py as an example was rejected: ", why)),
  }
}

# Refusing on a file the base prompt ALREADY names is the role's real gate,
# not an invented one.
fn test_refusing_on_a_known_file_is_fine() -> Result[Unit, Str] {
  let improved := str.concat(base_qa_prompt(), "\n\nPRECONDITION: if app.py is missing, do NOT proceed — emit FAIL immediately.")
  match improver.installs_a_gate_on_an_invented_artifact(base_qa_prompt(), improved) {
    None => Ok(()),
    Some(why) => Err(str.concat("a precondition on a file the base prompt names was rejected: ", why)),
  }
}

# The negative control for the detector itself.
fn test_an_unchanged_prompt_is_not_rejected() -> Result[Unit, Str] {
  match improver.installs_a_gate_on_an_invented_artifact(base_qa_prompt(), base_qa_prompt()) {
    None => Ok(()),
    Some(why) => Err(str.concat("the base prompt was rejected as its own improvement: ", why)),
  }
}

fn test_the_improver_is_told_not_to_install_gates() -> Result[Unit, Str] {
  if str.contains(improver.improver_system_prompt(), "must not install its own gate") {
    Ok(())
  } else {
    Err("the improver's instructions do not forbid installing a gate")
  }
}

fn suite() -> [env] List[Result[Unit, Str]] {
  [test_tool_capability_note_names_qa_tools(), test_tool_capability_note_names_py_qa_tools(), test_tool_capability_note_warns_against_exceeding_tools(), test_tool_capability_note_handles_toolless_roles(), test_improvement_prompt_includes_capability_note(), test_the_tzc10_corruption_is_rejected(), test_citing_a_file_without_refusing_is_fine(), test_refusing_on_a_known_file_is_fine(), test_an_unchanged_prompt_is_not_rejected(), test_the_improver_is_told_not_to_install_gates()]
}

fn run_all() -> [env, io] Unit {
  let results := suite()
  let __dbg := list.map(results, fn (r :: Result[Unit, Str]) -> [io] Unit {
    match r {
      Ok(_) => (),
      Err(e) => io.print(str.concat("FAIL: ", e)),
    }
  })
  let failures := list.fold(results, 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
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

