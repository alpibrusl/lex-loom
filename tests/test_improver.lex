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

fn suite() -> [env] List[Result[Unit, Str]] {
  [test_tool_capability_note_names_qa_tools(), test_tool_capability_note_names_py_qa_tools(), test_tool_capability_note_warns_against_exceeding_tools(), test_tool_capability_note_handles_toolless_roles(), test_improvement_prompt_includes_capability_note()]
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

