# test_loom_trail.lex — trail paths and portable export (src/loom_trail.lex).
#
# Two things are covered here, both of which were previously unguarded:
#
#   1. Sprint ids are not safe filenames. `company.iteration_sprint_id` builds
#      `acme-ab12cd/iter-3`, and SQLite refuses to create a database under a
#      directory that does not exist. Because `run_sprint` swallows that with
#      `Err(_) => None`, every company-run sprint silently had no lex-trail
#      chain. `slug` is what stops that recurring.
#
#   2. `export_jsonl` renders the chain as a standalone artifact an external
#      verifier can bind to. The test asserts the exported bytes really are a
#      valid hash chain — every id recomputing, every parent linking — rather
#      than merely that a file appeared.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.io" as io

import "std.json" as json

import "lex-trail/src/log" as tlog

import "lex-trail/src/event" as ev

import "../src/loom_trail" as ltrail

fn test_slug_flattens_path_separators() -> Result[Unit, Str] {
  if not (ltrail.slug("sprint-1") == "sprint-1") {
    Err("a plain sprint id must not change, or existing databases get renamed")
  } else {
    if ltrail.slug("acme-ab12cd/iter-3") == "acme-ab12cd_iter-3" {
      Ok(())
    } else {
      Err("an iteration sprint id was not flattened")
    }
  }
}

# The regression that matters: no trail path may contain a separator, or the
# database silently fails to open and the chain disappears.
fn test_trail_paths_are_never_nested() -> Result[Unit, Str] {
  let db := ltrail.trail_db_path("acme-ab12cd/iter-3")
  let ex := ltrail.trail_export_path("acme-ab12cd/iter-3")
  if str.contains(db, "/") or str.contains(ex, "/") {
    Err(str.join(["a trail path is still nested: ", db, " / ", ex], ""))
  } else {
    Ok(())
  }
}

fn seed(log :: tlog.Log) -> [sql, time] Result[Unit, Str] {
  match ltrail.sprint_started(log, "t-1", "build a thing", None) {
    Err(e) => Err(e),
    Ok(_) => match ltrail.node_started(log, "t-1", "impl-1", "builder", 1, ltrail.latest_id(log)) {
      Err(e) => Err(e),
      Ok(_) => match ltrail.node_denied(log, "t-1", "impl-1", "spec", "signature mismatch", 1, ltrail.latest_id(log)) {
        Err(e) => Err(e),
        Ok(_) => match ltrail.sprint_complete(log, "t-1", true, true, "demo/1", ltrail.latest_id(log)) {
          Err(e) => Err(e),
          Ok(_) => Ok(()),
        },
      },
    },
  }
}

type Line = { id :: Str, kind :: Str, parent :: Str, payload_json :: Str, ts_ms :: Int }

fn parse_lines(content :: Str) -> Result[List[Line], Str] {
  list.fold(list.filter(str.split(content, "\n"), fn (s :: Str) -> Bool {
    not str.is_empty(str.trim(s))
  }), Ok([]), fn (acc :: Result[List[Line], Str], s :: Str) -> Result[List[Line], Str] {
    match acc {
      Err(e) => Err(e),
      Ok(ls) => {
        let parsed :: Result[Line, Str] := json.parse(s)
        match parsed {
          Err(e) => Err(str.concat("bad exported line: ", e)),
          Ok(l) => Ok(list.concat(ls, [l])),
        }
      },
    }
  })
}

fn line_parent(l :: Line) -> Option[Str] {
  if str.is_empty(l.parent) {
    None
  } else {
    Some(l.parent)
  }
}

# Every exported id must recompute from its own content, using lex-trail's own
# hash — the property an external verifier relies on.
fn ids_recompute(ls :: List[Line]) -> Bool {
  list.fold(ls, true, fn (acc :: Bool, l :: Line) -> Bool {
    acc and l.id == ev.compute_id(l.kind, line_parent(l), l.payload_json, l.ts_ms)
  })
}

fn links_ok(prev :: Str, rest :: List[Line]) -> Bool {
  match list.head(rest) {
    None => true,
    Some(l) => if l.parent == prev {
      links_ok(l.id, list.tail(rest))
    } else {
      false
    },
  }
}

fn chain_linked(ls :: List[Line]) -> Bool {
  match list.head(ls) {
    None => true,
    Some(first) => if str.is_empty(first.parent) {
      links_ok(first.id, list.tail(ls))
    } else {
      false
    },
  }
}

fn test_export_is_a_valid_chain() -> [sql, fs_write, io, time] Result[Unit, Str] {
  match tlog.open_memory() {
    Err(e) => Err(e),
    Ok(log) => match seed(log) {
      Err(e) => Err(e),
      Ok(_) => {
        let path := "/tmp/loom_trail_export_test.jsonl"
        match ltrail.export_jsonl(log, path) {
          Err(e) => Err(str.concat("export failed: ", e)),
          Ok(head) => match io.read(path) {
            Err(e) => Err(e),
            Ok(content) => match parse_lines(content) {
              Err(e) => Err(e),
              Ok(ls) => if not (list.len(ls) == 4) {
                Err(str.concat("expected 4 exported events, got ", int.to_str(list.len(ls))))
              } else {
                if not ids_recompute(ls) {
                  Err("an exported event id does not recompute")
                } else {
                  if not chain_linked(ls) {
                    Err("the exported chain is not linked from a root")
                  } else {
                    match list.head(list.reverse(ls)) {
                      None => Err("no last line"),
                      Some(last) => if last.id == head {
                        Ok(())
                      } else {
                        Err("export returned a head that is not the chain's last id")
                      },
                    }
                  }
                }
              },
            },
          },
        }
      },
    },
  }
}

fn test_export_of_empty_log_has_no_head() -> [sql, fs_write, io] Result[Unit, Str] {
  match tlog.open_memory() {
    Err(e) => Err(e),
    Ok(log) => match ltrail.export_jsonl(log, "/tmp/loom_trail_export_empty.jsonl") {
      Err(e) => Err(e),
      Ok(head) => if str.is_empty(head) {
        Ok(())
      } else {
        Err("an empty trail reported a head")
      },
    },
  }
}

fn run_all() -> [sql, fs_write, io, time] Unit {
  let results := [test_slug_flattens_path_separators(), test_trail_paths_are_never_nested(), test_export_is_a_valid_chain(), test_export_of_empty_log_has_no_head()]
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

