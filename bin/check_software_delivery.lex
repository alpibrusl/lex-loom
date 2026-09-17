# check_software_delivery.lex — a SoftwareCo delivery against the run-1
# software-delivery criteria.
#
#     check-software-delivery.sh <company.db> <workspace dir> [<skeleton dir>]
#
# Every criterion is mechanical and comes from what LOOM ITSELF RECORDED, not
# from what the supplier says:
#
#   checkable:iteration-passed   an iteration ended with status success
#   checkable:acceptance-passed  that sprint's trail carries acceptance_passed,
#                                i.e. the sealed artifact was re-executed in a
#                                clean dir and its own suite passed
#   checkable:app-present        something was built
#   checkable:tests-present      something was tested
#
# The buyer runs this itself and re-derives the evidence from the trail rather
# than taking the supplier's word -- here the same company, which is the point
# of routing an internal build through the same contract path.
#
# Ported from check_software_delivery.py (lex-loom#512).

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.fs" as fs

import "std.sql" as sql

type SprintRow = { sprint_id :: Str }

type CountRow = { n :: Int }

type Finding = { attr :: Str, why :: Str }

# Content equality rather than a digest. The Python hashed bytes only to
# compare them; comparing the text directly gives the same answer for the
# skeleton files this looks at, and drops a crypto dependency from a checker
# that is not doing cryptography.
fn contents_of(paths :: List[Str]) -> [fs_read, io] List[Str] {
  list.fold(paths, [], fn (acc :: List[Str], p :: Str) -> [fs_read, io] List[Str] {
    match io.read(p) {
      Err(_) => acc,
      Ok(t) => list.concat(acc, [t]),
    }
  })
}

fn glob_of(pattern :: Str) -> [fs_walk] List[Str] {
  match fs.glob(pattern) {
    Err(_) => [],
    Ok(g) => g,
  }
}

fn basename(p :: Str) -> Str {
  match list.head(list.reverse(str.split(p, "/"))) {
    None => p,
    Some(b) => b,
  }
}

fn is_test_name(name :: Str) -> Bool {
  str.starts_with(name, "test_") or str.ends_with(name, "_test.py")
}

fn passing_sprint(db_path :: Str) -> [sql, fs_read, fs_write, fs_walk] Str {
  if not fs.exists(db_path) {
    ""
  } else {
    match sql.open(db_path) {
      Err(_) => "",
      Ok(h) => {
        let rows :: Result[List[SprintRow], { message :: Str, code :: Option[Str], detail :: Option[Str] }] := sql.query(h, "SELECT sprint_id FROM company_iterations WHERE status='success' ORDER BY idx DESC LIMIT 1", [])
        match rows {
          Err(_) => "",
          Ok(rs) => match list.head(rs) {
            None => "",
            Some(r) => r.sprint_id,
          },
        }
      },
    }
  }
}

fn acceptance_count(db_path :: Str, sprint :: Str) -> [sql, fs_read, fs_write, fs_walk] Int {
  if str.is_empty(sprint) or not fs.exists(db_path) {
    0
  } else {
    match sql.open(db_path) {
      Err(_) => 0,
      Ok(h) => {
        let rows :: Result[List[CountRow], { message :: Str, code :: Option[Str], detail :: Option[Str] }] := sql.query(h, "SELECT count(*) AS n FROM traces WHERE run_id=? AND event_kind='acceptance_passed'", [PStr(sprint)])
        match rows {
          Err(_) => 0,
          Ok(rs) => match list.head(rs) {
            None => 0,
            Some(r) => r.n,
          },
        }
      },
    }
  }
}

# Run 1 found live: the build put the product in main.py and left the
# skeleton's app.py untouched, and a criterion pinned to the file NAME settled
# a working, tested, launched API at 50%. The criterion is that something was
# BUILT -- any top-level Python module that is not a test and is not
# byte-identical to the skeleton's copy.
fn built_modules(ws :: Str, skeleton :: Str) -> [fs_read, fs_walk, io] List[Str] {
  let skel := contents_of(glob_of(str.join([skeleton, "/*.py"], "")))
  list.filter(glob_of(str.join([ws, "/*.py"], "")), fn (p :: Str) -> [fs_read, io] Bool {
    if is_test_name(basename(p)) {
      false
    } else {
      match io.read(p) {
        Err(_) => false,
        Ok(t) => not list.fold(skel, false, fn (acc :: Bool, s :: Str) -> Bool {
          if acc {
            true
          } else {
            s == t
          }
        }),
      }
    }
  })
}

fn own_tests(ws :: Str, skeleton :: Str) -> [fs_read, fs_walk, io] List[Str] {
  let skel := contents_of(glob_of(str.join([skeleton, "/tests/test_*.py"], "")))
  list.filter(glob_of(str.join([ws, "/**/test_*.py"], "")), fn (p :: Str) -> [fs_read, io] Bool {
    if str.contains(p, "__pycache__") {
      false
    } else {
      match io.read(p) {
        Err(_) => false,
        Ok(t) => not list.fold(skel, false, fn (acc :: Bool, s :: Str) -> Bool {
          if acc {
            true
          } else {
            s == t
          }
        }),
      }
    }
  })
}

fn main(db_path :: Str, ws :: Str, skeleton_arg :: Str) -> [sql, fs_read, fs_write, fs_walk, io] Int {
  if str.is_empty(db_path) or str.is_empty(ws) {
    let __ := io.print("usage: check-software-delivery.sh <company.db> <workspace dir> [<skeleton dir>]")
    2
  } else {
    let skeleton := if str.is_empty(skeleton_arg) {
      "paths/python-fastapi"
    } else {
      skeleton_arg
    }
    let sprint := passing_sprint(db_path)
    let acc := acceptance_count(db_path, sprint)
    let built := built_modules(ws, skeleton)
    let tests := own_tests(ws, skeleton)
    let checks := [("checkable:iteration-passed", not str.is_empty(sprint), "no iteration of the company ended with status success"), ("checkable:acceptance-passed", acc > 0, str.join(["no acceptance_passed in the trail of the passing sprint (", if str.is_empty(sprint) {
      "none"
    } else {
      sprint
    }, ")"], "")), ("checkable:app-present", not list.is_empty(built), "no top-level Python module beyond the path skeleton's (nothing was built)"), ("checkable:tests-present", not list.is_empty(tests), "no test_*.py beyond the path skeleton's")]
    let met := list.filter(checks, fn (c :: (Str, Bool, Str)) -> Bool {
      match c {
        (_, ok, _) => ok,
      }
    })
    let unmet := list.filter(checks, fn (c :: (Str, Bool, Str)) -> Bool {
      match c {
        (_, ok, _) => not ok,
      }
    })
    let attrs := str.join(list.map(met, fn (c :: (Str, Bool, Str)) -> Str {
      match c {
        (a, _, _) => a,
      }
    }), " ")
    let __v := io.print(str.concat("SOFTWARE_DELIVERY_VERIFIED ", attrs))
    if list.is_empty(unmet) {
      let __o := io.print(str.concat("SOFTWARE_DELIVERY_OK ", attrs))
      0
    } else {
      let __h := io.print("check_software_delivery: the delivery does not meet these checkable criteria:\n")
      let __l := list.fold(unmet, 0, fn (n :: Int, c :: (Str, Bool, Str)) -> [io] Int {
        match c {
          (a, _, why) => {
            let __ := io.print(str.join(["  ", a, ": ", why], ""))
            n + 1
          },
        }
      })
      1
    }
  }
}

