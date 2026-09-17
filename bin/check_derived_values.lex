# check_derived_values.lex — expected values that were PASTED rather than
# derived.
#
# A test is an oracle. When its expected values are hand-written constants, a
# wrong one is indistinguishable from a real bug: the run that prompted this
# asserted a Unix epoch an hour off against a CORRECT implementation, every
# gate did its job and refused to seal, and three iterations went into changing
# working code to satisfy it.
#
# Asking a model to "derive expected values" is a request. This makes it
# checkable: a value that was computed leaves a computation in the source, and
# a value that was pasted leaves a literal.
#
# DELIBERATELY NARROW. It flags only literals that plausibly encode a DERIVED
# quantity -- Unix epochs and full timestamps -- and never small integers,
# status codes, short strings or booleans, which are legitimately written out.
# A check that cried wolf on `== 400` would be turned off within a day.
#
# WHAT STAYS IN PYTHON, AND WHY (lex-loom#512). Two of this gate's four jobs
# PARSE AND RUN PYTHON TEST CODE: executing a pin means walking a Python AST,
# reconstructing the expression source and evaluating it, and asking whether a
# suite can be COLLECTED means running pytest and reading its exit codes.
# Neither is loom's logic in another language -- they are the company's product
# language, like paths/python-* and py_compile. They live in bin/py_test_pins.py
# and run only when the work dir holds Python test files. A Lex company's gate
# never invokes them.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.fs" as fs

import "std.process" as proc

import "std.regex" as re

import "std.int" as int

type Finding = { file :: Str, line :: Int, what :: Str, literal :: Str, src :: Str }

fn timestamp_pattern() -> Str {
  "\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}"
}

fn rfc2822_pattern() -> Str {
  "[A-Z][a-z]{2}, \\d{1,2} [A-Z][a-z]{2} \\d{4} \\d{2}:\\d{2}:\\d{2}"
}

fn find_all_of(pattern :: Str, text :: Str) -> List[{ text :: Str, start :: Int, end :: Int, groups :: List[Str] }] {
  match re.compile(pattern) {
    Err(_) => [],
    Ok(r) => re.find_all(r, text),
  }
}

fn matches(pattern :: Str, text :: Str) -> Bool {
  not list.is_empty(find_all_of(pattern, text))
}

# A 9-11 digit integer is almost certainly a Unix epoch. Below that it is a
# count, an id, a port, a size -- things a test may legitimately state.
#
# The Python wrote this as `(?<![\d.])\d{9,11}(?![\d.])`. std.regex supports no
# look-around at all, so this finds maximal digit runs and inspects the
# characters either side by POSITION, which is what the look-around meant: a
# run of exactly 9-11 digits, not part of a longer number and not part of a
# decimal.
fn epochs_in(text :: Str) -> List[Str] {
  list.fold(find_all_of("\\d+", text), [], fn (acc :: List[Str], m :: { text :: Str, start :: Int, end :: Int, groups :: List[Str] }) -> List[Str] {
    let n := str.len(m.text)
    if n < 9 or n > 11 {
      acc
    } else {
      let before_ok := m.start == 0 or str.slice(text, m.start - 1, m.start) != "."
      let after_ok := m.end >= str.len(text) or str.slice(text, m.end, m.end + 1) != "."
      if before_ok and after_ok {
        list.concat(acc, [m.text])
      } else {
        acc
      }
    }
  })
}

fn literals_in(text :: Str) -> List[(Str, Str)] {
  list.concat(list.map(epochs_in(text), fn (l :: Str) -> (Str, Str) {
    (l, "a Unix epoch")
  }), list.concat(list.map(find_all_of(timestamp_pattern(), text), fn (m :: { text :: Str, start :: Int, end :: Int, groups :: List[Str] }) -> (Str, Str) {
    (m.text, "a timestamp")
  }), list.map(find_all_of(rfc2822_pattern(), text), fn (m :: { text :: Str, start :: Int, end :: Int, groups :: List[Str] }) -> (Str, Str) {
    (m.text, "an RFC 2822 date")
  })))
}

# A line that calls into a date/time library is DERIVING, not pasting.
fn looks_computed(line :: Str) -> Bool {
  list.fold(["datetime", "timestamp()", "zoneinfo", "ZoneInfo", "timedelta", "fromisoformat", "isoformat", "astimezone", "strftime", "format_datetime", "formatdate", "utcfromtimestamp", "time.", "calendar."], false, fn (acc :: Bool, t :: Str) -> Bool {
    if acc {
      true
    } else {
      str.contains(line, t)
    }
  })
}

fn is_assertish(line :: Str) -> Bool {
  str.contains(line, "assert") or str.contains(line, "assertEqual") or str.contains(line, "==") or str.contains(line, "Err(") or str.contains(line, "expected")
}

# Only the EXPECTED value can be pasted; the input side is data the test
# legitimately states. `assert convert("2024-01-15T12:00:00", ...) == x` has a
# timestamp on the LEFT as an INPUT -- flagging it is the kind of false alarm
# that gets a check switched off.
fn expected_side(line :: Str) -> Str {
  if not str.contains(line, "==") {
    ""
  } else {
    str.join(list.tail(str.split(line, "==")), "==")
  }
}

fn contains_str(xs :: List[Str], want :: Str) -> Bool {
  list.fold(xs, false, fn (acc :: Bool, x :: Str) -> Bool {
    if acc {
      true
    } else {
      x == want
    }
  })
}

# Names bound to a derivation, and derivation is TRANSITIVE because it is
# written that way:
#
#     expected_dt  = datetime(...).astimezone(...)   <- computed
#     expected_iso = expected_dt.isoformat()         <- computed FROM it
#
# Taking only the first pass would leave expected_iso unrecognised, which is
# precisely the name the pin below compares against.
fn derived_names(lines :: List[Str], acc :: List[Str], rounds :: Int) -> List[Str] {
  if rounds <= 0 {
    acc
  } else {
    let grown := list.fold(lines, acc, fn (names :: List[Str], line :: Str) -> List[Str] {
      let name := assigned_name(line)
      if str.is_empty(name) or contains_str(names, name) {
        names
      } else {
        let rhs := str.join(list.tail(str.split(line, "=")), "=")
        let from_derived := list.fold(names, false, fn (f :: Bool, n :: Str) -> Bool {
          f or word_in(rhs, n)
        })
        if looks_computed(line) or from_derived {
          list.concat(names, [name])
        } else {
          names
        }
      }
    })
    if list.len(grown) == list.len(acc) {
      grown
    } else {
      derived_names(lines, grown, rounds - 1)
    }
  }
}

fn assigned_name(line :: Str) -> Str {
  match list.head(find_all_of("^\\s*([A-Za-z_]\\w*)\\s*=[^=]", line)) {
    None => "",
    Some(m) => match list.head(m.groups) {
      None => "",
      Some(g) => g,
    },
  }
}

fn word_in(hay :: Str, word :: Str) -> Bool {
  matches(str.join(["\\b", word, "\\b"], ""), hay)
}

fn local_fns(text :: Str) -> List[Str] {
  list.fold(find_all_of("(?m)^\\s*def\\s+([A-Za-z_]\\w*)\\s*\\(", text), [], fn (acc :: List[Str], m :: { text :: Str, start :: Int, end :: Int, groups :: List[Str] }) -> List[Str] {
    match list.head(m.groups) {
      None => acc,
      Some(g) => list.concat(acc, [g]),
    }
  })
}

# Literals the file itself checks AGAINST a derivation.
#
# Banning literals outright is too blunt, and a real run proved it: a test
# author pasted "2025-07-11T08:00:00-04:00", the gate refused it four times,
# and the pasted value was RIGHT -- it caught a genuine four-hour bug in the
# implementation. The property worth demanding is not "computed" but
# "CHECKABLE". A literal pinned to a derivation is checkable: if the paste is
# wrong, THAT assertion fails and names the oracle, instead of the
# implementation being blamed for the author's typo.
#
# A call to a helper DEFINED IN THIS FILE is a derivation too (#366): tzc19's
# author wrote `assert expected_iso() == "..."` -- the pin idiom with the
# derivation behind a def -- and was denied eight times as a paste.
fn pinned_literals(lines :: List[Str], text :: Str) -> List[Str] {
  let names := derived_names(lines, [], 4)
  let fns := local_fns(text)
  list.fold(lines, [], fn (acc :: List[Str], line :: Str) -> List[Str] {
    let calls_local := list.fold(fns, false, fn (f :: Bool, name :: Str) -> Bool {
      f or matches(str.join(["\\b", name, "\\s*\\("], ""), line)
    })
    let inline := looks_computed(line) or str.contains(line, "==") and calls_local
    let via_name := str.contains(line, "==") and list.fold(names, false, fn (f :: Bool, n :: Str) -> Bool {
      f or word_in(line, n)
    })
    if inline or via_name {
      list.concat(acc, list.map(literals_in(line), fn (lw :: (Str, Str)) -> Str {
        match lw {
          (l, _) => l,
        }
      }))
    } else {
      acc
    }
  })
}

fn count_occurrences(hay :: Str, needle :: Str) -> Int {
  list.len(str.split(hay, needle)) - 1
}

fn clip(s :: Str, n :: Int) -> Str {
  if str.len(s) > n {
    str.slice(s, 0, n)
  } else {
    s
  }
}

fn basename(p :: Str) -> Str {
  match list.head(list.reverse(str.split(p, "/"))) {
    None => p,
    Some(b) => b,
  }
}

# A literal appearing MORE THAN ONCE in the file is an INPUT being echoed, not
# a hand-written oracle: a timestamp posted in a request body and then asserted
# in the response is a real round-trip test. tzc11 denied one such assertion
# ten times across three iterations -- the single largest denial source in that
# run.
fn scan(path :: Str, text :: Str) -> List[Finding] {
  let lines := str.split(text, "\n")
  let pins := pinned_literals(lines, text)
  list.fold(list.enumerate(lines), [], fn (acc :: List[Finding], il :: (Int, Str)) -> List[Finding] {
    match il {
      (i, line) => {
        let s := str.trim(line)
        if str.starts_with(s, "#") or not is_assertish(s) {
          acc
        } else {
          let rhs := expected_side(s)
          if str.is_empty(rhs) or looks_computed(rhs) {
            acc
          } else {
            match list.head(literals_in(rhs)) {
              None => acc,
              Some(lw) => match lw {
                (lit, what) => if contains_str(pins, lit) or count_occurrences(text, lit) >= 2 {
                  acc
                } else {
                  list.concat(acc, [{ file: basename(path), line: i + 1, what: what, literal: lit, src: clip(s, 100) }])
                },
              },
            }
          }
        }
      },
    }
  })
}

# A Lex test that imports nothing from the work dir tests a stub of its own
# making. lexwc4 iteration 1: the author defined `handle` inside
# wordcount_test.lex returning {body:"{}", status:200}; all five tests ran
# against that stub, all five failed against the real server at QA (#404).
fn lex_stub_failure(files :: List[(Str, Str)]) -> Str {
  let bad := list.fold(files, [], fn (acc :: List[Str], ft :: (Str, Str)) -> List[Str] {
    match ft {
      (path, text) => if not str.ends_with(path, ".lex") {
        acc
      } else {
        if matches("(?m)^\\s*import \"\\./", text) {
          acc
        } else {
          list.concat(acc, [basename(path)])
        }
      },
    }
  })
  if list.is_empty(bad) {
    ""
  } else {
    str.join(["check_derived_values: a Lex test file imports nothing from the work dir, so it can\nonly test a stub of its own:\n\n", str.join(list.map(bad, fn (b :: Str) -> Str {
      str.concat("  ", b)
    }), "\n"), "\n\nImport the module the build writes -- `import \"./server\" as server` -- and call\nits functions; do not define the implementation inside the test.\n"], "")
  }
}

fn glob_of(pattern :: Str) -> [fs_walk] List[Str] {
  match fs.glob(pattern) {
    Err(_) => [],
    Ok(g) => g,
  }
}

fn is_test_file(path :: Str) -> Bool {
  let b := str.to_lower(basename(path))
  if str.starts_with(b, "_") {
    false
  } else {
    if str.ends_with(b, ".py") or str.ends_with(b, ".lex") {
      str.contains(b, "test")
    } else {
      false
    }
  }
}

fn test_files(root :: Str) -> [fs_walk] List[Str] {
  list.filter(list.concat(glob_of(str.join([root, "/**/*.py"], "")), glob_of(str.join([root, "/**/*.lex"], ""))), fn (p :: Str) -> Bool {
    is_test_file(p) and not str.contains(p, "__pycache__")
  })
}

# The two jobs that must parse and RUN Python test code. Only when the work dir
# holds Python test files: a Lex suite is collected by `lex run <file> run_all`,
# not by pytest, and the Lex test_author eval read 0/5 because every attempt was
# denied "no tests collected" by a pytest run over a directory of .lex files
# (#344).
# The helper's path is passed IN, not written as "bin/py_test_pins.py". A gate
# runs with the work dir as its cwd, so a relative path resolves inside the
# company's own tree and the helper is simply not there -- which produced a
# python3 "can't open file" on stderr and a criterion silently unchecked. The
# shim knows where it lives; the checker should not have to guess.
fn python_side(helper :: Str, root :: Str, has_py :: Bool) -> [proc] Str {
  if not has_py or str.is_empty(helper) {
    ""
  } else {
    match proc.run("python3", [helper, root]) {
      Err(_) => "",
      Ok(r) => str.trim(str.concat(r.stdout, r.stderr)),
    }
  }
}

fn main(root_arg :: Str, helper :: Str) -> [fs_read, fs_walk, proc, io] Int {
  let root := if str.is_empty(root_arg) {
    "."
  } else {
    root_arg
  }
  let paths := test_files(root)
  if list.is_empty(paths) {
    no_test_file()
  } else {
    let files := list.fold(paths, [], fn (acc :: List[(Str, Str)], p :: Str) -> [fs_read, io] List[(Str, Str)] {
      match io.read(p) {
        Err(_) => acc,
        Ok(t) => list.concat(acc, [(p, t)]),
      }
    })
    let findings := list.fold(files, [], fn (acc :: List[Finding], ft :: (Str, Str)) -> List[Finding] {
      match ft {
        (p, t) => list.concat(acc, scan(p, t)),
      }
    })
    if not list.is_empty(findings) {
      pasted(findings, list.fold(files, false, fn (acc :: Bool, ft :: (Str, Str)) -> Bool {
        match ft {
          (p, _) => acc or str.ends_with(p, ".lex"),
        }
      }))
    } else {
      let py := python_side(helper, root, list.fold(files, false, fn (acc :: Bool, ft :: (Str, Str)) -> Bool {
        match ft {
          (p, _) => acc or str.ends_with(p, ".py"),
        }
      }))
      if not str.is_empty(py) {
        let __ := io.print(py)
        1
      } else {
        let stub := lex_stub_failure(files)
        if not str.is_empty(stub) {
          let __ := io.print(stub)
          1
        } else {
          let __ := io.print(str.join(["check_derived_values: ", int.to_str(list.len(files)), " test file(s), expected values are derived"], ""))
          0
        }
      }
    }
  }
}

# Not "nothing to check" -- this IS the finding. A test author whose gate exits
# 0 for writing no tests seals and hands off, and QA then dies three retries
# later with "NO TEST FILE", wearing the blame for the omission. Watched happen
# in tzpin: 3 QA denials, all misfiled.
fn no_test_file() -> [io] Int {
  let __a := io.print("check_derived_values: NO TEST FILE was written.\n")
  let __b := io.print("A test author's deliverable is a test file. Write one (test_*.py,")
  let __c := io.print("*_test.py, or *_test.lex) with py_check/lex_check so it is on disk,")
  let __d := io.print("then restate it in a fenced block. Prose describing the tests you")
  let __e := io.print("would write is not a test suite, and nothing downstream can run it.")
  1
}

# The hint has to be in the AUTHOR'S language: a .lex author shown a Python
# datetime derivation has nothing to copy (#344).
fn pasted(findings :: List[Finding], any_lex :: Bool) -> [io] Int {
  let __h := io.print("check_derived_values: expected values were PASTED, not derived.\n")
  let __l := list.fold(findings, 0, fn (n :: Int, f :: Finding) -> [io] Int {
    let __a := io.print(str.join(["  ", f.file, ":", int.to_str(f.line), "  ", f.what, " written as a literal: ", f.literal], ""))
    let __b := io.print(str.concat("      ", f.src))
    n + 1
  })
  let __i := io.print("\nA hand-written expected value is an unverifiable oracle: if it is wrong,")
  let __j := io.print("the failure is indistinguishable from a bug in the implementation, and the")
  let __k := io.print("loop will change working code to satisfy it. Two ways to fix this —")
  let __m := io.print("either is accepted:")
  let __n := io.print("")
  let __hint := if any_lex {
    lex_hint()
  } else {
    py_hint()
  }
  let __z := io.print("Both make a wrong paste fail at the ORACLE, naming your expected value,")
  let __y := io.print("instead of the implementation being blamed for your typo.")
  1
}

fn lex_hint() -> [io] Unit {
  let __a := io.print("  1. COMPUTE the expected value where you assert it:")
  let __b := io.print("       if v == 1700000000 + 330 * 60 { Ok(()) } else { Err(\"shift\") }")
  let __c := io.print("")
  let __d := io.print("  2. PIN the literal to a derivation ONCE, then reuse it freely:")
  let __e := io.print("       let expected := 1700000000 + 330 * 60")
  let __f := io.print("       if expected == 1700019800 { ... }   # the pin; reuse `expected` below")
  io.print("")
}

fn py_hint() -> [io] Unit {
  let __a := io.print("  1. COMPUTE the expected value where you assert it:")
  let __b := io.print("       assert body[\"result\"] == datetime(")
  let __c := io.print("           2025, 7, 11, 12, tzinfo=ZoneInfo(\"UTC\")")
  let __d := io.print("       ).astimezone(ZoneInfo(\"America/New_York\")).isoformat()")
  let __e := io.print("")
  let __f := io.print("  2. PIN the literal to a derivation ONCE, then reuse it freely:")
  let __g := io.print("       assert \"2025-07-11T08:00:00-04:00\" == datetime(")
  let __h := io.print("           2025, 7, 11, 12, tzinfo=ZoneInfo(\"UTC\")")
  let __i := io.print("       ).astimezone(ZoneInfo(\"America/New_York\")).isoformat()")
  io.print("")
}

