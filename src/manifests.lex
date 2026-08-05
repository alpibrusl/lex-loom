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

import "std.list" as list

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

# ── Named presets (OA1, lex-loom#182) ────────────────────────────────────────
# The 5 phase manifests above, addressable by name — the vocabulary
# [policy.isolation] overrides pick from in company.toml, and what
# cast.lex's grant report renders. Adding a 6th preset means adding both a
# branch here and to manifest_json_for_preset below.
fn preset_name_for_kind(kind :: Str) -> Str {
  if kind == "build" {
    "Implementation"
  } else {
    if kind == "py_build" {
      "Implementation"
    } else {
      if kind == "fe_build" {
        "Implementation"
      } else {
        if kind == "qa" {
          "QA"
        } else {
          if kind == "py_qa" {
            "QA"
          } else {
            if kind == "security" {
              "QA"
            } else {
              if kind == "scribe" {
                "Retro"
              } else {
                "Demo"
              }
            }
          }
        }
      }
    }
  }
}

# The full manifest JSON for a named preset. Unrecognised preset names fall
# back to the Demo preset's ReadOnly/no-exec grant — the same
# never-hand-out-exec-by-omission default manifest_json_for_kind already
# relied on, now also the safe fallback for a mistyped
# [policy.isolation] override.
fn manifest_json_for_preset(preset :: Str, sprint_id :: Str) -> Str {
  if preset == "Design" {
    design_manifest_json(sprint_id)
  } else {
    if preset == "Implementation" {
      implementation_manifest_json(sprint_id)
    } else {
      if preset == "QA" {
        qa_manifest_json(sprint_id)
      } else {
        if preset == "Retro" {
          retro_manifest_json(sprint_id)
        } else {
          demo_manifest_json(sprint_id)
        }
      }
    }
  }
}

# Map an agent's role `kind` to the lex-os phase manifest that governs it
# (docs/design/lex-os-isolation.md's per-role table). Unmapped roles fall
# back to demo_manifest_json's ReadOnly/no-exec grant — the safe default,
# since an unrecognised role must never be handed exec authority by omission.
fn manifest_json_for_kind(kind :: Str, sprint_id :: Str) -> Str {
  manifest_json_for_preset(preset_name_for_kind(kind), sprint_id)
}

# ── [policy.isolation] overrides (OA1, lex-loom#182) ─────────────────────────
# `overrides` is a company's declared [policy.isolation] table, parsed into
# (role_kind, preset_name) pairs by bin/bootstrap-company.sh — e.g.
# [("qa", "Demo")] to run qa tighter than its Sandboxed-exec default, or
# [("devops", "Implementation")] to grant a role manifest_json_for_kind
# would otherwise fall back to Demo for. An override targets an EXISTING
# preset name (validated against preset_name_for_kind's own vocabulary by
# manifest_json_for_preset's safe fallback) — it never invents new raw
# grant fields, so a company can only pick among the same 5 vetted presets
# every role already runs under.
#
# OA1 shipped these as reportable-only (cast.lex's roster_grant_report).
# OA2 (lex-loom#183) wired them into the real execution path: both
# src/agent/runner.lex's lex_os_exec_step (proc_cmd) and its LLM-tool
# filter (src/tool_grant.lex) now call manifest_json_for_kind_with_overrides
# instead of the unconditional manifest_json_for_kind, so a company's
# declared [policy.isolation] override actually changes what a node's
# agent can do, not just what gets reported.
fn lookup_override(overrides :: List[(Str, Str)], kind :: Str) -> Option[Str] {
  list.fold(overrides, None, fn (acc :: Option[Str], pair :: (Str, Str)) -> Option[Str] {
    match acc {
      Some(_) => acc,
      None => match pair {
        (k, preset) => if k == kind {
          Some(preset)
        } else {
          None
        },
      },
    }
  })
}

# The preset a role kind would run under, given a company's declared
# overrides — the override's preset name if one is declared for this kind,
# else the same default preset_name_for_kind already returns.
fn preset_for_kind_with_overrides(kind :: Str, overrides :: List[(Str, Str)]) -> Str {
  match lookup_override(overrides, kind) {
    Some(preset) => preset,
    None => preset_name_for_kind(kind),
  }
}

# The full manifest JSON a role kind would run under, given a company's
# declared overrides. Not called by the real execution path yet — see the
# overrides section header above.
fn manifest_json_for_kind_with_overrides(kind :: Str, sprint_id :: Str, overrides :: List[(Str, Str)]) -> Str {
  manifest_json_for_preset(preset_for_kind_with_overrides(kind, overrides), sprint_id)
}

# Parse a company's raw POLICY_ISOLATION env value ("qa:Demo,devops:Implementation")
# into override pairs. Malformed segments (no ':', an empty kind or preset)
# are dropped rather than erroring — a typo in one override should never
# take down the whole report; matches split_roles' (soft_register.lex)
# equally permissive parsing of a comma-joined company.toml field.
fn parse_isolation_overrides(raw :: Str) -> List[(Str, Str)] {
  if str.is_empty(str.trim(raw)) {
    []
  } else {
    list.fold(str.split(raw, ","), [], fn (acc :: List[(Str, Str)], seg :: Str) -> List[(Str, Str)] {
      let parts := str.split(str.trim(seg), ":")
      if list.len(parts) == 2 {
        let kind := str.trim(part_at(parts, 0))
        let preset := str.trim(part_at(parts, 1))
        if str.is_empty(kind) or str.is_empty(preset) {
          acc
        } else {
          list.concat(acc, [(kind, preset)])
        }
      } else {
        acc
      }
    })
  }
}

fn part_at(xs :: List[Str], i :: Int) -> Str {
  if i <= 0 {
    match list.head(xs) {
      None => "",
      Some(h) => h,
    }
  } else {
    part_at(list.tail(xs), i - 1)
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

