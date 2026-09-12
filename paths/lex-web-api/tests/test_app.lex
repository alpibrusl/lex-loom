# tests/test_app.lex -- the skeleton's own suite, on lex-web's testing
# surface: build a request, dispatch it against the SAME router production
# serves, assert on the response. No socket, no port. A build agent adds a
# test here for every route it adds; a test author writes them from the spec.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "lex-web/src/router" as router

import "lex-web/src/testing" as t

import "../main" as app

fn test_health_answers_ok() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] Result[Unit, Str] {
  let r := router.dispatch(app.app(), t.get("/health"))
  t.all([t.assert_ok(r), t.assert_body_contains(r, "\"ok\":true")])
}

fn test_submit_requires_email() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] Result[Unit, Str] {
  let req := t.request_with_headers("POST", "/submit", "name=Ada", "", [("content-type", "application/x-www-form-urlencoded")])
  t.assert_status(router.dispatch(app.app(), req), 400)
}

fn test_submit_form_redirects_when_next_given() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] Result[Unit, Str] {
  let req := t.request_with_headers("POST", "/submit", "name=Ada&email=ada%40example.eu", "next=/thanks", [("content-type", "application/x-www-form-urlencoded")])
  let r := router.dispatch(app.app(), req)
  t.all([t.assert_status(r, 302), t.assert_header(r, "location", "/thanks")])
}

fn test_submit_form_answers_json_without_next() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] Result[Unit, Str] {
  let req := t.request_with_headers("POST", "/submit", "name=Ada&email=ada%40example.eu", "", [("content-type", "application/x-www-form-urlencoded")])
  let r := router.dispatch(app.app(), req)
  t.all([t.assert_ok(r), t.assert_body_contains(r, "ada@example.eu")])
}

fn test_oversize_body_is_refused() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] Result[Unit, Str] {
  let big := str.join(list.map(list.range(0, 70000), fn (_i :: Int) -> Str {
    "x"
  }), "")
  let req := t.request_with_headers("POST", "/submit", str.concat("email=a%40b.eu&pad=", big), "", [("content-type", "application/x-www-form-urlencoded")])
  t.assert_status(router.dispatch(app.app(), req), 413)
}

fn suite() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] List[Result[Unit, Str]] {
  [t.label("health", test_health_answers_ok()), t.label("submit requires email", test_submit_requires_email()), t.label("submit redirects", test_submit_form_redirects_when_next_given()), t.label("submit json", test_submit_form_answers_json_without_next()), t.label("oversize refused", test_oversize_body_is_refused())]
}

fn run_all() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] Unit {
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
    io.print(str.concat("ok   ", str.concat(int_str(list.len(results)), " lex-web-api skeleton tests")))
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

fn int_str(n :: Int) -> Str {
  if n == 5 {
    "5"
  } else {
    "?"
  }
}

