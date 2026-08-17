# support_scope.lex — #194: bind the CX A2A fetch to the company's OWN URL.
#
# cx_a2a.lex's fetch_support_items skill used to accept an arbitrary
# caller-supplied `url` — any host, any port — so a caller holding a valid
# CX_API_TOKEN could direct the server to fetch from any target on the
# network. The fix is NOT a private-IP/loopback blocklist (the legitimate
# use is exactly http://127.0.0.1:<port> in this project's single-host
# deployment model); it is an allowlist of ONE: the calling company's own
# registered product URL.
#
# Where that registry already lives: the company DB. A Launch or Deploy
# node that actually succeeded recorded {"ok":true,"url":...} as its
# artifact, and `company.liveness_target` already derives "the company's
# own live URL" from it for the operate loop's liveness checks — the same
# derivation the runtime trusts is the one the A2A surface now enforces.
# One source of truth, two enforcement points (the same rule lex-os
# applies to grants).
#
# Resolution order (refuse, don't downgrade):
#   1. CX_ALLOWED_URL — an operator-pinned base URL, for deployments where
#      the product URL is static config rather than derived state.
#   2. The company DB's registered Launch/Deploy URL (newest iteration
#      with one wins; deploy is preferred over launch inside
#      liveness_target itself).
#   3. Neither configured → an error, never an unscoped fetch.

import "std.list" as list

import "std.str" as str

import "lex-orm/src/connection" as conn

import "./company" as company

# Base-URL normalization: strip trailing slashes so http://x:8080 and
# http://x:8080/ compare equal. Nothing smarter on purpose — scheme, host,
# and port must match byte-for-byte; "normalize harder" is how allowlist
# bypasses are born.
fn normalize_base(url :: Str) -> Str
  examples {
    normalize_base("http://x:8080/") => "http://x:8080",
    normalize_base("http://x:8080//") => "http://x:8080",
    normalize_base("http://x:8080") => "http://x:8080"
  }
{
  if str.ends_with(url, "/") {
    normalize_base(str.slice(url, 0, str.len(url) - 1))
  } else {
    url
  }
}

# The scope decision. An empty request means "use the registered URL";
# a non-empty request must equal it after normalization. An empty
# allowlist matches nothing — never fail-open.
fn url_in_scope(requested :: Str, allowed :: Str) -> Bool
  examples {
    url_in_scope("", "http://127.0.0.1:8123") => true,
    url_in_scope("http://127.0.0.1:8123/", "http://127.0.0.1:8123") => true,
    url_in_scope("http://internal-service:9000", "http://127.0.0.1:8123") => false,
    url_in_scope("", "") => false
  }
{
  if str.is_empty(allowed) {
    false
  } else {
    str.is_empty(requested) or normalize_base(requested) == normalize_base(allowed)
  }
}

# The newest iteration that registered a live URL wins: a company's URL
# moves as it re-launches/re-deploys, and the scope must follow the same
# state the operate loop trusts, not a stale first hit.
fn registered_url(db :: conn.ConnDb, company_id :: Str) -> [sql] Option[Str] {
  list.fold(list.reverse(company.load_iterations(db, company_id)), None, fn (acc :: Option[Str], it :: company.CompanyIteration) -> [sql] Option[Str] {
    match acc {
      Some(u) => Some(u),
      None => match company.liveness_target(db, it.sprint_id) {
        Some(t) => Some(t.url),
        None => None,
      },
    }
  })
}

# Resolve the ONE allowed base URL, or say precisely why there isn't one.
# Resolved per request, not at server startup: the registered URL changes
# when the company re-deploys, and the scope must track it.
fn resolve_allowed(override :: Str, db_path :: Str, company_id :: Str) -> [sql, fs_read, fs_write, io] Result[Str, Str] {
  if str.is_empty(override) == false {
    Ok(normalize_base(override))
  } else {
    if str.is_empty(db_path) or str.is_empty(company_id) {
      Err("no URL scope configured: set CX_ALLOWED_URL, or LOOM_EVENTS_DB + LOOM_EVENTS_COMPANY so the company's own registered live URL can be derived")
    } else {
      match conn.open(db_path) {
        Err(_) => Err("cannot open the company DB to resolve the URL scope"),
        Ok(db) => match registered_url(db, company_id) {
          Some(u) => Ok(normalize_base(u)),
          None => Err(str.join(["no live URL registered for company ", company_id, ": a Launch or Deploy node must have recorded {ok:true,url:...} before support items can be fetched"], "")),
        },
      }
    }
  }
}

