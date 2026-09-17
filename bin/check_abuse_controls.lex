# check_abuse_controls.lex — a public form endpoint actually refuses abuse, by
# abusing it.
#
# A form endpoint is a spam relay and a dumping ground unless it decides
# otherwise, and "we added a honeypot" is a claim until something fills it in.
# This gate STARTS the product, sends it the four submissions that matter, and
# requires the right answer to each:
#
#   checkable:genuine-accepted   a plain, well-formed submission is accepted
#                                (2xx, or a 3xx redirect to the success page)
#   checkable:honeypot-refused   the same submission with the honeypot field
#                                filled is refused (4xx)
#   checkable:oversize-refused   a body over the size cap is refused
#   checkable:rate-limited       a burst draws at least one 429
#
# The first is not decoration: a filter that drops a real lead has failed the
# product however many bots it stopped, so the genuine case is checked FIRST.
#
# WHY curl AND NOT std.http. A 3xx is the product's ANSWER, not an instruction
# to go elsewhere -- a form backend's success is very often a 302 to a thanks
# page, and following it scores the redirect target instead of the submission.
# std.http follows redirects with no way to opt out (lex-lang#901), so the
# status it reports for a 302 is the thanks page's. curl does not follow unless
# asked. When #901 lands this collapses back to http.send.
#
# Starting and reaping the product is bin/check-abuse-controls.sh's job:
# process groups are what a shell is for, and the gate must kill the whole
# group whatever the outcome.
#
# Ported from check_abuse_controls.py (lex-loom#512).

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.fs" as fs

import "std.process" as proc

import "std.int" as int

import "lex-schema/json_value" as jv

type Probe = { start :: Str, endpoint :: Str, port :: Int, health :: Str, honeypot_field :: Str, fields :: List[(Str, Str)], burst :: Int, oversize_bytes :: Int, timeout_s :: Int }

type Finding = { attr :: Str, ok :: Bool, why :: Str }

fn default_fields() -> List[(Str, Str)] {
  [("email", "probe@example.com"), ("message", "hello from the abuse gate")]
}

fn field_str_or(j :: jv.Json, name :: Str, fallback :: Str) -> Str {
  match jv.get_field(j, name) {
    Some(JStr(s)) => s,
    _ => fallback,
  }
}

fn field_int_or(j :: jv.Json, name :: Str, fallback :: Int) -> Int {
  match jv.get_field(j, name) {
    Some(JInt(n)) => n,
    Some(JStr(s)) => match str.to_int(s) {
      None => fallback,
      Some(n) => n,
    },
    _ => fallback,
  }
}

fn fields_of(j :: jv.Json) -> List[(Str, Str)] {
  match jv.get_field(j, "fields") {
    Some(JObj(kvs)) => list.map(kvs, fn (kv :: (Str, jv.Json)) -> (Str, Str) {
      match kv {
        (k, v) => (k, match v {
          JStr(s) => s,
          JInt(n) => int.to_str(n),
          _ => "",
        }),
      }
    }),
    _ => default_fields(),
  }
}

fn parse_probe(raw :: Str) -> Result[Probe, Str] {
  match jv.parse(raw) {
    Err(e) => Err(e.message),
    Ok(j) => {
      let start := field_str_or(j, "start", "")
      let endpoint := field_str_or(j, "endpoint", "")
      if str.is_empty(start) {
        Err("'start'")
      } else {
        if str.is_empty(endpoint) {
          Err("'endpoint'")
        } else {
          Ok({ start: start, endpoint: endpoint, port: field_int_or(j, "port", 8093), health: field_str_or(j, "health", "/healthz"), honeypot_field: field_str_or(j, "honeypot_field", "website"), fields: fields_of(j), burst: field_int_or(j, "burst", 60), oversize_bytes: field_int_or(j, "oversize_bytes", 2000000), timeout_s: field_int_or(j, "timeout_s", 20) })
        }
      }
    },
  }
}

fn urlencode_pairs(kvs :: List[(Str, Str)]) -> Str {
  str.join(list.map(kvs, fn (kv :: (Str, Str)) -> Str {
    match kv {
      (k, v) => str.join([k, "=", form_escape(v)], ""),
    }
  }), "&")
}

fn form_escape(s :: Str) -> Str {
  str.replace(str.replace(str.replace(s, "%", "%25"), "&", "%26"), " ", "+")
}

fn with_field(kvs :: List[(Str, Str)], name :: Str, value :: Str) -> List[(Str, Str)] {
  list.concat(list.filter(kvs, fn (kv :: (Str, Str)) -> Bool {
    match kv {
      (k, _) => k != name,
    }
  }), [(name, value)])
}

# The HTTP status, or 0 when the connection itself was refused or reset --
# which for an oversize body IS a refusal, provided the server is still
# standing afterwards.
# The body goes through a FILE, not a command-line argument: the oversize probe
# is ~1.2 MB and ARG_MAX on macOS is ~256 KB, so passing it inline fails on the
# one submission this gate exists to send.
fn post_status(url :: Str, body :: Str) -> [proc, fs_write, io] Int {
  let path := "/tmp/loom-abuse-body.txt"
  let __w := io.write(path, body)
  match proc.run("curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "10", "-X", "POST", "-H", "Content-Type: application/x-www-form-urlencoded", "--data-binary", str.concat("@", path), url]) {
    Err(_) => 0,
    Ok(r) => match str.to_int(str.trim(r.stdout)) {
      None => 0,
      Some(n) => n,
    },
  }
}

fn get_status(url :: Str) -> [proc] Int {
  match proc.run("curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", url]) {
    Err(_) => 0,
    Ok(r) => match str.to_int(str.trim(r.stdout)) {
      None => 0,
      Some(n) => n,
    },
  }
}

fn wait_healthy(base :: Str, health :: Str, tries :: Int) -> [proc] Bool {
  if tries <= 0 {
    false
  } else {
    let s := get_status(str.concat(base, health))
    if s >= 200 and s < 300 {
      true
    } else {
      let __ := proc.run("sleep", ["0.5"])
      wait_healthy(base, health, tries - 1)
    }
  }
}

# By doubling, not by list.range(0, n). The oversize body is ~1.2 MB, and
# building it as a 1,200,000-element list then joining hung the gate outright
# -- the checker became the thing that could not finish. ~21 concatenations
# instead of 1.2 million allocations.
fn repeat_str(s :: Str, n :: Int) -> Str {
  if n <= 0 {
    ""
  } else {
    grow(s, s, str.len(s), n)
  }
}

fn grow(unit :: Str, acc :: Str, have :: Int, want :: Int) -> Str {
  if have >= want {
    str.slice(acc, 0, want)
  } else {
    grow(unit, str.concat(acc, acc), have * 2, want)
  }
}

fn burst_statuses(url :: Str, body :: Str, n :: Int) -> [proc, fs_write, io] List[Int] {
  list.map(list.range(0, n), fn (i :: Int) -> [proc, fs_write, io] Int {
    post_status(url, body)
  })
}

# Python's list repr, because this line sits next to the one the Python printed
# in the same trail and "[302]" is the shape a reader has seen before.
fn int_list_repr(xs :: List[Int]) -> Str {
  str.join(["[", str.join(list.map(xs, fn (c :: Int) -> Str {
    int.to_str(c)
  }), ", "), "]"], "")
}

fn sorted_unique(xs :: List[Int]) -> List[Int] {
  list.sort_by(list.fold(xs, [], fn (acc :: List[Int], x :: Int) -> List[Int] {
    if list.fold(acc, false, fn (f :: Bool, y :: Int) -> Bool {
      f or x == y
    }) {
      acc
    } else {
      list.concat(acc, [x])
    }
  }), fn (n :: Int) -> Int {
    n
  })
}

# The shim needs `start` and `port` BEFORE it launches anything, and must not
# grow a JSON parser of its own to get them -- a second parser is a second set
# of defaults to drift. This prints them, or the refusal, for the shim to read.
fn preflight(root_arg :: Str) -> [fs_read, fs_walk, io] Int {
  let root := if str.is_empty(root_arg) {
    "."
  } else {
    root_arg
  }
  let probe_path := str.join([root, "/abuse-probe.json"], "")
  if not fs.is_file(probe_path) {
    let __ := io.print("REFUSE\tno abuse-probe.json in the workspace. The build node declares how to start and drive its endpoint there.")
    1
  } else {
    match io.read(probe_path) {
      Err(_) => {
        let __ := io.print("REFUSE\tabuse-probe.json is not usable (cannot be read); need at least start and endpoint")
        1
      },
      Ok(raw) => match parse_probe(raw) {
        Err(e) => {
          let __ := io.print(str.join(["REFUSE\tabuse-probe.json is not usable (", e, "); need at least start and endpoint"], ""))
          1
        },
        Ok(p) => {
          let __ := io.print(str.join(["START\t", p.start], ""))
          let __p := io.print(str.join(["PORT\t", int.to_str(p.port)], ""))
          0
        },
      },
    }
  }
}

fn main(root_arg :: Str) -> [fs_read, fs_write, fs_walk, proc, io] Int {
  let root := if str.is_empty(root_arg) {
    "."
  } else {
    root_arg
  }
  let probe_path := str.join([root, "/abuse-probe.json"], "")
  if not fs.is_file(probe_path) {
    refuse("no abuse-probe.json in the workspace. The build node declares how to start and drive its endpoint there.")
  } else {
    match io.read(probe_path) {
      Err(_) => refuse("abuse-probe.json is not usable (cannot be read); need at least start and endpoint"),
      Ok(raw) => match parse_probe(raw) {
        Err(e) => refuse(str.join(["abuse-probe.json is not usable (", e, "); need at least start and endpoint"], "")),
        Ok(p) => run_probe(p),
      },
    }
  }
}

fn refuse(msg :: Str) -> [io] Int {
  let __a := io.print("ABUSE_CONTROLS_VERIFIED")
  let __b := io.print(str.concat("check_abuse_controls: ", msg))
  1
}

# The product is already running: bin/check-abuse-controls.sh started it in the
# workspace with PORT set, and reaps its process group whatever happens here.
fn run_probe(p :: Probe) -> [proc, fs_write, io] Int {
  let base := str.join(["http://127.0.0.1:", int.to_str(p.port)], "")
  if not wait_healthy(base, p.health, p.timeout_s * 2) {
    refuse(str.join(["the product did not answer ", p.health, " on port ", int.to_str(p.port), " within ", int.to_str(p.timeout_s), "s after `", p.start, "`"], ""))
  } else {
    let url := str.concat(base, p.endpoint)
    let genuine := urlencode_pairs(p.fields)
    let g := post_status(url, genuine)
    let h := post_status(url, urlencode_pairs(with_field(p.fields, p.honeypot_field, "http://spam.example")))
    let big := urlencode_pairs(with_field(p.fields, "message", repeat_str("x", p.oversize_bytes)))
    let o := post_status(url, big)
    let still_up := wait_healthy(base, p.health, 10)
    let codes := burst_statuses(url, genuine, p.burst)
    report([{ attr: "checkable:genuine-accepted", ok: g >= 200 and g < 400, why: str.join(["a plain well-formed submission got ", int.to_str(g), "; a filter that drops a real lead has failed the product"], "") }, { attr: "checkable:honeypot-refused", ok: h >= 400 and h < 500, why: str.join(["a submission with the honeypot field `", p.honeypot_field, "` filled got ", int.to_str(h), ", not a refusal"], "") }, { attr: "checkable:oversize-refused", ok: (o >= 400 and o < 500 or o == 0) and still_up, why: if not still_up {
      str.join(["a ", int.to_str(str.len(big)), "-byte body took the server down (status ", int.to_str(o), ", then ", p.health, " stopped answering)"], "")
    } else {
      str.join(["a ", int.to_str(str.len(big)), "-byte body got ", int.to_str(o), ", not a refusal"], "")
    } }, { attr: "checkable:rate-limited", ok: list.fold(codes, false, fn (acc :: Bool, c :: Int) -> Bool {
      acc or c == 429
    }), why: str.join([int.to_str(list.len(codes)), " rapid submissions drew no 429 (statuses seen: ", int_list_repr(sorted_unique(codes)), ")"], "") }])
  }
}

fn report(checks :: List[Finding]) -> [io] Int {
  let met := list.filter(checks, fn (c :: Finding) -> Bool {
    c.ok
  })
  let unmet := list.filter(checks, fn (c :: Finding) -> Bool {
    not c.ok
  })
  let attrs := str.join(list.map(met, fn (c :: Finding) -> Str {
    c.attr
  }), " ")
  let __v := io.print(str.concat("ABUSE_CONTROLS_VERIFIED ", attrs))
  if list.is_empty(unmet) {
    let __o := io.print(str.concat("ABUSE_CONTROLS_OK ", attrs))
    0
  } else {
    let __h := io.print("check_abuse_controls: the endpoint does not refuse abuse the way it must:\n")
    let __l := list.fold(unmet, 0, fn (n :: Int, c :: Finding) -> [io] Int {
      let __ := io.print(str.join(["  ", c.attr, ": ", c.why], ""))
      n + 1
    })
    1
  }
}

