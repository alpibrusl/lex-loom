# Sprint and per-phase trust manifests (lex-os integration).
#
# Each sprint phase maps to a Grant that describes what agents in that
# phase are authorised to do on the three trust dimensions.
#
# Phase grants:
#   Design / Architect  — ReadOnly FS, Allowlist Net, No Exec
#                         (reads existing code, calls the LLM, no writes)
#   Implementation      — ReadWrite FS, Allowlist Net, Sandboxed Exec
#                         (writes generated code, runs lex check / tests)
#   QA                  — ReadOnly FS, Allowlist Net, Sandboxed Exec
#                         (reads artifacts, runs test suite, no writes)
#   Demo / Retro        — ReadOnly FS, Allowlist Net, No Exec
#                         (reads artifacts, produces prose reports)
#   Digest              — ReadOnly FS, Allowlist Net, No Exec
#                         (reads trail, writes tightened specs to DB only)
#
# Sprint-level manifest = least upper bound across all phases.
# Budget: 1 hour wall-clock, 500 commands, $50 max LLM spend, 200 API calls.

import "std.str" as str

import "std.int" as int

fn manifest_json(goal :: Str, filesystem :: Str, network :: Str, exec_level :: Str, floor :: Str, wall :: Int, cmds :: Int, money :: Int, api_calls :: Int) -> Str {
  str.join(["{\"goal\":{\"description\":\"", goal, "\"},", "\"grant\":{\"filesystem\":\"", filesystem, "\",\"network\":\"", network, "\",\"exec\":\"", exec_level, "\"},", "\"budget\":{\"wall_clock_secs\":", int.to_str(wall), ",", "\"max_commands\":", int.to_str(cmds), ",", "\"max_money_cents\":", int.to_str(money), ",", "\"max_api_calls\":", int.to_str(api_calls), "},", "\"isolation_floor\":\"", floor, "\",\"egress\":[]}"], "")
}

fn design_manifest_json(sprint_id :: Str) -> Str {
  manifest_json(str.concat("loom sprint ", str.concat(sprint_id, " — Design phase (Architect)")), "ReadOnly", "Allowlist", "None", "Namespace", 3600, 500, 5000, 200)
}

fn implementation_manifest_json(sprint_id :: Str) -> Str {
  manifest_json(str.concat("loom sprint ", str.concat(sprint_id, " — Implementation phase (Build)")), "ReadWrite", "Allowlist", "Sandboxed", "Gvisor", 3600, 500, 5000, 200)
}

fn qa_manifest_json(sprint_id :: Str) -> Str {
  manifest_json(str.concat("loom sprint ", str.concat(sprint_id, " — QA phase")), "ReadOnly", "Allowlist", "Sandboxed", "Gvisor", 3600, 500, 5000, 200)
}

fn demo_manifest_json(sprint_id :: Str) -> Str {
  manifest_json(str.concat("loom sprint ", str.concat(sprint_id, " — Demo phase")), "ReadOnly", "Allowlist", "None", "Namespace", 3600, 500, 5000, 200)
}

fn retro_manifest_json(sprint_id :: Str) -> Str {
  manifest_json(str.concat("loom sprint ", str.concat(sprint_id, " — Retro + Digest phases")), "ReadOnly", "Allowlist", "None", "Namespace", 3600, 500, 5000, 200)
}

# Sprint-level manifest: union across all phases (ReadWrite FS, Allowlist Net, Sandboxed Exec).
fn sprint_manifest_json(sprint_id :: Str) -> Str {
  manifest_json(str.concat("loom sprint ", sprint_id), "ReadWrite", "Allowlist", "Sandboxed", "Gvisor", 3600, 500, 5000, 200)
}

# Map an agent's role `kind` to the lex-os phase manifest that governs it
# (docs/design/lex-os-isolation.md's per-role table). Unmapped roles fall
# back to demo_manifest_json's ReadOnly/no-exec grant — the safe default,
# since an unrecognised role must never be handed exec authority by omission.
fn manifest_json_for_kind(kind :: Str, sprint_id :: Str) -> Str {
  if kind == "build" {
    implementation_manifest_json(sprint_id)
  } else {
    if kind == "py_build" {
      implementation_manifest_json(sprint_id)
    } else {
      if kind == "fe_build" {
        implementation_manifest_json(sprint_id)
      } else {
        if kind == "qa" {
          qa_manifest_json(sprint_id)
        } else {
          if kind == "py_qa" {
            qa_manifest_json(sprint_id)
          } else {
            if kind == "security" {
              qa_manifest_json(sprint_id)
            } else {
              if kind == "scribe" {
                retro_manifest_json(sprint_id)
              } else {
                demo_manifest_json(sprint_id)
              }
            }
          }
        }
      }
    }
  }
}

# Compact grant summary for trail events — human-readable, not full JSON.
fn grant_summary_for_phase(phase :: Str) -> Str {
  if phase == "Design" {
    "fs=read-only net=allowlist exec=none"
  } else {
    if phase == "Implementation" {
      "fs=read-write net=allowlist exec=sandboxed"
    } else {
      if phase == "QA" {
        "fs=read-only net=allowlist exec=sandboxed"
      } else {
        "fs=read-only net=allowlist exec=none"
      }
    }
  }
}

