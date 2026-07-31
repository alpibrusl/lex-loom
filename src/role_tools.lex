# role_tools.lex — the single source of truth for which tools each loom role may
# wield (#47 review follow-up).
#
# Before this, the role→tools policy lived in two places: roles.lex listed the
# actual Tool objects per agent-def, and verify.lex hand-copied the names for the
# authority/operations check. They drifted — `launch` carries a `run_server` tool
# but the verifier's copy omitted it, so every HTTP-server sprint got a spurious
# VIOLATION/EXCEEDED verdict. That defeats the whole point of an *independent*
# verifier: a re-derivation you can't trust to track what was actually granted.
#
# Now both sides read this one list:
#   * the runtime derives each agent's tools from it (roles.tools_of_role), and
#   * the verifier re-derives authority against it (verify.allowed_tools),
# so the check can never silently diverge from what was granted.
#
# Roles not listed wield no tools (pm, architect, demo, scribe, docs, devops,
# ux, brand, content_designer, judge, …). The architect's `emit_graph`
# tool is sprint-scoped and injected outside the node loop, so it never appears
# in an op_grant — it is intentionally not a role policy entry.

fn tools_for(role :: Str) -> List[Str] {
  if role == "build" {
    ["lex_guidelines", "lex_check"]
  } else {
    if role == "py_build" {
      ["py_check"]
    } else {
      if role == "qa" {
        ["lex_check", "lex_run"]
      } else {
        if role == "py_qa" {
          ["run_code"]
        } else {
          if role == "launch" {
            ["run_server"]
          } else {
            if role == "deploy" {
              ["deploy_hetzner"]
            } else {
              if role == "security" {
                ["security_scan"]
              } else {
                if role == "content_creator" {
                  ["publish_content"]
                } else {
                  if role == "cx" {
                    ["fetch_support_items"]
                  } else {
                    []
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

