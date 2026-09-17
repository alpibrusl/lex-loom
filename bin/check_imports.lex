# check_imports.lex — every module a build produced actually imports.
#
# `spec compiles` runs py_compile, which PARSES. It never resolves an import,
# so a build naming a package nobody installed, or importing a symbol that does
# not exist, compiles cleanly and then fails the moment anything runs it. The
# failure surfaces at the LAUNCH node as {"ok": false} -- several nodes and
# several retries away from the build that caused it.
#
# A live run made the case by itself: iteration 2's PM wrote "the build gate
# must be `python -c 'import app_main'` (do NOT use py_compile)" into the goal
# text. The pipeline asked for this check on its own.
#
# The python3 here is NOT loom's: it is the company's product language, the
# same way py_compile is, and it stays for the same reason paths/python-* stays
# (lex-loom#512). What moved to Lex is which modules to try and how to report.
#
# Each import runs in its own subprocess under an alarm, so a module with a
# side effect at import time cannot hang or poison the gate.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.fs" as fs

import "std.process" as proc

import "std.int" as int

fn timeout_s() -> Int {
  20
}

fn stem_of(path :: Str) -> Str {
  let base := match list.head(list.reverse(str.split(path, "/"))) {
    None => path,
    Some(b) => b,
  }
  match str.strip_suffix(base, ".py") {
    None => base,
    Some(s) => s,
  }
}

# conftest.py is NOT skipped, though it looks like test scaffolding. pytest
# imports it unconditionally before collecting anything, so a broken one kills
# the entire suite and every test is reported as failing. Found live: an agent
# wrote pytest INI config into it --
#
#     [pytest]
#     asyncio_mode = auto
#
# which py_compile ACCEPTS, because `[pytest]` is a valid list literal.
# Importing it raises NameError, pytest dies at collection, and QA blames the
# implementation.
#
# test_*.py stay skipped for a real reason: a test author writes them BEFORE
# the implementation exists, on purpose, so importing one would fail by design.
# They are exercised when QA runs the suite.
fn wanted_module(stem :: Str) -> Bool {
  if str.starts_with(stem, "_") {
    false
  } else {
    if stem == "conftest" {
      true
    } else {
      not str.contains(str.to_lower(stem), "test")
    }
  }
}

fn glob_of(pattern :: Str) -> [fs_walk] List[Str] {
  match fs.glob(pattern) {
    Err(_) => [],
    Ok(g) => g,
  }
}

fn sorted(xs :: List[Str]) -> List[Str] {
  list.sort_by(xs, fn (a :: Str) -> Str {
    a
  })
}

# Packages too (#351). Since py_check can write into a folder (#341) a build
# writes tzconvert/__init__.py + tzconvert/app.py, and tzc15's iteration 1
# sealed one whose __init__ imported a name app.py never defined: this check
# never imported the package, the build was accepted, and QA found the
# ImportError a phase later.
fn package_names(root :: Str) -> [fs_walk] List[Str] {
  sorted(list.filter(list.map(glob_of(str.join([root, "/*/__init__.py"], "")), fn (p :: Str) -> Str {
    dir_name_of(p)
  }), fn (n :: Str) -> Bool {
    if str.starts_with(n, "_") or str.starts_with(n, ".") {
      false
    } else {
      not str.contains(str.to_lower(n), "test")
    }
  }))
}

fn dir_name_of(init_path :: Str) -> Str {
  let parts := str.split(init_path, "/")
  let without_file := list.reverse(list.tail(list.reverse(parts)))
  match list.head(list.reverse(without_file)) {
    None => "",
    Some(d) => d,
  }
}

fn module_names(root :: Str) -> [fs_walk] List[Str] {
  list.filter(sorted(list.map(glob_of(str.join([root, "/*.py"], "")), fn (p :: Str) -> Str {
    stem_of(p)
  })), wanted_module)
}

type Bad = { name :: Str, why :: Str }

# perl's alarm rather than `timeout`, which BSD does not ship -- loom runs on
# macOS and on Linux CI, and a gate that only works on one of them is a gate
# that fails for the wrong reason on the other.
fn import_failure(root :: Str, name :: Str) -> [proc] Option[Bad] {
  let script := str.join(["cd '", root, "' && perl -e 'alarm shift; exec @ARGV' ", int.to_str(timeout_s()), " python3 -c 'import ", name, "' 2>&1; echo \"##RC:$?\""], "")
  match proc.run("bash", ["-c", script]) {
    Err(m) => Some({ name: name, why: str.concat("could not run the import: ", m) }),
    Ok(r) => {
      let out := str.concat(r.stdout, r.stderr)
      let rc := rc_of(out)
      if rc == 0 {
        None
      } else {
        if rc == 142 or rc == 14 {
          Some({ name: name, why: str.join(["import did not finish in ", int.to_str(timeout_s()), "s — something runs at import time"], "") })
        } else {
          Some({ name: name, why: last_nonempty(out) })
        }
      }
    },
  }
}

fn rc_of(out :: Str) -> Int {
  match list.head(list.tail(str.split(out, "##RC:"))) {
    None => 1,
    Some(rest) => match str.to_int(str.trim(match list.head(str.split(rest, "\n")) {
      None => rest,
      Some(l) => l,
    })) {
      None => 1,
      Some(n) => n,
    },
  }
}

fn last_nonempty(out :: Str) -> Str {
  let lines := list.filter(str.split(out, "\n"), fn (l :: Str) -> Bool {
    not str.is_empty(str.trim(l)) and not str.starts_with(str.trim(l), "##RC:")
  })
  match list.head(list.reverse(lines)) {
    None => "import failed",
    Some(l) => str.trim(l),
  }
}

fn main(root_arg :: Str) -> [fs_walk, proc, io] Int {
  let root := if str.is_empty(root_arg) {
    "."
  } else {
    root_arg
  }
  let names := list.concat(module_names(root), package_names(root))
  if list.is_empty(names) {
    let __ := io.print("check_imports: no importable modules found — nothing to check")
    0
  } else {
    let bad := list.fold(names, [], fn (acc :: List[Bad], n :: Str) -> [proc] List[Bad] {
      match import_failure(root, n) {
        None => acc,
        Some(b) => list.concat(acc, [b]),
      }
    })
    if list.is_empty(bad) {
      let __ := io.print(str.join(["check_imports: ", int.to_str(list.len(names)), " module(s) import cleanly"], ""))
      0
    } else {
      let __h := io.print("check_imports: a module the build produced does not import.\n")
      let __l := list.fold(bad, 0, fn (n :: Int, b :: Bad) -> [io] Int {
        let __ := io.print(str.join(["  ", b.name, ": ", b.why], ""))
        n + 1
      })
      let __f := io.print("\nThis compiles but cannot run: py_compile only parses. Fix the import\nitself — use a package that exists (stdlib, flask, fastapi, jinja2,\nmarkdown, pytest), or correct the module/symbol name. If the module is a\nscratch file you no longer need, DELETE it: py_check with delete:true.")
      1
    }
  }
}

