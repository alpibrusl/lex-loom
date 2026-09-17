# fixture_server.lex — a stand-in for an external service, for the demos.
#
# Three demos each started a python3 http.server to play the part of something
# outside the company: a support-ticket endpoint (sa2), a revenue endpoint
# (sa3), a content-publishing endpoint that counts what it received
# (content-a2a). Each wrote its own BaseHTTPRequestHandler subclass; all three
# answered one path with one JSON body.
#
# Configured by environment rather than argv, because the demos background it
# and a long JSON body on a command line is another quoting problem nobody
# needs:
#
#   FIXTURE_PORT    the port to listen on
#   FIXTURE_PATH    the path to answer; empty means answer every path (sa3)
#   FIXTURE_BODY    the JSON body to return
#   FIXTURE_COUNTER a file holding a hit count; when set, each accepted request
#                   increments it and `post_count` is added to the response
#                   (content-a2a, which proves the content role really posted)
#
# Any other path is a 404, which is what the Python did and what makes the
# "wrong path" leg of those demos meaningful.

import "std.str" as str

import "std.io" as io

import "std.env" as env

import "std.net" as net

import "std.map" as map

import "std.int" as int

fn getenv(name :: Str, fallback :: Str) -> [env] Str {
  match env.get(name) {
    Some(v) => v,
    None => fallback,
  }
}

fn counter_path() -> [env] Str {
  getenv("FIXTURE_COUNTER", "")
}

fn bump() -> [env, fs_read, fs_write, io] Int {
  let path := counter_path()
  if str.is_empty(path) {
    0
  } else {
    let current := match io.read(path) {
      Err(_) => 0,
      Ok(t) => match str.to_int(str.trim(t)) {
        None => 0,
        Some(n) => n,
      },
    }
    let next := current + 1
    let __ := io.write(path, int.to_str(next))
    next
  }
}

# `post_count` is spliced in rather than built with a JSON library, because the
# body is already JSON the caller supplied and re-serialising it would reorder
# its fields -- which the demos compare against verbatim.
fn with_count(body :: Str, n :: Int) -> Str {
  if n <= 0 {
    body
  } else {
    let trimmed := str.trim(body)
    if str.ends_with(trimmed, "}") {
      str.join([str.slice(trimmed, 0, str.len(trimmed) - 1), ",\"post_count\":", int.to_str(n), "}"], "")
    } else {
      trimmed
    }
  }
}

fn handle(req :: Request) -> [env, fs_read, fs_write, io] Response {
  let want := getenv("FIXTURE_PATH", "")
  if str.is_empty(want) or req.path == want {
    let n := bump()
    { status: 200, body: BodyStr(with_count(getenv("FIXTURE_BODY", "{}"), n)), headers: map.set(map.new(), "Content-Type", "application/json") }
  } else {
    { status: 404, body: BodyStr(""), headers: map.new() }
  }
}

fn main() -> [env, net, io, fs_read, fs_write] Unit {
  let p := match str.to_int(getenv("FIXTURE_PORT", "0")) {
    None => 0,
    Some(n) => n,
  }
  if p == 0 {
    io.print("fixture_server: FIXTURE_PORT is required")
  } else {
    net.serve_fn(p, handle)
  }
}

