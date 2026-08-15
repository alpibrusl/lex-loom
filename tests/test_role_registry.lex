# test_role_registry.lex — ORG5 (lex-loom#220): the data-driven roster.
#
#   1. DISPATCHER — roles.for_role now dispatches over builtin_specs data;
#      every role_kinds kind resolves to an AgentDef of that kind (the
#      behavior-identical migration), and the spec list and role_kinds agree
#      exactly.
#   2. PACKS — the closed pack registry partitions the builtin vocabulary;
#      unknown packs are refused; declared packs shape castable_kinds
#      (core + declared), no declaration keeps every builtin castable.
#   3. GRANT ORDER — manifests.grant_within is a real partial order over
#      the preset dims (fs, exec).
#   4. BOUNDED RUNTIME CREATION — every structural refusal (shadowing,
#      duplicate, unknown tool profile, unknown preset, grant above the
#      company ceiling) lands on the trail and writes nothing castable; an
#      approved proposal becomes castable through cast.cast_node itself,
#      as "loom-dyn-<kind>", and the role_defs row ledgers proposer +
#      approver. A rejected proposal never becomes castable.

import "std.list" as list

import "std.str" as str

import "std.io" as io

import "std.crypto" as crypto

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/role_kinds" as role_kinds

import "../src/roles" as roles

import "../src/role_registry" as registry

import "../src/manifests" as manifests

import "../src/cast" as cast

import "../src/company" as company

import "../src/transport" as tr

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn open_db() -> [sql, fs_write, random, crypto] Result[conn.ConnDb, Str] {
  let path := str.join(["/tmp/loom-org5-test-", crypto.random_str_hex(8), ".db"], "")
  match conn.open(path) {
    Err(_) => Err("open test db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

fn mk_ccfg(cid :: Str, policy_isolation :: Str) -> company.CompanyCfg {
  { id: cid, goal: "g", model: "proc:cat", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: policy_isolation }
}

fn contains(xs :: List[Str], x :: Str) -> Bool {
  list.fold(xs, false, fn (found :: Bool, e :: Str) -> Bool {
    found or e == x
  })
}

# ── 1. The dispatcher is behavior-identical over the whole vocabulary ────────
fn test_dispatcher_covers_vocabulary() -> [env] Result[Unit, Str] {
  let kinds := role_kinds.known_kinds()
  let all_dispatch := list.fold(kinds, Ok(()), fn (acc :: Result[Unit, Str], k :: Str) -> [env] Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => match roles.for_role(k, "test-model", "/tmp/ep", "test-sprint") {
        None => Err(str.join(["builtin role '", k, "' no longer dispatches"], "")),
        Some(d) => if d.kind == k and d.model_name == "test-model" {
          Ok(())
        } else {
          Err(str.join(["dispatch for '", k, "' returned kind '", d.kind, "'"], ""))
        },
      },
    }
  })
  match all_dispatch {
    Err(e) => Err(e),
    Ok(_) => match check("unknown roles still miss", match roles.for_role("warp_engineer", "m", "", "") {
      None => true,
      Some(_) => false,
    }) {
      Err(e) => Err(e),
      Ok(_) => {
        let spec_kinds := list.map(roles.builtin_specs(), fn (s :: roles.RoleSpec) -> Str {
          s.kind
        })
        check("builtin_specs and role_kinds agree exactly", spec_kinds == role_kinds.known_kinds())
      },
    },
  }
}

# ── 2. Packs ─────────────────────────────────────────────────────────────────
fn test_pack_partition() -> Result[Unit, Str] {
  let all := list.fold(registry.pack_registry(), [], fn (acc :: List[Str], p :: (Str, List[Str])) -> List[Str] {
    match p {
      (_, rs) => list.concat(acc, rs),
    }
  })
  match check("packs cover every builtin role exactly once", list.len(all) == list.len(role_kinds.known_kinds())) {
    Err(e) => Err(e),
    Ok(_) => list.fold(role_kinds.known_kinds(), Ok(()), fn (acc :: Result[Unit, Str], k :: Str) -> Result[Unit, Str] {
      match acc {
        Err(e) => Err(e),
        Ok(_) => if contains(all, k) {
          Ok(())
        } else {
          Err(str.join(["role '", k, "' is in no pack"], ""))
        },
      }
    }),
  }
}

fn test_validate_packs() -> Result[Unit, Str] {
  match check("known packs validate", match registry.validate_packs("finance, research") {
    Ok(ps) => ps == ["finance", "research"],
    Err(_) => false,
  }) {
    Err(e) => Err(e),
    Ok(_) => match check("empty declaration validates to none", match registry.validate_packs("") {
      Ok(ps) => list.is_empty(ps),
      Err(_) => false,
    }) {
      Err(e) => Err(e),
      Ok(_) => check("unknown pack refused loudly", match registry.validate_packs("finance,warpdrive") {
        Ok(_) => false,
        Err(m) => str.contains(m, "unknown role pack 'warpdrive'"),
      }),
    },
  }
}

fn test_castable_kinds_follow_packs() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("org5-packs-", crypto.random_str_hex(6))
      let __c := company.save_company(db, mk_ccfg(cid, ""))
      let no_packs := registry.castable_kinds(db, cid)
      match check("no declaration: every builtin castable", list.len(no_packs) == list.len(role_kinds.known_kinds())) {
        Err(e) => Err(e),
        Ok(_) => match registry.validate_packs("finance") {
          Err(m) => Err(m),
          Ok(packs) => match registry.save_packs(db, cid, packs) {
            Err(m) => Err(m),
            Ok(_) => {
              let ks := registry.castable_kinds(db, cid)
              match check("finance pack staffs finance roles", contains(ks, "finance") and contains(ks, "monetization_handoff")) {
                Err(e) => Err(e),
                Ok(_) => match check("core is always staffed", contains(ks, "pm") and contains(ks, "build")) {
                  Err(e) => Err(e),
                  Ok(_) => check("undeclared packs are not staffed", not contains(ks, "research") and not contains(ks, "security")),
                },
              }
            },
          },
        },
      }
    },
  }
}

# ── 3. The grant partial order ───────────────────────────────────────────────
fn test_grant_within() -> Result[Unit, Str] {
  match check("equal presets are within", manifests.grant_within("Demo", "Demo")) {
    Err(e) => Err(e),
    Ok(_) => match check("exec exceeds a no-exec ceiling", not manifests.grant_within("QA", "Demo")) {
      Err(e) => Err(e),
      Ok(_) => match check("write exceeds a read-only ceiling", not manifests.grant_within("Implementation", "QA")) {
        Err(e) => Err(e),
        Ok(_) => match check("narrower is within", manifests.grant_within("QA", "Implementation") and manifests.grant_within("Demo", "Implementation")) {
          Err(e) => Err(e),
          Ok(_) => check("nothing exceeds the sprint union", list.fold(manifests.known_presets(), true, fn (ok :: Bool, p :: Str) -> Bool {
            ok and manifests.grant_within(p, "Implementation")
          })),
        },
      },
    },
  }
}

# ── 4. Bounded runtime creation ──────────────────────────────────────────────
fn test_proposal_refusals() -> [io, sql, fs_read, fs_write, time, random, crypto, vcs] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("org5-refuse-", crypto.random_str_hex(6))
      let __c := company.save_company(db, mk_ccfg(cid, "ceiling:Demo"))
      let shadow := registry.propose_role(db, cid, "qa", "prompt", "none", "Demo", "ceo")
      let badtools := registry.propose_role(db, cid, "growth_hacker", "prompt", "shell_wizard", "Demo", "ceo")
      let badpreset := registry.propose_role(db, cid, "growth_hacker", "prompt", "none", "Unbounded", "ceo")
      let overgrant := registry.propose_role(db, cid, "growth_hacker", "prompt", "none", "Implementation", "ceo")
      match check("shadowing a builtin refused", match shadow {
        Err(m) => str.contains(m, "shadows a builtin role"),
        Ok(_) => false,
      }) {
        Err(e) => Err(e),
        Ok(_) => match check("unknown tool profile refused", match badtools {
          Err(m) => str.contains(m, "unknown tool profile"),
          Ok(_) => false,
        }) {
          Err(e) => Err(e),
          Ok(_) => match check("unknown grant preset refused", match badpreset {
            Err(m) => str.contains(m, "unknown grant preset"),
            Ok(_) => false,
          }) {
            Err(e) => Err(e),
            Ok(_) => match check("grant above the company ceiling refused STRUCTURALLY", match overgrant {
              Err(m) => str.contains(m, "exceeds the company ceiling 'Demo'"),
              Ok(_) => false,
            }) {
              Err(e) => Err(e),
              Ok(_) => match check("refusals are on the trail", tr.trail_contains(db, cid, "role_refused", "exceeds the company ceiling")) {
                Err(e) => Err(e),
                Ok(_) => check("nothing became castable", not contains(registry.castable_kinds(db, cid), "growth_hacker")),
              },
            },
          },
        },
      }
    },
  }
}

fn test_propose_approve_cast() -> [env, io, sql, fs_read, fs_write, time, random, crypto, vcs] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("org5-approve-", crypto.random_str_hex(6))
      let __c := company.save_company(db, mk_ccfg(cid, ""))
      match registry.propose_role(db, cid, "growth_hacker", "You are the Growth Hacker. Propose concrete distribution experiments grounded in the product's real usage signals.", "research", "Demo", "ceo") {
        Err(m) => Err(str.concat("valid proposal refused: ", m)),
        Ok(att_id) => match check("proposal parks before the board", match tr.get_attention(db, att_id) {
          Some(item) => item.oracle == "board" and item.verdict == "pending",
          None => false,
        }) {
          Err(e) => Err(e),
          Ok(_) => match check("not castable while pending", match registry.lookup_active(db, cid, "growth_hacker") {
            None => true,
            Some(_) => false,
          }) {
            Err(e) => Err(e),
            Ok(_) => {
              let __r := tr.resolve_attention(db, att_id, "approved", "", "board-jane")
              let __a := registry.apply_resolved(db, cid)
              match registry.lookup_active(db, cid, "growth_hacker") {
                None => Err("approved role not active"),
                Some(d) => match check("ledger names proposer and approver", d.proposed_by == "ceo" and d.approved_by == "board-jane" and d.grant_preset == "Demo") {
                  Err(e) => Err(e),
                  Ok(_) => match check("activation is on the trail", tr.trail_contains(db, cid, "role_activated", "growth_hacker")) {
                    Err(e) => Err(e),
                    Ok(_) => {
                      let node := { id: "gh-1", role: "growth_hacker", gate: "spec non-empty", expand: None, activate_when: "" }
                      let entry := cast.cast_node(db, node, "req", "proc:cat", str.concat(cid, "/iter-x"))
                      match check("approved role casts through the real cast path", entry.agent_config.kind == "growth_hacker" and entry.agent_config.id == "loom-dyn-growth_hacker") {
                        Err(e) => Err(e),
                        Ok(_) => {
                          let rej := registry.propose_role(db, cid, "chaos_officer", "prompt", "none", "Demo", "ceo")
                          match rej {
                            Err(m) => Err(str.concat("second proposal refused: ", m)),
                            Ok(att2) => {
                              let __r2 := tr.resolve_attention(db, att2, "rejected", "not needed", "board-jane")
                              let __a2 := registry.apply_resolved(db, cid)
                              check("rejected role never becomes castable", match registry.lookup_active(db, cid, "chaos_officer") {
                                None => true,
                                Some(_) => false,
                              })
                            },
                          }
                        },
                      }
                    },
                  },
                },
              }
            },
          },
        },
      }
    },
  }
}

fn suite() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] List[Result[Unit, Str]] {
  [test_dispatcher_covers_vocabulary(), test_pack_partition(), test_validate_packs(), test_castable_kinds_follow_packs(), test_grant_within(), test_proposal_refusals(), test_propose_approve_cast()]
}

fn run_all() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
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
    ()
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

