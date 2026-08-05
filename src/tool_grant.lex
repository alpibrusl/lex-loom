# tool_grant.lex — OA2 (lex-loom#183): which loom tools a lex-os Grant
# actually covers.
#
# Every loom tool runs in-process (an HTTP fetch, a shelled `lex`/`python3`
# call, a DB read) — there is no separate sandboxed box per tool call the
# way `agent/runner.lex`'s `lex_os_exec_step` gets for a whole `proc_cmd`
# node. So this is NOT kernel-level mediation: it's a second, pure
# evaluation of the SAME Grant every other consumer reads
# (`manifests.manifest_json_for_kind_with_overrides`) — the same pattern
# lex-os itself already uses (a static grant-vs-effect wall, separate from
# the runtime supervisor's gate, both reading one declaration). See
# docs/design/oa2-tool-call-mediation.md for the full design review.
#
# `tool_required_dimension` is a small, hand-maintained table in the exact
# style of role_tools.lex's role->tool-name policy: explicit and auditable,
# never inferred from a tool's declared effect row (every tool in
# roles.lex declares the same [net, io, proc] regardless of what it
# actually does, since that's lex-llm's fixed Tool.execute signature — not
# a reliable signal of required grant level).

import "std.str" as str

import "lex-schema/json_value" as jv

# The lex-os Grant dimension + minimum level each tool actually needs, based
# on what its implementation does (src/roles.lex's make_*_tool functions).
# A tool with no entry (None) needs nothing — always allowed.
fn tool_required_dimension(name :: Str) -> Option[(Str, Str)] {
  if name == "lex_guidelines" {
    None
  } else {
    if name == "lex_check" {
      Some(("exec", "Sandboxed"))
    } else {
      if name == "lex_run" {
        Some(("exec", "Sandboxed"))
      } else {
        if name == "py_check" {
          Some(("exec", "Sandboxed"))
        } else {
          if name == "run_code" {
            Some(("exec", "Sandboxed"))
          } else {
            if name == "security_scan" {
              Some(("exec", "Sandboxed"))
            } else {
              if name == "run_server" {
                Some(("exec", "Sandboxed"))
              } else {
                if name == "deploy_hetzner" {
                  Some(("exec", "Full"))
                } else {
                  if name == "publish_content" {
                    Some(("network", "Full"))
                  } else {
                    if name == "fetch_support_items" {
                      Some(("network", "Allowlist"))
                    } else {
                      if name == "web_search" {
                        Some(("network", "Allowlist"))
                      } else {
                        None
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

# Level's total order (mirrors lex_types::trust::Level in lex-os): None(0) <
# ReadOnly/Sandboxed/Loopback(1) < ReadWrite/Allowlist(2) < Full(3). An
# unrecognised level ranks 0 (no authority) — never fail-open on a typo.
fn level_rank(level :: Str) -> Int {
  if level == "None" {
    0
  } else {
    if level == "ReadOnly" {
      1
    } else {
      if level == "Sandboxed" {
        1
      } else {
        if level == "Loopback" {
          1
        } else {
          if level == "ReadWrite" {
            2
          } else {
            if level == "Allowlist" {
              2
            } else {
              if level == "Full" {
                3
              } else {
                0
              }
            }
          }
        }
      }
    }
  }
}

# Read one dimension's granted level out of a manifest_json_for_* string
# (the same `{"grant":{"filesystem":...,"network":...,"exec":...}}` shape
# every other manifests.lex consumer reads). Malformed/missing JSON reads
# as "None" — the safe, no-authority default.
fn grant_level_for_dimension(manifest_json :: Str, dimension :: Str) -> Str {
  match jv.parse(manifest_json) {
    Err(_) => "None",
    Ok(root) => match jv.get_field(root, "grant") {
      None => "None",
      Some(grant) => match jv.get_field(grant, dimension) {
        Some(JStr(v)) => v,
        _ => "None",
      },
    },
  }
}

# Is `name` allowed under the given manifest's Grant?
fn tool_allowed_under_manifest(name :: Str, manifest_json :: Str) -> Bool {
  match tool_required_dimension(name) {
    None => true,
    Some(req) => match req {
      (dimension, required_level) => level_rank(grant_level_for_dimension(manifest_json, dimension)) >= level_rank(required_level),
    },
  }
}

