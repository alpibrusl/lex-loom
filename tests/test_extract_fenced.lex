# test_extract_fenced.lex — the extractor that runs in front of every sh gate.
#
# Ported from bin/extract_fenced.py (lex-loom#512) and verified against it
# differentially: 618 of 618 real artifacts from the probe corpus produced
# byte-identical trees. That corpus cannot be kept -- it lives in /tmp and the
# Python it was compared against is deleted -- so the properties it exercised
# are pinned here instead.
#
# The differential run found exactly one real bug, and it is the one worth
# keeping a test for: a fenced name carrying a directory ("tests/test_app.lex",
# which is where a test file belongs) was silently dropped, because the write
# failed and nothing checked. A test_author node would have had its tests
# vanish and then been failed by the gate for producing no tests -- tooling
# blaming the role, which is the failure mode this whole port exists to reduce.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "../bin/extract_fenced" as ex

fn names_of(text :: Str) -> List[Str] {
  list.map(ex.extract(text), fn (b :: ex.Block) -> Str {
    b.name
  })
}

fn body_of(text :: Str, name :: Str) -> Str {
  list.fold(ex.extract(text), "", fn (acc :: Str, b :: ex.Block) -> Str {
    if b.name == name {
      str.join(b.lines, "\n")
    } else {
      acc
    }
  })
}

fn has(names :: List[Str], want :: Str) -> Bool {
  list.fold(names, false, fn (acc :: Bool, n :: Str) -> Bool {
    if acc {
      true
    } else {
      n == want
    }
  })
}

fn test_the_fence_tag_can_be_the_filename() -> Result[Unit, Str] {
  if has(names_of("```app.py\nprint(1)\n```\n"), "app.py") {
    Ok(())
  } else {
    Err("```app.py did not produce app.py")
  }
}

# `docker build` wants a file literally named "Dockerfile". Without this the
# devops node's fence fell through to file1.txt and the gate could never pass.
fn test_an_extensionless_tool_name_keeps_its_spelling() -> Result[Unit, Str] {
  if has(names_of("```Dockerfile\nFROM scratch\n```\n"), "Dockerfile") {
    Ok(())
  } else {
    Err("```Dockerfile did not produce a file named Dockerfile")
  }
}

fn test_a_language_tag_falls_back_to_a_numbered_name() -> Result[Unit, Str] {
  if has(names_of("```python\nx = 1\n```\n"), "file1.py") {
    Ok(())
  } else {
    Err("a bare ```python fence with no label did not produce file1.py")
  }
}

fn test_a_comment_on_the_next_line_names_the_file() -> Result[Unit, Str] {
  if has(names_of("```python\n# app.py\nx = 1\n```\n"), "app.py") {
    Ok(())
  } else {
    Err("a `# app.py` hint on the line after the fence was ignored")
  }
}

# Some models label the file in a heading or a table cell instead of on the
# fence. Missing this sent real files to file1.py, which then mismatched
# whatever a later step expected by name.
fn test_a_heading_above_the_fence_names_the_file() -> Result[Unit, Str] {
  if has(names_of("### `server.lex`\n\n```lex\nfn main() -> Int { 0 }\n```\n"), "server.lex") {
    Ok(())
  } else {
    Err("a heading naming the file just above the fence was ignored")
  }
}

fn test_a_table_row_above_the_fence_names_the_file() -> Result[Unit, Str] {
  if has(names_of("| `handler.js` | the entry point |\n\n```javascript\nx\n```\n"), "handler.js") {
    Ok(())
  } else {
    Err("a table cell naming the file above the fence was ignored")
  }
}

# The label is always immediately above. Letting prose further up donate a
# filename is how an unrelated sentence renames someone else's file.
fn test_unrelated_prose_above_the_fence_does_not_name_the_file() -> Result[Unit, Str] {
  let names := names_of("Some notes about main.py in passing.\n\n```python\nx = 1\n```\n")
  match has(names, "main.py") {
    true => Err("a sentence mentioning main.py in passing renamed the block"),
    false => Ok(()),
  }
}

# THE BUG THE DIFFERENTIAL RUN FOUND.
fn test_a_name_with_a_directory_survives() -> Result[Unit, Str] {
  if has(names_of("```lex\n# tests/test_app.lex\nfn t() -> Int { 0 }\n```\n"), "tests/test_app.lex") {
    Ok(())
  } else {
    Err("a fenced name carrying a directory was dropped — the node's tests vanish and the gate blames the node")
  }
}

# The Python opened each file with "w", so a repeated name kept the LAST block.
# Anything else silently concatenates two versions of a file into one.
fn test_a_repeated_name_keeps_the_last_block() -> Result[Unit, Str] {
  let out := body_of("```a.py\nfirst\n```\n\n```a.py\nsecond\n```\n", "a.py")
  if str.contains(out, "second") and not str.contains(out, "first") {
    Ok(())
  } else {
    Err(str.join(["a repeated filename did not replace the earlier block, it produced: ", out], ""))
  }
}

fn test_the_hint_line_is_still_content() -> Result[Unit, Str] {
  if str.contains(body_of("```python\n# app.py\nx = 1\n```\n", "app.py"), "# app.py") {
    Ok(())
  } else {
    Err("the `# app.py` hint was consumed instead of written into the file, so the file differs from what the model wrote")
  }
}

fn test_prose_outside_any_fence_is_not_extracted() -> Result[Unit, Str] {
  match list.is_empty(ex.extract("Just prose, no fences at all.\n")) {
    true => Ok(()),
    false => Err("prose with no fences produced a file"),
  }
}

# An artifact that ends mid-fence still yields the block, the way the Python
# did by leaving the handle open until the process exited.
fn test_an_unterminated_fence_still_yields_its_block() -> Result[Unit, Str] {
  if has(names_of("```a.py\nx = 1\n"), "a.py") {
    Ok(())
  } else {
    Err("a truncated artifact lost its last block entirely")
  }
}

fn run_all() -> [io] Int {
  let results := [("the fence tag can be the filename", test_the_fence_tag_can_be_the_filename()), ("an extensionless tool name keeps its spelling", test_an_extensionless_tool_name_keeps_its_spelling()), ("a language tag falls back to a numbered name", test_a_language_tag_falls_back_to_a_numbered_name()), ("a comment on the next line names the file", test_a_comment_on_the_next_line_names_the_file()), ("a heading above the fence names the file", test_a_heading_above_the_fence_names_the_file()), ("a table row above the fence names the file", test_a_table_row_above_the_fence_names_the_file()), ("unrelated prose above the fence does not name the file", test_unrelated_prose_above_the_fence_does_not_name_the_file()), ("a name with a directory survives", test_a_name_with_a_directory_survives()), ("a repeated name keeps the last block", test_a_repeated_name_keeps_the_last_block()), ("the hint line is still content", test_the_hint_line_is_still_content()), ("prose outside any fence is not extracted", test_prose_outside_any_fence_is_not_extracted()), ("an unterminated fence still yields its block", test_an_unterminated_fence_still_yields_its_block())]
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

