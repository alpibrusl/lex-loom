# extract_fenced.lex — fenced code blocks out of an artifact and onto disk.
#
# This runs in front of EVERY `spec sh` gate: verify_shell_on_output_from
# writes the node's answer to a file, runs this over it, and the gate command
# then executes in the directory it produced. A node whose files land under the
# wrong names fails a gate it should have passed, and the role gets the blame.
#
# It is also the reason the gate script installs `python() { python3 "$@"; }`.
# Porting it takes Python out of the gate HARNESS, not just out of one gate
# (lex-loom#512).
#
# Fence forms agents actually emit, in the order the filename is looked for:
#
#   ```app.py            the tag IS the filename
#   ```Dockerfile        an extension-less name a real tool demands by spelling
#   ```python            a language tag, so the name comes from, in order:
#                          - a "# app.py" comment on the NEXT line
#                          - a heading or table cell naming the file just ABOVE
#                          - file1.py, file2.py, ... as a last resort
#
# The heading lookback is not decoration. Some models label a file as
# "### `app.py`" or "| `app.py` | ... |" instead of on the fence line, and
# without it those files fell back to file1.py/file2.py, which then silently
# mismatched whatever a later step (a Dockerfile COPY, an import) expected by
# real name.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.regex" as re

import "std.fs" as fs

import "std.int" as int

type Block = { name :: Str, lines :: List[Str] }

type Scan = { blocks :: List[Block], name :: Str, lines :: List[Str], open :: Bool, counter :: Int, recent :: List[Str], pending :: Bool, fallback :: Str }

fn lang_ext(tag :: Str) -> Str {
  let t := str.to_lower(tag)
  let table := [("lex", "lex"), ("python", "py"), ("py", "py"), ("sh", "sh"), ("bash", "sh"), ("javascript", "js"), ("js", "js"), ("html", "html"), ("css", "css"), ("json", "json"), ("yaml", "yml"), ("yml", "yml"), ("toml", "toml")]
  list.fold(table, "txt", fn (acc :: Str, kv :: (Str, Str)) -> Str {
    match kv {
      (k, v) => if k == t {
        v
      } else {
        acc
      },
    }
  })
}

# Tags that ARE the canonical, extension-less filename a real tool looks for.
# `docker build` wants a file literally named "Dockerfile"; without this a
# devops node's ```Dockerfile fence fell through to file1.txt and the gate
# could never pass (#21).
fn no_ext_filename(tag :: Str) -> Str {
  let t := str.to_lower(tag)
  list.fold([("dockerfile", "Dockerfile"), ("makefile", "Makefile"), ("procfile", "Procfile")], "", fn (acc :: Str, kv :: (Str, Str)) -> Str {
    match kv {
      (k, v) => if k == t {
        v
      } else {
        acc
      },
    }
  })
}

fn sanitize(s :: Str) -> Str {
  match re.compile("[^A-Za-z0-9._/-]") {
    Err(_) => s,
    Ok(r) => re.replace_all(r, s, ""),
  }
}

fn first_group(pattern :: Str, s :: Str) -> Str {
  match re.compile(pattern) {
    Err(_) => "",
    Ok(r) => match re.find(r, s) {
      None => "",
      Some(m) => match list.head(m.groups) {
        None => "",
        Some(g) => g,
      },
    },
  }
}

# A "# app.py" style comment on the line after the fence. Anchored at both ends
# so a line of prose that merely contains a filename does not win over a
# heading that names it deliberately.
fn next_line_name(line :: Str) -> Str {
  first_group("^[#/ ]*([A-Za-z0-9_./-]+\\.[A-Za-z0-9]+)[ \t]*$", str.trim(line))
}

fn heading_name_of(line :: Str) -> Str {
  first_group("[`*#|][ \t]*([A-Za-z0-9_./-]+\\.[A-Za-z0-9]+)", line)
}

fn looks_like_heading(s :: Str) -> Bool {
  list.fold(["#", "*", "|", "-"], false, fn (acc :: Bool, p :: Str) -> Bool {
    if acc {
      true
    } else {
      str.starts_with(s, p)
    }
  })
}

# The label, if any, sits immediately above the fence. A non-empty line that is
# not heading-shaped ends the search rather than letting an unrelated sentence
# further up donate a filename.
fn heading_lookback(recent :: List[Str]) -> Str {
  match list.head(recent) {
    None => "",
    Some(line) => {
      let c := str.trim(line)
      if str.is_empty(c) {
        heading_lookback(list.tail(recent))
      } else {
        let n := heading_name_of(c)
        if not str.is_empty(n) {
          n
        } else {
          if looks_like_heading(c) {
            heading_lookback(list.tail(recent))
          } else {
            ""
          }
        }
      }
    },
  }
}

fn keep_recent(recent :: List[Str], line :: Str) -> List[Str] {
  let grown := list.cons(line, recent)
  if list.len(grown) > 5 {
    list.reverse(list.tail(list.reverse(grown)))
  } else {
    grown
  }
}

# A later fence with the same name REPLACES the earlier one, because the
# Python this replaces opened each file with "w" and the last write won.
fn close_block(st :: Scan) -> List[Block] {
  if st.open {
    list.concat(list.filter(st.blocks, fn (b :: Block) -> Bool {
      b.name != st.name
    }), [{ name: st.name, lines: list.reverse(st.lines) }])
  } else {
    st.blocks
  }
}

fn fence_tag(s :: Str) -> Str {
  str.trim(str.slice(s, 3, str.len(s)))
}

fn name_for_tag(tag :: Str, counter :: Int) -> Str {
  if str.contains(tag, ".") {
    sanitize(tag)
  } else {
    let known := no_ext_filename(tag)
    if not str.is_empty(known) {
      known
    } else {
      str.join(["file", int.to_str(counter), ".", lang_ext(tag)], "")
    }
  }
}

fn step(st :: Scan, line :: Str) -> Scan {
  let s := str.trim(line)
  let resolved := if st.pending {
    let hint := next_line_name(line)
    let chosen := if not str.is_empty(hint) {
      sanitize(hint)
    } else {
      if not str.is_empty(st.fallback) {
        sanitize(st.fallback)
      } else {
        st.name
      }
    }
    { blocks: st.blocks, name: chosen, lines: st.lines, open: st.open, counter: st.counter, recent: st.recent, pending: false, fallback: "" }
  } else {
    st
  }
  if str.starts_with(s, "```") and str.len(s) > 3 {
    let tag := fence_tag(s)
    let generic := not str.contains(tag, ".") and str.is_empty(no_ext_filename(tag))
    let counter := if generic {
      resolved.counter + 1
    } else {
      resolved.counter
    }
    { blocks: close_block(resolved), name: name_for_tag(tag, counter), lines: [], open: true, counter: counter, recent: keep_recent(resolved.recent, line), pending: generic, fallback: if generic {
      heading_lookback(resolved.recent)
    } else {
      ""
    } }
  } else {
    if s == "```" {
      { blocks: close_block(resolved), name: "", lines: [], open: false, counter: resolved.counter, recent: keep_recent(resolved.recent, line), pending: false, fallback: "" }
    } else {
      if resolved.open {
        { blocks: resolved.blocks, name: resolved.name, lines: list.cons(line, resolved.lines), open: true, counter: resolved.counter, recent: keep_recent(resolved.recent, line), pending: resolved.pending, fallback: resolved.fallback }
      } else {
        { blocks: resolved.blocks, name: resolved.name, lines: resolved.lines, open: false, counter: resolved.counter, recent: keep_recent(resolved.recent, line), pending: false, fallback: "" }
      }
    }
  }
}

# An artifact that ends inside a fence still yields the block, the same way the
# Python did by leaving the file handle open until the process exited.
fn extract(text :: Str) -> List[Block] {
  let final := list.fold(str.split(text, "\n"), { blocks: [], name: "", lines: [], open: false, counter: 0, recent: [], pending: false, fallback: "" }, step)
  close_block(final)
}

# A fenced name may carry a directory -- "tests/test_app.lex" is the common
# one, because that is where a test file belongs. Without creating it the write
# fails and the block is silently dropped, which the gate then reports as the
# node producing no tests. Caught by differential test against the Python this
# replaces: 59 of 60 real artifacts matched, and the one that did not was
# exactly this.
fn parent_dir(path :: Str) -> Str {
  let parts := str.split(path, "/")
  if list.len(parts) < 2 {
    ""
  } else {
    str.join(list.reverse(list.tail(list.reverse(parts))), "/")
  }
}

fn write_blocks(dir :: Str, blocks :: List[Block]) -> [fs_write, io] Int {
  list.fold(blocks, 0, fn (n :: Int, b :: Block) -> [fs_write, io] Int {
    if str.is_empty(b.name) {
      n
    } else {
      let path := str.join([dir, "/", b.name], "")
      let __mk := match parent_dir(path) {
        "" => Ok(()),
        d => fs.mkdir_p(d),
      }
      match io.write(path, str.join(list.concat(b.lines, [""]), "\n")) {
        Err(_) => n,
        Ok(_) => n + 1,
      }
    }
  })
}

fn main(src :: Str, dir :: Str) -> [fs_read, fs_write, io] Int {
  match io.read(src) {
    Err(_) => 1,
    Ok(text) => {
      let __ := write_blocks(dir, extract(text))
      0
    },
  }
}

