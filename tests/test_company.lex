# test_company.lex — C1 persistence round-trip + C2 condition DSL (#53).

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.sql" as sql

import "std.io" as io

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "std.fs" as fs

import "lex-orm/src/query" as ormq

import "lex-memory/src/memory" as mem

import "../src/migrate" as migrate

import "../src/company" as company

import "../src/transport" as tr

import "../src/company_runner" as company_runner

import "lex-ctl/src/contract" as kct

import "../src/operate_ledger" as oledger

import "../src/effects" as eff

import "../src/agent/registry" as registry

import "../src/sensing" as sensing

import "lex-schema/json_value" as jv

# ── C2: condition DSL (pure) ──────────────────────────────────────────────────
fn ctx(idx :: Int, verdict :: Str, summary :: Str, acc :: Int, bnc :: Int) -> company.IterCtx {
  { idx: idx, last_verdict: verdict, digest_summary: summary, accepted_count: acc, bounced_count: bnc, spend_cents: 0 }
}

fn ctx_with_spend(idx :: Int, verdict :: Str, summary :: Str, acc :: Int, bnc :: Int, spend :: Int) -> company.IterCtx {
  { idx: idx, last_verdict: verdict, digest_summary: summary, accepted_count: acc, bounced_count: bnc, spend_cents: spend }
}

fn expect(label :: Str, got :: Bool, want :: Bool) -> Result[Unit, Str] {
  if got == want {
    Ok(())
  } else {
    Err(str.concat("condition mismatch: ", label))
  }
}

fn test_always_empty_never() -> Result[Unit, Str] {
  let c := ctx(1, "passed", "", 0, 0)
  match expect("always", company.eval_condition("always", c), true) {
    Err(e) => Err(e),
    Ok(_) => match expect("empty=always", company.eval_condition("", c), true) {
      Err(e) => Err(e),
      Ok(_) => expect("never", company.eval_condition("never", c), false),
    },
  }
}

fn test_iter_bounds() -> Result[Unit, Str] {
  let c := ctx(2, "passed", "", 0, 0)
  match expect("iter ge 2", company.eval_condition("iter ge 2", c), true) {
    Err(e) => Err(e),
    Ok(_) => match expect("iter ge 3", company.eval_condition("iter ge 3", c), false) {
      Err(e) => Err(e),
      Ok(_) => match expect("iter lt 3", company.eval_condition("iter lt 3", c), true) {
        Err(e) => Err(e),
        Ok(_) => expect("iter eq 2", company.eval_condition("iter eq 2", c), true),
      },
    },
  }
}

fn test_verdict_and_counts() -> Result[Unit, Str] {
  let c := ctx(1, "failed", "shipped MVP", 4, 1)
  match expect("verdict-failed", company.eval_condition("verdict-failed", c), true) {
    Err(e) => Err(e),
    Ok(_) => match expect("verdict-passed", company.eval_condition("verdict-passed", c), false) {
      Err(e) => Err(e),
      Ok(_) => match expect("digest contains", company.eval_condition("digest contains \"MVP\"", c), true) {
        Err(e) => Err(e),
        Ok(_) => match expect("digest contains miss", company.eval_condition("digest contains \"refund\"", c), false) {
          Err(e) => Err(e),
          Ok(_) => match expect("accepted ge 4", company.eval_condition("accepted ge 4", c), true) {
            Err(e) => Err(e),
            Ok(_) => expect("bounced lt 1", company.eval_condition("bounced lt 1", c), false),
          },
        },
      },
    },
  }
}

fn test_well_formed() -> Result[Unit, Str] {
  match expect("iter ge 2 wf", company.is_well_formed_condition("iter ge 2"), true) {
    Err(e) => Err(e),
    Ok(_) => match expect("bogus", company.is_well_formed_condition("frobnicate now"), false) {
      Err(e) => Err(e),
      Ok(_) => match expect("iter bad op", company.is_well_formed_condition("iter zz 2"), false) {
        Err(e) => Err(e),
        Ok(_) => expect("digest wf", company.is_well_formed_condition("digest contains \"x\""), true),
      },
    },
  }
}

# ── C1: persistence round-trip (db-backed) ────────────────────────────────────
fn company_eq(a :: company.CompanyCfg, b :: company.CompanyCfg) -> Bool {
  if a.id == b.id {
    if a.goal == b.goal {
      if a.model == b.model {
        if a.max_iterations == b.max_iterations {
          if a.stop_when == b.stop_when {
            if a.pmf_when == b.pmf_when {
              if a.maintenance_when == b.maintenance_when {
                if a.wake_when == b.wake_when {
                  if a.soft_mesh_url == b.soft_mesh_url {
                    if a.soft_org_id == b.soft_org_id {
                      if a.soft_roles == b.soft_roles {
                        if a.soft_settlement == b.soft_settlement {
                          a.policy_isolation == b.policy_isolation
                        } else {
                          false
                        }
                      } else {
                        false
                      }
                    } else {
                      false
                    }
                  } else {
                    false
                  }
                } else {
                  false
                }
              } else {
                false
              }
            } else {
              false
            }
          } else {
            false
          }
        } else {
          false
        }
      } else {
        false
      }
    } else {
      false
    }
  } else {
    false
  }
}

fn test_company_roundtrip() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("co-rt")
        let cfg := { id: id, goal: "build the thing", model: "test", max_iterations: 3, stop_when: "iter ge 3", pmf_when: "verdict-passed", maintenance_when: "iter ge 5", wake_when: "verdict-failed", soft_mesh_url: "https://mesh.example.com", soft_org_id: "acme-co", soft_roles: "distribution,cx", soft_settlement: "1", policy_isolation: "qa:Demo,devops:Implementation" }
        match company.save_company(db, cfg) {
          Err(e) => Err(str.concat("save_company: ", e)),
          Ok(_) => match company.load_company(db, id) {
            None => Err("load_company returned None"),
            Some(c2) => if company_eq(c2, cfg) {
              run_iter_roundtrip(db, id)
            } else {
              Err("company round-trip mismatch")
            },
          },
        }
      },
    },
  }
}

# split out to keep nesting shallow
fn run_iter_roundtrip(db :: conn.ConnDb, id :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  match company.record_iteration(db, { company_id: id, idx: 1, sprint_id: str.concat(id, "/iter-1"), parent_sprint_id: "", status: "running", goal: "g1" }) {
    Err(e) => Err(str.concat("record_iteration: ", e)),
    Ok(_) => match company.record_iteration(db, { company_id: id, idx: 2, sprint_id: str.concat(id, "/iter-2"), parent_sprint_id: str.concat(id, "/iter-1"), status: "running", goal: "g2" }) {
      Err(e) => Err(str.concat("record_iteration 2: ", e)),
      Ok(_) => {
        let latest := company.latest_iteration_idx(db, id)
        if latest == 2 {
          let its := company.load_iterations(db, id)
          if list.len(its) == 2 {
            Ok(())
          } else {
            Err(str.concat("expected 2 iterations, got ", int.to_str(list.len(its))))
          }
        } else {
          Err(str.concat("expected latest idx 2, got ", int.to_str(latest)))
        }
      },
    },
  }
}

# SA1 (lex-loom#178): a company.toml with [soft] round-trips through
# save_company/load_company and shows up in board_report — schema +
# persistence only, no mesh behavior.
fn test_board_report_shows_soft_section_when_configured() -> [sql, fs_write, fs_read, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("soft-rt")
        let cfg := { id: id, goal: "Build a widget factory", model: "test", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "https://mesh.example.com", soft_org_id: "widget-co", soft_roles: "distribution,cx", soft_settlement: "", policy_isolation: "" }
        match company.save_company(db, cfg) {
          Err(e) => Err(e),
          Ok(_) => {
            let report := company.board_report(db, id)
            if str.contains(report, "Soft (cross-org mesh):") {
              if str.contains(report, "https://mesh.example.com") {
                if str.contains(report, "widget-co") {
                  if str.contains(report, "distribution,cx") {
                    Ok(())
                  } else {
                    Err(str.concat("report missing soft roles: ", report))
                  }
                } else {
                  Err(str.concat("report missing soft org_id: ", report))
                }
              } else {
                Err(str.concat("report missing soft mesh_url: ", report))
              }
            } else {
              Err(str.concat("report missing Soft section header: ", report))
            }
          },
        }
      },
    },
  }
}

fn test_board_report_soft_section_defaults_not_configured() -> [sql, fs_write, fs_read, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("soft-unset")
        let cfg := { id: id, goal: "Build a widget factory", model: "test", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
        match company.save_company(db, cfg) {
          Err(e) => Err(e),
          Ok(_) => {
            let report := company.board_report(db, id)
            if str.contains(report, "not soft-aware") {
              Ok(())
            } else {
              Err(str.concat("expected the default not-soft-aware line, got: ", report))
            }
          },
        }
      },
    },
  }
}

# The one genuinely new query the Company-view UI needs (#149) — everything
# else the new /api/companies* endpoints use is an existing per-company
# function called once per id from this list.
fn test_list_companies_returns_seeded_ids() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id_a := rand_id("list-a")
        let id_b := rand_id("list-b")
        let cfg := fn (id :: Str) -> company.CompanyCfg {
          { id: id, goal: "g", model: "m", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
        }
        match company.save_company(db, cfg(id_a)) {
          Err(e) => Err(e),
          Ok(_) => match company.save_company(db, cfg(id_b)) {
            Err(e) => Err(e),
            Ok(_) => {
              let ids := company.list_companies(db)
              let has_a := list.fold(ids, false, fn (found :: Bool, x :: Str) -> Bool {
                found or x == id_a
              })
              let has_b := list.fold(ids, false, fn (found :: Bool, x :: Str) -> Bool {
                found or x == id_b
              })
              if has_a and has_b {
                Ok(())
              } else {
                Err(str.join(["expected both seeded ids in list_companies (", int.to_str(list.len(ids)), " ids returned)"], ""))
              }
            },
          },
        }
      },
    },
  }
}

# ── relationships.lex wiring (#151): "who do I contact about X for this
# company" — a company-scoped accountability graph, not a rigid org chart.
# `role` on a relationship is repurposed as the oracle/domain name (the same
# string a `human <oracle>` gate already carries); `to_agent` is either a
# real human registered in the (vendored, generic) agent registry, or a pool
# specialist's own `agent_pool.id` directly -- no registry entry needed for
# the latter, since agent_pool is already the loom-specific source of truth
# for those.
fn seed_pool_agent(db :: conn.ConnDb, id :: Str, role :: Str, tags_json :: Str, attestation :: Int) -> [sql, fs_write] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "INSERT INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, bounce_count, retired_at, created_at) VALUES (?, ?, 'you are a specialist', 'test-model', ?, ?, 0, '', '2026-01-01T00:00:00')", params: [PStr(id), PStr(role), PStr(tags_json), PInt(attestation)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn test_save_company_registers_in_registry() -> [sql, fs_write, fs_read, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("reg-co")
        match company.save_company(db, { id: id, goal: "g", model: "m", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }) {
          Err(e) => Err(e),
          Ok(_) => match registry.find_by_id(db, id) {
            Err(e) => Err(e),
            Ok(None) => Err("company was not registered"),
            Ok(Some(ref)) => if ref.kind == "loom-company" {
              Ok(())
            } else {
              Err(str.concat("expected kind loom-company, got ", ref.kind))
            },
          },
        }
      },
    },
  }
}

fn test_add_contact_and_resolve_returns_human() -> [sql, fs_write, fs_read, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let cid := rand_id("contact-co")
        match company.save_company(db, { id: cid, goal: "g", model: "m", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }) {
          Err(e) => Err(e),
          Ok(_) => match company.add_contact(db, cid, "legal-counsel", "jane-doe", "Jane Doe", "mailto:jane@example.com") {
            Err(e) => Err(e),
            Ok(_) => {
              let contacts := company.resolve_oracle_contacts(db, cid, "legal-counsel")
              match list.head(contacts) {
                None => Err("expected one contact, got none"),
                Some(ct) => if ct.name == "Jane Doe" and ct.contact == "mailto:jane@example.com" {
                  Ok(())
                } else {
                  Err(str.join(["unexpected contact: name=", ct.name, " contact=", ct.contact], ""))
                },
              }
            },
          },
        }
      },
    },
  }
}

fn test_add_pool_agent_contact_and_resolve_returns_pool_agent() -> [sql, fs_write, fs_read, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let cid := rand_id("pool-contact-co")
        match company.save_company(db, { id: cid, goal: "g", model: "m", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }) {
          Err(e) => Err(e),
          Ok(_) => match seed_pool_agent(db, "strict-qa-v1", "py_qa", "[\"lex\",\"qa\"]", 12) {
            Err(e) => Err(e),
            Ok(_) => match company.add_pool_agent_contact(db, cid, "security", "strict-qa-v1") {
              Err(e) => Err(e),
              Ok(_) => {
                let contacts := company.resolve_oracle_contacts(db, cid, "security")
                match list.head(contacts) {
                  None => Err("expected one contact, got none"),
                  Some(ct) => if ct.kind == "pool-agent" and str.contains(ct.note, "attestation=12") {
                    Ok(())
                  } else {
                    Err(str.join(["unexpected contact: kind=", ct.kind, " note=", ct.note], ""))
                  },
                }
              },
            },
          },
        }
      },
    },
  }
}

fn test_resolve_oracle_contacts_empty_when_none_configured() -> [sql, fs_write, fs_read, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let cid := rand_id("no-contact-co")
        match company.save_company(db, { id: cid, goal: "g", model: "m", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }) {
          Err(e) => Err(e),
          Ok(_) => if list.is_empty(company.resolve_oracle_contacts(db, cid, "security")) {
            Ok(())
          } else {
            Err("expected no contacts for an unconfigured oracle")
          },
        }
      },
    },
  }
}

fn test_company_id_of_sprint_extracts_prefix() -> Result[Unit, Str] {
  if company.company_id_of_sprint("acme/iter-3") == "acme" {
    Ok(())
  } else {
    Err(str.concat("expected 'acme', got ", company.company_id_of_sprint("acme/iter-3")))
  }
}

fn test_is_authorized_resolver_true_when_no_contacts_registered() -> [sql, fs_write, fs_read, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let cid := rand_id("open-gate-co")
        match company.save_company(db, { id: cid, goal: "g", model: "m", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }) {
          Err(e) => Err(e),
          Ok(_) => if company.is_authorized_resolver(db, cid, "founder", "anyone-at-all") {
            Ok(())
          } else {
            Err("expected an oracle with no registered contacts to authorize anyone (safe-default-when-unconfigured, same rule OA1's preset fallback uses)")
          },
        }
      },
    },
  }
}

fn test_is_authorized_resolver_true_for_the_registered_contact() -> [sql, fs_write, fs_read, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let cid := rand_id("gated-co")
        match company.save_company(db, { id: cid, goal: "g", model: "m", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }) {
          Err(e) => Err(e),
          Ok(_) => match company.add_contact(db, cid, "founder", "jane-doe", "Jane Doe", "mailto:jane@example.com") {
            Err(e) => Err(e),
            Ok(_) => if company.is_authorized_resolver(db, cid, "founder", "jane-doe") {
              Ok(())
            } else {
              Err("expected the registered contact to be authorized")
            },
          },
        }
      },
    },
  }
}

fn test_is_authorized_resolver_false_for_an_unregistered_id_once_a_contact_exists() -> [sql, fs_write, fs_read, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let cid := rand_id("locked-co")
        match company.save_company(db, { id: cid, goal: "g", model: "m", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }) {
          Err(e) => Err(e),
          Ok(_) => match company.add_contact(db, cid, "founder", "jane-doe", "Jane Doe", "mailto:jane@example.com") {
            Err(e) => Err(e),
            Ok(_) => if company.is_authorized_resolver(db, cid, "founder", "some-random-person") {
              Err("expected an unregistered id to be denied once a real contact is registered for this oracle")
            } else {
              Ok(())
            },
          },
        }
      },
    },
  }
}

fn test_contacts_section_lists_configured_contacts() -> [sql, fs_write, fs_read, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let cid := rand_id("section-co")
        match company.save_company(db, { id: cid, goal: "g", model: "m", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }) {
          Err(e) => Err(e),
          Ok(_) => match company.add_contact(db, cid, "legal-counsel", "jane-doe-2", "Jane Doe", "mailto:jane@example.com") {
            Err(e) => Err(e),
            Ok(_) => {
              let section := company.contacts_section(db, cid)
              if str.contains(section, "legal-counsel") and str.contains(section, "Jane Doe") {
                Ok(())
              } else {
                Err(str.concat("contacts_section missing expected content: ", section))
              }
            },
          },
        }
      },
    },
  }
}

# Structured counterpart to contacts_section -- what the Company Detail UI
# renders as a real "Contacts" section instead of a preformatted text block.
fn test_all_contacts_returns_oracle_and_resolved_contact() -> [sql, fs_write, fs_read, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let cid := rand_id("all-contacts-co")
        match company.save_company(db, { id: cid, goal: "g", model: "m", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }) {
          Err(e) => Err(e),
          Ok(_) => match company.add_contact(db, cid, "legal-counsel", "jane-doe-3", "Jane Doe", "mailto:jane@example.com") {
            Err(e) => Err(e),
            Ok(_) => {
              let rows := company.all_contacts(db, cid)
              match list.head(rows) {
                None => Err("expected one contact row"),
                Some(row) => if row.oracle == "legal-counsel" and row.contact.name == "Jane Doe" and row.contact.contact == "mailto:jane@example.com" {
                  Ok(())
                } else {
                  Err(str.join(["unexpected row: oracle=", row.oracle, " name=", row.contact.name], ""))
                },
              }
            },
          },
        }
      },
    },
  }
}

fn exec(db :: conn.ConnDb, s :: Str) -> [sql, fs_write] Unit {
  let __r := sql.exec(db.handle, s, [])
  ()
}

fn test_persist_memory() -> [sql, fs_read, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let __d := exec(db, "INSERT INTO digests (id, sprint_id, summary_text, lessons, seed_graph_json, created_at) VALUES ('d1', 'acme/iter-1', 'sum', 'Use str.split in hot paths.', '{}', '2026-01-01')")
        let __g1 := exec(db, "INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES ('r', 'acme/iter-1', 'op_grant', '{\"node\":\"build\",\"role\":\"build\",\"agent\":\"build-agent\",\"tools\":\"\"}', 't1')")
        let __g2 := exec(db, "INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES ('r', 'acme/iter-1', 'op_grant', '{\"node\":\"qa\",\"role\":\"qa\",\"agent\":\"qa-agent\",\"tools\":\"\"}', 't2')")
        let n := company.persist_iteration_memory(db, "acme/iter-1")
        if n == 2 {
          let entries := mem.recall_all(db, "build-agent")
          match list.head(entries) {
            None => Err("no memory recalled for build-agent"),
            Some(e) => if str.contains(e.content, "str.split") {
              Ok(())
            } else {
              Err(str.concat("recalled wrong content: ", e.content))
            },
          }
        } else {
          Err(str.concat("expected 2 agents updated, got ", int.to_str(n)))
        }
      },
    },
  }
}

fn test_persist_brand_memory_writes_to_all_reader_agents() -> [sql, fs_read, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let __a1 := exec(db, "INSERT INTO artifacts (hash, sprint_id, node_id, content, created_at) VALUES ('h1-brandtest', 'acme/brand-iter-1', 'brand-designer-tokens', '--color-primary: #1a73e8;', 't1')")
        let __a2 := exec(db, "INSERT INTO artifacts (hash, sprint_id, node_id, content, created_at) VALUES ('h2-brandtest', 'acme/brand-iter-1', 'brand-strategist-voice', 'Positioning: the fast, no-nonsense shortener.', 't2')")
        let n := company.persist_brand_memory(db, "acme/brand-iter-1")
        if n == 3 {
          let entries := mem.recall_all(db, "loom-brand-designer")
          match list.head(entries) {
            None => Err("no brand memory recalled for loom-brand-designer"),
            Some(e) => if str.contains(e.content, "#1a73e8") {
              if str.contains(e.content, "Positioning") {
                Ok(())
              } else {
                Err(str.concat("missing positioning text: ", e.content))
              }
            } else {
              Err(str.concat("missing design tokens: ", e.content))
            },
          }
        } else {
          Err(str.concat("expected 3 brand-reader agents updated, got ", int.to_str(n)))
        }
      },
    },
  }
}

fn test_persist_brand_memory_noop_when_no_brand_artifact() -> [sql, fs_read, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let __a1 := exec(db, "INSERT INTO artifacts (hash, sprint_id, node_id, content, created_at) VALUES ('h1-nobrandtest', 'acme/no-brand-iter-1', 'py-build', 'print(1)', 't1')")
        let n := company.persist_brand_memory(db, "acme/no-brand-iter-1")
        if n == 0 {
          Ok(())
        } else {
          Err(str.concat("expected 0 (no brand node ran), got ", int.to_str(n)))
        }
      },
    },
  }
}

fn test_strategist_continue() -> Result[Unit, Str] {
  let d := company.parse_strategist_decision("{\"decision\":\"continue\",\"goal\":\"\",\"reason\":\"not met yet\"}")
  if d.decision == "continue" {
    Ok(())
  } else {
    Err(str.concat("expected continue, got ", d.decision))
  }
}

fn test_strategist_revise() -> Result[Unit, Str] {
  let d := company.parse_strategist_decision("{\"decision\":\"revise\",\"goal\":\"Narrow to just the parser\",\"reason\":\"too big\"}")
  if d.decision == "revise" {
    if d.goal == "Narrow to just the parser" {
      Ok(())
    } else {
      Err(str.concat("revise goal lost: ", d.goal))
    }
  } else {
    Err(str.concat("expected revise, got ", d.decision))
  }
}

fn test_strategist_revise_no_goal_degrades() -> Result[Unit, Str] {
  let d := company.parse_strategist_decision("{\"decision\":\"revise\",\"goal\":\"\",\"reason\":\"x\"}")
  if d.decision == "continue" {
    Ok(())
  } else {
    Err(str.concat("empty-goal revise should degrade to continue, got ", d.decision))
  }
}

fn test_strategist_stop_and_garbage() -> Result[Unit, Str] {
  let s := company.parse_strategist_decision("{\"decision\":\"stop\",\"goal\":\"\",\"reason\":\"mission achieved\"}")
  if s.decision == "stop" {
    let g := company.parse_strategist_decision("not json at all")
    if g.decision == "stop" {
      Ok(())
    } else {
      Err(str.concat("unparseable reply should STOP (avoid thrash), got ", g.decision))
    }
  } else {
    Err(str.concat("expected stop, got ", s.decision))
  }
}

# Found live (pdfx2 iter-19): the Strategist returned an unparseable reply
# twice in a row and the company stopped with zero retry, unlike every
# other role in this codebase. company_runner.strategist_reply_with_retry
# now retries a bounded number of times before falling back to
# parse_strategist_decision's safe "stop" -- this checks the pure predicate
# it retries against.
fn test_strategist_reply_is_parseable_true_for_valid_json() -> Result[Unit, Str] {
  if company.strategist_reply_is_parseable("{\"decision\":\"continue\",\"goal\":\"\",\"reason\":\"ok\"}") {
    Ok(())
  } else {
    Err("expected valid JSON to be parseable")
  }
}

fn test_strategist_reply_is_parseable_false_for_garbage() -> Result[Unit, Str] {
  if company.strategist_reply_is_parseable("not json at all") {
    Err("expected garbage to be unparseable")
  } else {
    Ok(())
  }
}

fn test_iteration_sprint_id() -> Result[Unit, Str] {
  if company.iteration_sprint_id("acme", 2) == "acme/iter-2" {
    Ok(())
  } else {
    Err("iteration_sprint_id wrong")
  }
}

# NOTE (#242): every open below is a fresh per-run file DB — the old shared
# "sqlite::memory:" store (which persisted across separate process
# invocations) is gone. Db-backed tests still use fresh random ids so rows
# stay disjoint when one test makes several opens.
fn rand_id(prefix :: Str) -> [crypto, random] Str {
  str.join([prefix, "-", crypto.random_str_hex(8)], "")
}

fn stage_cfg(pmf :: Str, maint :: Str) -> company.CompanyCfg {
  stage_cfg_id("acme", pmf, maint)
}

fn stage_cfg_id(id :: Str, pmf :: Str, maint :: Str) -> company.CompanyCfg {
  { id: id, goal: "g", model: "m", max_iterations: 10, stop_when: "", pmf_when: pmf, maintenance_when: maint, wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
}

fn test_stage_advances_on_pmf() -> Result[Unit, Str] {
  let cfg := stage_cfg("verdict-passed", "")
  let passed := ctx(1, "passed", "", 1, 0)
  let failed := ctx(1, "failed", "", 0, 1)
  if company.next_stage(Validation, failed, cfg, false) == Validation {
    if company.next_stage(Validation, passed, cfg, false) == Growth {
      Ok(())
    } else {
      Err("PMF met should advance Validation -> Growth")
    }
  } else {
    Err("PMF unmet should stay in Validation")
  }
}

fn test_stage_empty_condition_never_advances() -> Result[Unit, Str] {
  let cfg := stage_cfg("", "")
  let passed := ctx(1, "passed", "", 1, 0)
  if company.next_stage(Validation, passed, cfg, false) == Validation {
    Ok(())
  } else {
    Err("empty pmf_when should never auto-advance")
  }
}

fn test_stage_growth_to_maintenance() -> Result[Unit, Str] {
  let cfg := stage_cfg("", "iter ge 5")
  let early := ctx(3, "passed", "", 1, 0)
  let mature := ctx(5, "passed", "", 1, 0)
  if company.next_stage(Growth, early, cfg, false) == Growth {
    if company.next_stage(Growth, mature, cfg, false) == Maintenance {
      Ok(())
    } else {
      Err("maintenance_when met should advance Growth -> Maintenance")
    }
  } else {
    Err("maintenance_when unmet should stay in Growth")
  }
}

fn test_stage_sunset_from_any_stage() -> Result[Unit, Str] {
  let cfg := stage_cfg("", "")
  let c := ctx(2, "passed", "", 1, 0)
  if company.next_stage(Validation, c, cfg, true) == Sunset {
    if company.next_stage(Growth, c, cfg, true) == Sunset {
      if company.next_stage(Sunset, c, cfg, false) == Sunset {
        Ok(())
      } else {
        Err("sunset must be terminal")
      }
    } else {
      Err("sunset_now should sunset from Growth")
    }
  } else {
    Err("sunset_now should sunset from Validation")
  }
}

fn test_stage_persistence_roundtrip() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("stage-rt")
        match company.save_company(db, stage_cfg_id(id, "verdict-passed", "")) {
          Err(e) => Err(str.concat("save_company: ", e)),
          Ok(_) => {
            let s0 := company.load_stage(db, id)
            if s0 == Ideation {
              match company.save_stage(db, id, Growth) {
                Err(e) => Err(str.concat("save_stage: ", e)),
                Ok(_) => {
                  let s1 := company.load_stage(db, id)
                  if s1 == Growth {
                    Ok(())
                  } else {
                    Err("stage did not persist as Growth")
                  }
                },
              }
            } else {
              Err(str.concat("new company should start in Ideation, got: ", company.stage_to_str(s0)))
            }
          },
        }
      },
    },
  }
}

fn test_is_dormant() -> Result[Unit, Str] {
  let failed := ctx(3, "failed", "", 0, 1)
  let passed := ctx(3, "passed", "", 1, 0)
  match expect("empty wake_when never dormant", company.is_dormant(Maintenance, "", passed), false) {
    Err(e) => Err(e),
    Ok(_) => match expect("non-Maintenance never dormant", company.is_dormant(Growth, "verdict-failed", passed), false) {
      Err(e) => Err(e),
      Ok(_) => match expect("wake_when unmet -> dormant", company.is_dormant(Maintenance, "verdict-failed", passed), true) {
        Err(e) => Err(e),
        Ok(_) => expect("wake_when met -> not dormant", company.is_dormant(Maintenance, "verdict-failed", failed), false),
      },
    },
  }
}

fn test_resume_point_fresh() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let r := company.resume_point(db, rand_id("nope"))
        if r.start_idx == 1 {
          if str.is_empty(r.parent_sprint) {
            if str.is_empty(r.last_goal) {
              Ok(())
            } else {
              Err("fresh company should have no last_goal")
            }
          } else {
            Err("fresh company should have no parent_sprint")
          }
        } else {
          Err(str.concat("fresh company should resume at 1, got ", int.to_str(r.start_idx)))
        }
      },
    },
  }
}

fn test_resume_point_after_iterations() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("resume-it")
        let sprint1 := str.concat(id, "/iter-1")
        match company.record_iteration(db, { company_id: id, idx: 1, sprint_id: sprint1, parent_sprint_id: "", status: "success", goal: "g1" }) {
          Err(e) => Err(e),
          Ok(_) => match company.finish_iteration(db, id, 1, "success") {
            Err(e) => Err(e),
            Ok(_) => {
              let r := company.resume_point(db, id)
              if r.start_idx == 2 {
                if r.parent_sprint == sprint1 {
                  if r.last_goal == "g1" {
                    Ok(())
                  } else {
                    Err(str.concat("expected last_goal 'g1' (what was actually attempted), got: ", r.last_goal))
                  }
                } else {
                  Err(str.concat("wrong parent_sprint: ", r.parent_sprint))
                }
              } else {
                Err(str.concat("expected resume at 2, got ", int.to_str(r.start_idx)))
              }
            },
          },
        }
      },
    },
  }
}

fn test_save_company_preserves_stage() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("save-pres")
        let cfg := stage_cfg_id(id, "verdict-passed", "")
        match company.save_company(db, cfg) {
          Err(e) => Err(e),
          Ok(_) => match company.save_stage(db, id, Growth) {
            Err(e) => Err(e),
            Ok(_) => match company.save_company(db, cfg) {
              Err(e) => Err(e),
              Ok(_) => {
                let s := company.load_stage(db, id)
                if s == Growth {
                  Ok(())
                } else {
                  Err("re-saving the company must not reset its stage")
                }
              },
            },
          },
        }
      },
    },
  }
}

fn test_strategist_add() -> Result[Unit, Str] {
  let d := company.parse_strategist_decision("{\"decision\":\"add\",\"goal\":\"Add a subtract function\",\"reason\":\"grow the library\"}")
  if d.decision == "add" {
    if d.goal == "Add a subtract function" {
      Ok(())
    } else {
      Err(str.concat("add goal lost: ", d.goal))
    }
  } else {
    Err(str.concat("expected add, got ", d.decision))
  }
}

fn test_strategist_add_no_goal_degrades() -> Result[Unit, Str] {
  let d := company.parse_strategist_decision("{\"decision\":\"add\",\"goal\":\"\",\"reason\":\"x\"}")
  if d.decision == "continue" {
    Ok(())
  } else {
    Err(str.concat("empty-goal add should degrade to continue, got ", d.decision))
  }
}

fn test_backlog_roundtrip() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("backlog")
        match company.next_backlog_item(db, id) {
          Some(_) => Err("fresh company should have no backlog item"),
          None => match company.append_backlog(db, id, "Add subtract") {
            Err(e) => Err(e),
            Ok(_) => match company.append_backlog(db, id, "Add multiply") {
              Err(e) => Err(e),
              Ok(_) => match company.next_backlog_item(db, id) {
                None => Err("expected a pending backlog item"),
                Some(item) => if item.goal == "Add subtract" {
                  match company.mark_backlog_status(db, id, item.idx, "active") {
                    Err(e) => Err(e),
                    Ok(_) => match company.next_backlog_item(db, id) {
                      None => Err("expected multiply to become the next pending item"),
                      Some(item2) => if item2.goal == "Add multiply" {
                        Ok(())
                      } else {
                        Err(str.concat("expected multiply next, got ", item2.goal))
                      },
                    },
                  }
                } else {
                  Err(str.concat("expected subtract first (FIFO), got ", item.goal))
                },
              },
            },
          },
        }
      },
    },
  }
}

fn test_track_company_id() -> Result[Unit, Str] {
  if company.track_company_id("acme", "web") == "acme/web" {
    Ok(())
  } else {
    Err("track_company_id should compose portfolio_id/track_id")
  }
}

fn test_portfolio_roundtrip() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let pid := rand_id("portfolio-rt")
        match company.add_track(db, pid, "web", "Build the web app") {
          Err(e) => Err(e),
          Ok(_) => match company.add_track(db, pid, "cli", "Build the CLI") {
            Err(e) => Err(e),
            Ok(_) => {
              let active := company.active_tracks(db, pid)
              if list.len(active) == 2 {
                match company.mark_track_status(db, pid, "cli", "done") {
                  Err(e) => Err(e),
                  Ok(_) => {
                    let still_active := company.active_tracks(db, pid)
                    if list.len(still_active) == 1 {
                      Ok(())
                    } else {
                      Err(str.concat("expected 1 active track after marking cli done, got ", int.to_str(list.len(still_active))))
                    }
                  },
                }
              } else {
                Err(str.concat("expected 2 active tracks, got ", int.to_str(list.len(active))))
              }
            },
          },
        }
      },
    },
  }
}

fn test_add_track_idempotent() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let pid := rand_id("portfolio-idem")
        match company.add_track(db, pid, "web", "Build the web app") {
          Err(e) => Err(e),
          Ok(_) => match company.mark_track_status(db, pid, "web", "done") {
            Err(e) => Err(e),
            Ok(_) => match company.add_track(db, pid, "web", "a different goal") {
              Err(e) => Err(e),
              Ok(_) => {
                let ts := company.load_tracks(db, pid)
                match list.head(ts) {
                  None => Err("expected the track to still exist"),
                  Some(t) => if t.status == "done" {
                    Ok(())
                  } else {
                    Err("re-seeding an existing track must not reset its status")
                  },
                }
              },
            },
          },
        }
      },
    },
  }
}

# ── #164: run_tracks/run_portfolio wiring ────────────────────────────────────
# Found live (investigating #164): these WERE already wired to a real CLI
# command (main.lex's run_portfolio_cmd) -- the epic issue's premise ("aren't
# wired to anything") was wrong. What was actually missing was ANY test
# coverage at all. run_one_track/run_company dive straight into a full
# company run (real LLM calls) with no seam to mock, so a normal test can't
# exercise the happy path deterministically -- but run_company's OWN Sunset
# short-circuit (a company already sunset with no queued backlog returns
# immediately, zero LLM/network calls) gives a real, free, deterministic way
# to exercise run_portfolio's actual wiring: seed+select+run+status-update,
# exactly the codepath that was previously completely unverified.
fn test_run_portfolio_advances_and_completes_a_sunset_track() -> [env, sql, fs_write, fs_read, time, crypto, random, io, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let pid := rand_id("portfolio-sunset")
        let tid := "t1"
        let cid := company.track_company_id(pid, tid)
        let seed_ccfg := { id: cid, goal: "a sunset goal", model: "test-model", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
        match company.save_company(db, seed_ccfg) {
          Err(e) => Err(e),
          Ok(_) => match company.save_stage(db, cid, Sunset) {
            Err(e) => Err(e),
            Ok(_) => {
              let result := company_runner.run_portfolio(db, pid, "test-model", 10, 1, false, [(tid, "a sunset goal")])
              if result.portfolio_id == pid {
                match list.head(result.tracks) {
                  None => Err("expected exactly one track result"),
                  Some(track_result) => if track_result.track_id == tid {
                    if track_result.result.stopped_by == "sunset" {
                      let ts := company.load_tracks(db, pid)
                      match list.head(ts) {
                        None => Err("expected the track row to exist after running"),
                        Some(t) => if t.status == "done" {
                          Ok(())
                        } else {
                          Err(str.concat("expected the track to be marked done once its company sunset, got status=", t.status))
                        },
                      }
                    } else {
                      Err(str.concat("expected stopped_by=sunset (no LLM call needed for this test), got: ", track_result.result.stopped_by))
                    }
                  } else {
                    Err(str.concat("wrong track_id in result, got: ", track_result.track_id))
                  },
                }
              } else {
                Err(str.concat("wrong portfolio_id echoed back, got: ", result.portfolio_id))
              }
            },
          },
        }
      },
    },
  }
}

fn test_run_portfolio_empty_seed_advances_nothing() -> [env, sql, fs_write, fs_read, time, crypto, random, io, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let pid := rand_id("portfolio-empty")
        let result := company_runner.run_portfolio(db, pid, "test-model", 10, 1, false, [])
        if list.is_empty(result.tracks) {
          Ok(())
        } else {
          Err(str.concat("expected zero tracks for an empty seed with no prior tracks, got ", int.to_str(list.len(result.tracks))))
        }
      },
    },
  }
}

fn test_shipped_summary_empty() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let s := company.shipped_summary(db, rand_id("nothing-shipped"))
        if s == "(nothing shipped yet)" {
          Ok(())
        } else {
          Err(str.concat("expected the empty placeholder, got: ", s))
        }
      },
    },
  }
}

fn test_shipped_summary_lists_successes_only() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("shipped")
        match company.record_iteration(db, { company_id: id, idx: 1, sprint_id: str.concat(id, "/iter-1"), parent_sprint_id: "", status: "success", goal: "Add a Stack module" }) {
          Err(e) => Err(e),
          Ok(_) => match company.record_iteration(db, { company_id: id, idx: 2, sprint_id: str.concat(id, "/iter-2"), parent_sprint_id: str.concat(id, "/iter-1"), status: "failed", goal: "Add a broken module" }) {
            Err(e) => Err(e),
            Ok(_) => {
              let s := company.shipped_summary(db, id)
              if str.contains(s, "Stack module") {
                if str.contains(s, "broken module") {
                  Err("shipped_summary must not list a failed iteration")
                } else {
                  Ok(())
                }
              } else {
                Err(str.concat("expected the shipped Stack module to be listed, got: ", s))
              }
            },
          },
        }
      },
    },
  }
}

fn test_board_notes_roundtrip() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("board")
        let pend0 := company.pending_board_notes(db, id)
        if list.is_empty(pend0) {
          match company.add_board_note(db, id, "focus on the Map module next") {
            Err(e) => Err(e),
            Ok(_) => {
              let pend1 := company.pending_board_notes(db, id)
              if list.len(pend1) == 1 {
                match company.mark_board_notes_consumed(db, id) {
                  Err(e) => Err(e),
                  Ok(_) => {
                    let pend2 := company.pending_board_notes(db, id)
                    if list.is_empty(pend2) {
                      Ok(())
                    } else {
                      Err("note should be consumed after mark_board_notes_consumed")
                    }
                  },
                }
              } else {
                Err(str.concat("expected 1 pending note, got ", int.to_str(list.len(pend1))))
              }
            },
          }
        } else {
          Err("fresh company should have no pending board notes")
        }
      },
    },
  }
}

fn test_board_report_contains_sections() -> [sql, fs_write, fs_read, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("board-rt")
        let cfg := { id: id, goal: "Build a widget factory", model: "test", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
        match company.save_company(db, cfg) {
          Err(e) => Err(e),
          Ok(_) => match company.record_iteration(db, { company_id: id, idx: 1, sprint_id: str.concat(id, "/iter-1"), parent_sprint_id: "", status: "success", goal: "Add the first widget" }) {
            Err(e) => Err(e),
            Ok(_) => match company.append_backlog(db, id, "Add a second widget") {
              Err(e) => Err(e),
              Ok(_) => {
                let report := company.board_report(db, id)
                if str.contains(report, "Build a widget factory") {
                  if str.contains(report, "Add the first widget") {
                    if str.contains(report, "Add a second widget") {
                      Ok(())
                    } else {
                      Err(str.concat("report missing backlog item: ", report))
                    }
                  } else {
                    Err(str.concat("report missing shipped feature: ", report))
                  }
                } else {
                  Err(str.concat("report missing mission: ", report))
                }
              },
            },
          },
        }
      },
    },
  }
}

# ── Operate loop v0 (#84/#85) ─────────────────────────────────────────────
fn insert_test_artifact(db :: conn.ConnDb, sprint_id :: Str, node_id :: Str, content :: Str) -> [sql, time] Result[Unit, Str] {
  let now := time.now_str()
  let hash := str.join([sprint_id, "-", node_id, "-", now], "")
  let q := ormq.for_dialect({ sql: "INSERT OR IGNORE INTO artifacts (hash, sprint_id, node_id, content, created_at) VALUES (?, ?, ?, ?, ?)", params: [PStr(hash), PStr(sprint_id), PStr(node_id), PStr(content), PStr(now)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn insert_test_node_result(db :: conn.ConnDb, sprint_id :: Str, node_id :: Str, accepted :: Int) -> [sql, time, crypto, random] Result[Unit, Str] {
  let now := time.now_str()
  let id := rand_id("nr")
  let q := ormq.for_dialect({ sql: "INSERT INTO node_results (id, sprint_id, node_id, phase, accepted, artifact, reason, created_at) VALUES (?, ?, ?, 'Implementation', ?, '', '', ?)", params: [PStr(id), PStr(sprint_id), PStr(node_id), PInt(accepted), PStr(now)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn insert_test_graph(db :: conn.ConnDb, sprint_id :: Str, graph_json :: Str) -> [sql, time, crypto, random] Result[Unit, Str] {
  let now := time.now_str()
  let id := rand_id("graph")
  let q := ormq.for_dialect({ sql: "INSERT INTO sprint_graphs (id, sprint_id, phase, graph_json, created_at) VALUES (?, ?, 'Design', ?, ?)", params: [PStr(id), PStr(sprint_id), PStr(graph_json), PStr(now)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# Found live (#pdfx company run this session): a real sprint's Architect
# named its build node "py-impl" -- containing neither "build" nor
# "py_build" -- so the OLD substring-matching find_build_artifact silently
# found nothing and skipped syncing a passing sprint's output entirely, with
# no error logged anywhere. find_build_artifact must match by the graph's
# recorded node ROLE (ground truth), not by guessing from the node_id text.
fn test_find_build_artifact_matches_by_role_not_node_name() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let sprint_id := rand_id("op-role-match")
        let graph := "{\"id\":\"g\",\"phase\":\"Design\",\"nodes\":[{\"id\":\"py-impl\",\"role\":\"py_build\",\"gate\":\"spec compiles\"}],\"edges\":[]}"
        match insert_test_graph(db, sprint_id, graph) {
          Err(e) => Err(e),
          Ok(_) => match insert_test_artifact(db, sprint_id, "py-impl", "print('real build output')") {
            Err(e) => Err(e),
            Ok(_) => match company.find_build_artifact(db, sprint_id) {
              None => Err("expected the py-impl node's content to be found via its role, not its name"),
              Some(content) => if content == "print('real build output')" {
                Ok(())
              } else {
                Err(str.concat("wrong content found: ", content))
              },
            },
          },
        }
      },
    },
  }
}

# No sprint_graphs row at all (e.g. a malformed/missing record) must still
# fall back to the old substring heuristic rather than finding nothing.
fn test_find_build_artifact_falls_back_without_a_graph_row() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let sprint_id := rand_id("op-fallback")
        match insert_test_artifact(db, sprint_id, "loom-build", "print('fallback build output')") {
          Err(e) => Err(e),
          Ok(_) => match company.find_build_artifact(db, sprint_id) {
            None => Err("expected the fallback heuristic to find a node_id containing 'build'"),
            Some(content) => if content == "print('fallback build output')" {
              Ok(())
            } else {
              Err(str.concat("wrong content found: ", content))
            },
          },
        }
      },
    },
  }
}

fn test_find_build_artifact_none_when_neither_matches() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let sprint_id := rand_id("op-nomatch")
        match insert_test_artifact(db, sprint_id, "loom-docs", "some docs, not a build artifact") {
          Err(e) => Err(e),
          Ok(_) => match company.find_build_artifact(db, sprint_id) {
            None => Ok(()),
            Some(content) => Err(str.concat("expected no build artifact to be found, got: ", content)),
          },
        }
      },
    },
  }
}

# Found live (pdfx company run this session): every one of 9 iterations
# only ever accepted py_build nodes; no "build" (Lex) role node was ever
# scoped or accepted, yet the Strategist declared the mission complete. This
# is the ground-truth signal that should have stopped that from happening.
fn test_has_shipped_build_node_false_when_only_py_build_accepted() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let company_id := rand_id("op-nolex")
        let sprint_id := str.concat(company_id, "/iter-1")
        match company.record_iteration(db, { company_id: company_id, idx: 1, sprint_id: sprint_id, parent_sprint_id: "", status: "success", goal: "extraction helper" }) {
          Err(e) => Err(e),
          Ok(_) => {
            let graph := "{\"id\":\"g\",\"phase\":\"Design\",\"nodes\":[{\"id\":\"py-impl\",\"role\":\"py_build\",\"gate\":\"spec compiles\"}],\"edges\":[]}"
            match insert_test_graph(db, sprint_id, graph) {
              Err(e) => Err(e),
              Ok(_) => match insert_test_node_result(db, sprint_id, "py-impl", 1) {
                Err(e) => Err(e),
                Ok(_) => if company.has_shipped_build_node(db, company_id) {
                  Err("expected no Lex build node to have shipped -- only a py_build node was ever accepted")
                } else {
                  Ok(())
                },
              },
            }
          },
        }
      },
    },
  }
}

fn test_has_shipped_build_node_true_when_a_build_node_was_accepted() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let company_id := rand_id("op-lex")
        let sprint_id := str.concat(company_id, "/iter-1")
        match company.record_iteration(db, { company_id: company_id, idx: 1, sprint_id: sprint_id, parent_sprint_id: "", status: "success", goal: "priced endpoint" }) {
          Err(e) => Err(e),
          Ok(_) => {
            let graph := "{\"id\":\"g\",\"phase\":\"Design\",\"nodes\":[{\"id\":\"lex-impl\",\"role\":\"build\",\"gate\":\"spec compiles\"}],\"edges\":[]}"
            match insert_test_graph(db, sprint_id, graph) {
              Err(e) => Err(e),
              Ok(_) => match insert_test_node_result(db, sprint_id, "lex-impl", 1) {
                Err(e) => Err(e),
                Ok(_) => if company.has_shipped_build_node(db, company_id) {
                  Ok(())
                } else {
                  Err("expected the accepted 'build' role node to be found")
                },
              },
            }
          },
        }
      },
    },
  }
}

fn test_has_shipped_build_node_false_when_build_node_was_never_accepted() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let company_id := rand_id("op-lex-bounced")
        let sprint_id := str.concat(company_id, "/iter-1")
        match company.record_iteration(db, { company_id: company_id, idx: 1, sprint_id: sprint_id, parent_sprint_id: "", status: "failed", goal: "priced endpoint" }) {
          Err(e) => Err(e),
          Ok(_) => {
            let graph := "{\"id\":\"g\",\"phase\":\"Design\",\"nodes\":[{\"id\":\"lex-impl\",\"role\":\"build\",\"gate\":\"spec compiles\"}],\"edges\":[]}"
            match insert_test_graph(db, sprint_id, graph) {
              Err(e) => Err(e),
              Ok(_) => match insert_test_node_result(db, sprint_id, "lex-impl", 0) {
                Err(e) => Err(e),
                Ok(_) => if company.has_shipped_build_node(db, company_id) {
                  Err("a bounced (not accepted) build node should not count as shipped")
                } else {
                  Ok(())
                },
              },
            }
          },
        }
      },
    },
  }
}

fn test_build_status_section_wording_matches_shipped_state() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let company_id := rand_id("op-status")
        let section := company.build_status_section(db, company_id)
        if str.contains(section, "NO Lex") {
          Ok(())
        } else {
          Err(str.concat("expected the never-shipped wording for a company with no iterations at all: ", section))
        }
      },
    },
  }
}

# Found live (pdfx2 company run): iter-6 shipped a real Lex build node;
# iter-8's Architect then quietly dropped Lex entirely and shipped a
# Flask/Python server instead. has_shipped_build_node (lifetime) stayed
# true and gave the Strategist no signal the CURRENT direction had drifted
# -- its own summary ("the minimal Lex server is shipped") was simply
# wrong. build_status_section must distinguish "drifted away after
# shipping once" from "shipped recently" and from "never shipped at all".
fn test_build_status_section_true_when_most_recent_iteration_shipped_build() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let company_id := rand_id("op-recent-lex")
        let sprint_id := str.concat(company_id, "/iter-1")
        match company.record_iteration(db, { company_id: company_id, idx: 1, sprint_id: sprint_id, parent_sprint_id: "", status: "success", goal: "priced endpoint" }) {
          Err(e) => Err(e),
          Ok(_) => {
            let graph := "{\"id\":\"g\",\"phase\":\"Design\",\"nodes\":[{\"id\":\"lex-impl\",\"role\":\"build\",\"gate\":\"spec compiles\"}],\"edges\":[]}"
            match insert_test_graph(db, sprint_id, graph) {
              Err(e) => Err(e),
              Ok(_) => match insert_test_node_result(db, sprint_id, "lex-impl", 1) {
                Err(e) => Err(e),
                Ok(_) => {
                  let section := company.build_status_section(db, company_id)
                  if str.contains(section, "MOST RECENT iteration -- the current direction is actively using Lex") {
                    Ok(())
                  } else {
                    Err(str.concat("expected the actively-using-Lex wording: ", section))
                  }
                },
              },
            }
          },
        }
      },
    },
  }
}

fn test_build_status_section_flags_drift_when_recent_iteration_dropped_lex() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let company_id := rand_id("op-drift")
        let sprint1 := str.concat(company_id, "/iter-1")
        let sprint2 := str.concat(company_id, "/iter-2")
        match company.record_iteration(db, { company_id: company_id, idx: 1, sprint_id: sprint1, parent_sprint_id: "", status: "success", goal: "priced endpoint" }) {
          Err(e) => Err(e),
          Ok(_) => match company.record_iteration(db, { company_id: company_id, idx: 2, sprint_id: sprint2, parent_sprint_id: sprint1, status: "success", goal: "health route" }) {
            Err(e) => Err(e),
            Ok(_) => {
              let lex_graph := "{\"id\":\"g1\",\"phase\":\"Design\",\"nodes\":[{\"id\":\"lex-impl\",\"role\":\"build\",\"gate\":\"spec compiles\"}],\"edges\":[]}"
              let py_only_graph := "{\"id\":\"g2\",\"phase\":\"Design\",\"nodes\":[{\"id\":\"py-impl\",\"role\":\"py_build\",\"gate\":\"spec compiles\"}],\"edges\":[]}"
              match insert_test_graph(db, sprint1, lex_graph) {
                Err(e) => Err(e),
                Ok(_) => match insert_test_node_result(db, sprint1, "lex-impl", 1) {
                  Err(e) => Err(e),
                  Ok(_) => match insert_test_graph(db, sprint2, py_only_graph) {
                    Err(e) => Err(e),
                    Ok(_) => match insert_test_node_result(db, sprint2, "py-impl", 1) {
                      Err(e) => Err(e),
                      Ok(_) => {
                        let section := company.build_status_section(db, company_id)
                        if str.contains(section, "drifted away from Lex") {
                          Ok(())
                        } else {
                          Err(str.concat("expected the drift wording (shipped earlier, not in the most recent iteration): ", section))
                        }
                      },
                    },
                  },
                },
              }
            },
          },
        }
      },
    },
  }
}

fn test_find_launch_url_from_artifact() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let sprint_id := rand_id("op-launch")
        match insert_test_artifact(db, sprint_id, "loom-launch", "{\"ok\":true,\"url\":\"http://localhost:9999\",\"response\":\"hi\"}") {
          Err(e) => Err(e),
          Ok(_) => match company.find_launch_url(db, sprint_id) {
            None => Err("expected a launch url, got None"),
            Some(url) => if url == "http://localhost:9999" {
              Ok(())
            } else {
              Err(str.concat("wrong url extracted: ", url))
            },
          },
        }
      },
    },
  }
}

fn test_find_launch_url_none_for_cli() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let sprint_id := rand_id("op-cli")
        match insert_test_artifact(db, sprint_id, "loom-py-build", "print('hello')") {
          Err(e) => Err(e),
          Ok(_) => match company.find_launch_url(db, sprint_id) {
            None => Ok(()),
            Some(url) => Err(str.concat("expected no launch url for a CLI-only sprint, got ", url)),
          },
        }
      },
    },
  }
}

fn test_find_deploy_url_from_artifact() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let sprint_id := rand_id("op-deploy")
        match insert_test_artifact(db, sprint_id, "loom-deploy", "{\"ok\":true,\"url\":\"http://1.2.3.4:8080\",\"response\":\"hi\"}") {
          Err(e) => Err(e),
          Ok(_) => match company.find_deploy_url(db, sprint_id) {
            None => Err("expected a deploy url, got None"),
            Some(url) => if url == "http://1.2.3.4:8080" {
              Ok(())
            } else {
              Err(str.concat("wrong url extracted: ", url))
            },
          },
        }
      },
    },
  }
}

# The Strategist should see the real production URL, not a stale localhost
# demo, once a company has actually deployed (#101/#102).
fn test_liveness_target_prefers_deploy_over_launch() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let sprint_id := rand_id("op-both")
        match insert_test_artifact(db, sprint_id, "loom-launch", "{\"ok\":true,\"url\":\"http://localhost:9999\",\"response\":\"hi\"}") {
          Err(e) => Err(e),
          Ok(_) => match insert_test_artifact(db, sprint_id, "loom-deploy", "{\"ok\":true,\"url\":\"http://1.2.3.4:8080\",\"response\":\"hi\"}") {
            Err(e) => Err(e),
            Ok(_) => match company.liveness_target(db, sprint_id) {
              None => Err("expected a liveness target"),
              Some(t) => if t.url == "http://1.2.3.4:8080" {
                if t.source == "production" {
                  Ok(())
                } else {
                  Err(str.concat("expected source=production, got ", t.source))
                }
              } else {
                Err(str.concat("expected the deploy url to win, got ", t.url))
              },
            },
          },
        }
      },
    },
  }
}

fn test_liveness_target_falls_back_to_launch() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let sprint_id := rand_id("op-launch-only")
        match insert_test_artifact(db, sprint_id, "loom-launch", "{\"ok\":true,\"url\":\"http://localhost:9999\",\"response\":\"hi\"}") {
          Err(e) => Err(e),
          Ok(_) => match company.liveness_target(db, sprint_id) {
            None => Err("expected a liveness target"),
            Some(t) => if t.url == "http://localhost:9999" {
              if t.source == "local demo" {
                Ok(())
              } else {
                Err(str.concat("expected source='local demo', got ", t.source))
              }
            } else {
              Err(str.concat("expected the launch url as fallback, got ", t.url))
            },
          },
        }
      },
    },
  }
}

fn test_liveness_target_none_for_cli() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let sprint_id := rand_id("op-none")
        match insert_test_artifact(db, sprint_id, "loom-py-build", "print('hello')") {
          Err(e) => Err(e),
          Ok(_) => match company.liveness_target(db, sprint_id) {
            None => Ok(()),
            Some(t) => Err(str.concat("expected no liveness target for a CLI-only sprint, got ", t.url)),
          },
        }
      },
    },
  }
}

fn test_operate_signal_roundtrip() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-signal")
        let empty := company.recent_operate_signals(db, id, "liveness", 5)
        if list.is_empty(empty) {
          match company.record_operate_signal(db, id, 1, "liveness", "up") {
            Err(e) => Err(e),
            Ok(_) => {
              let after := company.recent_operate_signals(db, id, "liveness", 5)
              if list.len(after) == 1 {
                let first := match list.head(after) {
                  Some(s) => s,
                  None => "",
                }
                if str.contains(first, "up") {
                  Ok(())
                } else {
                  Err("recorded signal missing its value")
                }
              } else {
                Err(str.concat("expected 1 signal, got ", int.to_str(list.len(after))))
              }
            },
          }
        } else {
          Err("fresh company should have no operate signals")
        }
      },
    },
  }
}

# check_remote_errors must never attempt an ssh call for a target that isn't
# actually a production Hetzner deploy -- no host configured, or no
# container name resolved, both mean "nothing to check", not "clean" by luck
# of a failed ssh call succeeding to produce empty output.
fn test_check_remote_errors_no_host_is_clean() -> [proc] Result[Unit, Str] {
  if company.check_remote_errors("", "root", "~/.ssh/id_rsa", "myapp") == "clean" {
    Ok(())
  } else {
    Err("expected 'clean' when no HETZNER_HOST is configured")
  }
}

fn test_check_remote_errors_no_service_name_is_clean() -> [proc] Result[Unit, Str] {
  if company.check_remote_errors("1.2.3.4", "root", "~/.ssh/id_rsa", "") == "clean" {
    Ok(())
  } else {
    Err("expected 'clean' when no service_name is resolved")
  }
}

fn test_find_deploy_service_name_from_artifact() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let sprint_id := rand_id("op-svc-name")
        match insert_test_artifact(db, sprint_id, "loom-deploy", "{\"ok\":true,\"url\":\"http://1.2.3.4:8080\",\"service_name\":\"widget-factory\"}") {
          Err(e) => Err(e),
          Ok(_) => match company.find_deploy_service_name(db, sprint_id) {
            None => Err("expected a service_name, got None"),
            Some(name) => if name == "widget-factory" {
              Ok(())
            } else {
              Err(str.concat("wrong service_name extracted: ", name))
            },
          },
        }
      },
    },
  }
}

fn test_find_deploy_service_name_none_when_absent() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let sprint_id := rand_id("op-svc-none")
        match insert_test_artifact(db, sprint_id, "loom-deploy", "{\"ok\":true,\"url\":\"http://1.2.3.4:8080\"}") {
          Err(e) => Err(e),
          Ok(_) => match company.find_deploy_service_name(db, sprint_id) {
            None => Ok(()),
            Some(name) => Err(str.concat("expected no service_name in an artifact without one, got ", name)),
          },
        }
      },
    },
  }
}

# The Strategist should see a real error-log excerpt when one was recorded,
# on top of the liveness line -- distinguishing "up but throwing" from
# "up and clean" is the whole point of this signal (#102 bug-fixing follow-up).
fn test_operate_section_includes_errors_when_present() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-err-section")
        match company.record_operate_signal(db, id, 1, "liveness", "up (production: http://1.2.3.4:8080)") {
          Err(e) => Err(e),
          Ok(_) => match company.record_operate_signal(db, id, 1, "errors", "Traceback: NullPointerException at line 42") {
            Err(e) => Err(e),
            Ok(_) => {
              let section := company.operate_section(db, id)
              if str.contains(section, "NullPointerException") {
                Ok(())
              } else {
                Err(str.concat("expected the error excerpt in operate_section, got: ", section))
              }
            },
          },
        }
      },
    },
  }
}

fn test_operate_section_omits_errors_section_when_none_recorded() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-err-section-none")
        match company.record_operate_signal(db, id, 1, "liveness", "up (production: http://1.2.3.4:8080)") {
          Err(e) => Err(e),
          Ok(_) => {
            let section := company.operate_section(db, id)
            if str.contains(section, "error log scans") {
              Err(str.concat("expected no error-log section when nothing was recorded, got: ", section))
            } else {
              Ok(())
            }
          },
        }
      },
    },
  }
}

fn test_board_report_shows_operate_section() -> [sql, fs_write, fs_read, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-report")
        let cfg := { id: id, goal: "Build a live API", model: "test", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
        match company.save_company(db, cfg) {
          Err(e) => Err(e),
          Ok(_) => match company.record_operate_signal(db, id, 1, "liveness", "down") {
            Err(e) => Err(e),
            Ok(_) => {
              let report := company.board_report(db, id)
              if str.contains(report, "down") {
                Ok(())
              } else {
                Err(str.concat("report missing operate signal: ", report))
              }
            },
          },
        }
      },
    },
  }
}

# #139: board_report now runs every pending contract through the SAME
# actuation.decide gate CTL6 uses and renders a dossier for any at
# Escalate. No class in the current vocabulary structurally reaches
# Escalate (application_error/rollback_release is Compensatable/
# Service, capped at Propose — see test_actuation.lex's own note), so
# this proves the FILTER: a genuinely Propose-tier pending contract
# must NOT leak into the "Escalations needing review" section, always
# showing "(none)" rather than every pending contract.
fn test_board_report_omits_non_escalate_pending_contracts() -> [sql, fs_write, fs_read, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("dossier-report")
        let cfg := { id: id, goal: "Build a live API", model: "test", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
        match company.save_company(db, cfg) {
          Err(e) => Err(e),
          Ok(_) => match oledger.open_incident(db, id, "errors", "2026-01-01T00:00:01", "[\"errors\"]", 1000) {
            Err(e) => Err(e),
            Ok(inc) => match oledger.set_diagnosed_cause(db, inc, "application_error", 90) {
              Err(e) => Err(e),
              Ok(_) => match eff.propose_contract(db, None, inc, 1, "2026-01-01T00:00:02") {
                Err(e) => Err(e),
                Ok(_) => {
                  let report := company.board_report(db, id)
                  if str.contains(report, "Escalations needing review:\n(none)") {
                    Ok(())
                  } else {
                    Err(str.concat("expected a Propose-tier contract to be omitted from escalations, got: ", report))
                  }
                },
              },
            },
          },
        }
      },
    },
  }
}

# ── OP2 (#86): Strategist actually sees Operate signals ─────────────────────
fn test_strategist_prompt_includes_operate_signals() -> Result[Unit, Str] {
  let iter_ctx := { idx: 2, last_verdict: "passed", digest_summary: "shipped the widget", accepted_count: 3, bounced_count: 0, spend_cents: 0 }
  let prompt := company_runner.strategist_prompt("Build a widget factory", "widget v1", [], "2026-07-06T12:00:00Z: down", "(no product usage signal recorded yet)", "(no revenue source configured)", "(no content published yet)", "NO Lex ('build' role) node has EVER been accepted for this company, across every iteration so far.", "", "Add widget v2", iter_ctx)
  if str.contains(prompt, "OPERATE SIGNALS") {
    if str.contains(prompt, "down") {
      Ok(())
    } else {
      Err(str.concat("prompt missing the actual signal value: ", prompt))
    }
  } else {
    Err(str.concat("prompt missing OPERATE SIGNALS section: ", prompt))
  }
}

fn test_strategist_prompt_no_signals_yet() -> Result[Unit, Str] {
  let iter_ctx := { idx: 1, last_verdict: "passed", digest_summary: "first ship", accepted_count: 1, bounced_count: 0, spend_cents: 0 }
  let prompt := company_runner.strategist_prompt("Build a widget factory", "(empty)", [], "(no launched server for this company, or no liveness checks yet)", "(no product usage signal recorded yet)", "(no revenue source configured)", "(no content published yet)", "NO Lex ('build' role) node has EVER been accepted for this company, across every iteration so far.", "", "Ship v1", iter_ctx)
  if str.contains(prompt, "no launched server") {
    Ok(())
  } else {
    Err(str.concat("prompt should gracefully state no signals exist yet: ", prompt))
  }
}

# #159: the Strategist's whole product (in a company like pulsecheck) can be
# a feedback tool, yet it never read the feedback its own product collected
# back into its continue/revise/add/stop decision. This is the acceptance
# criterion: a real product_signals string reaches the prompt under its own
# labelled section.
fn test_strategist_prompt_includes_product_signals() -> Result[Unit, Str] {
  let iter_ctx := { idx: 3, last_verdict: "passed", digest_summary: "shipped feedback endpoint", accepted_count: 4, bounced_count: 0, spend_cents: 0 }
  let prompt := company_runner.strategist_prompt("Build a feedback tool", "feedback v1", [], "2026-07-06T12:00:00Z: up", "{\"summary\": \"3 projects, 40 feedback rows, avg score 6.2\"}", "(no revenue source configured)", "(no content published yet)", "NO Lex ('build' role) node has EVER been accepted for this company, across every iteration so far.", "", "Add sentiment trend", iter_ctx)
  if str.contains(prompt, "PRODUCT SIGNALS") {
    if str.contains(prompt, "40 feedback rows") {
      Ok(())
    } else {
      Err(str.concat("prompt missing the actual product signal value: ", prompt))
    }
  } else {
    Err(str.concat("prompt missing PRODUCT SIGNALS section: ", prompt))
  }
}

fn test_product_signals_section_no_signal_yet() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("product-signals-none")
        let section := company.product_signals_section(db, id)
        if str.contains(section, "no product usage signal recorded yet") {
          Ok(())
        } else {
          Err(str.concat("expected the no-data case to be stated gracefully, got: ", section))
        }
      },
    },
  }
}

fn test_product_signals_section_reads_latest_recorded_signal() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("product-signals-latest")
        match company.record_operate_signal(db, id, 1, "product_usage", "{\"summary\": \"12 projects\"}") {
          Err(e) => Err(e),
          Ok(_) => {
            let section := company.product_signals_section(db, id)
            if str.contains(section, "12 projects") {
              Ok(())
            } else {
              Err(str.concat("expected the recorded product signal to be surfaced, got: ", section))
            }
          },
        }
      },
    },
  }
}

fn test_fetch_product_usage_reports_unreachable_cleanly() -> [proc] Result[Unit, Str] {
  let out := company.fetch_product_usage("http://127.0.0.1:1")
  if str.contains(out, "unreachable") {
    Ok(())
  } else {
    Err(str.concat("expected a clean unreachable message for a refused connection, got: ", out))
  }
}

# ── #160: real economics — revenue read from a human-configured, read-only
# source, compared against LLM spend. loom never touches payments itself.
fn test_strategist_prompt_includes_real_economics() -> Result[Unit, Str] {
  let iter_ctx := { idx: 4, last_verdict: "passed", digest_summary: "shipped pricing page", accepted_count: 5, bounced_count: 0, spend_cents: 0 }
  let prompt := company_runner.strategist_prompt("Build a feedback tool", "feedback v1", [], "2026-07-06T12:00:00Z: up", "(no product usage signal recorded yet)", "Revenue so far: $34.00. Estimated LLM spend so far: $12.50 (rough proxy — not real billing data).", "(no content published yet)", "NO Lex ('build' role) node has EVER been accepted for this company, across every iteration so far.", "", "Add annual plan", iter_ctx)
  if str.contains(prompt, "REAL ECONOMICS") {
    if str.contains(prompt, "$34.00") {
      Ok(())
    } else {
      Err(str.concat("prompt missing the actual revenue value: ", prompt))
    }
  } else {
    Err(str.concat("prompt missing REAL ECONOMICS section: ", prompt))
  }
}

fn test_real_economics_section_no_revenue_configured() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("economics-none")
        let section := company.real_economics_section(db, id)
        if str.contains(section, "no revenue source configured") {
          Ok(())
        } else {
          Err(str.concat("expected the unconfigured case to be stated gracefully, got: ", section))
        }
      },
    },
  }
}

fn test_real_economics_section_reads_latest_recorded_signal() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("economics-latest")
        match company.record_operate_signal(db, id, 1, "revenue_cents", "{\"revenue_cents\": 3400}") {
          Err(e) => Err(e),
          Ok(_) => {
            let section := company.real_economics_section(db, id)
            if str.contains(section, "$34.00") {
              if str.contains(section, "$0.00") {
                Ok(())
              } else {
                Err(str.concat("expected zero LLM spend for a company with no cost history, got: ", section))
              }
            } else {
              Err(str.concat("expected the recorded revenue to be surfaced, got: ", section))
            }
          },
        }
      },
    },
  }
}

fn test_real_economics_section_reports_unreachable_without_inventing_zero() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("economics-unreachable")
        match company.record_operate_signal(db, id, 1, "revenue_cents", "(unreachable)") {
          Err(e) => Err(e),
          Ok(_) => {
            let section := company.real_economics_section(db, id)
            if str.contains(section, "unreachable") {
              Ok(())
            } else {
              Err(str.concat("expected the unreachable case to be reported, not silently read as $0, got: ", section))
            }
          },
        }
      },
    },
  }
}

fn test_check_and_record_revenue_noop_when_unset() -> [env, sql, fs_write, time, crypto, random, proc] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("economics-unset")
        match company.check_and_record_revenue(db, id, 1) {
          Err(e) => Err(e),
          Ok(_) => {
            let section := company.real_economics_section(db, id)
            if str.contains(section, "no revenue source configured") {
              Ok(())
            } else {
              Err(str.concat("expected no signal recorded when REVENUE_URL is unset, got: ", section))
            }
          },
        }
      },
    },
  }
}

fn test_fetch_revenue_signal_reports_unreachable_cleanly() -> [proc] Result[Unit, Str] {
  let out := company.fetch_revenue_signal("http://127.0.0.1:1")
  if str.contains(out, "unreachable") {
    Ok(())
  } else {
    Err(str.concat("expected a clean unreachable message for a refused connection, got: ", out))
  }
}

# ── #161: distribution — real posts published via publish_content, real
# view counts read back from the product's own /loom/content, not a
# self-reported claim of having written content.
fn test_strategist_prompt_includes_distribution() -> Result[Unit, Str] {
  let iter_ctx := { idx: 5, last_verdict: "passed", digest_summary: "shipped launch blog post", accepted_count: 6, bounced_count: 0, spend_cents: 0 }
  let prompt := company_runner.strategist_prompt("Build a feedback tool", "feedback v1", [], "2026-07-06T12:00:00Z: up", "(no product usage signal recorded yet)", "(no revenue source configured)", "Published posts: 1. Total views recorded: 12.", "NO Lex ('build' role) node has EVER been accepted for this company, across every iteration so far.", "", "Add a second post", iter_ctx)
  if str.contains(prompt, "DISTRIBUTION") {
    if str.contains(prompt, "Total views recorded: 12") {
      Ok(())
    } else {
      Err(str.concat("prompt missing the actual distribution value: ", prompt))
    }
  } else {
    Err(str.concat("prompt missing DISTRIBUTION section: ", prompt))
  }
}

fn test_distribution_section_no_content_published_yet() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("distribution-none")
        let section := company.distribution_section(db, id)
        if str.contains(section, "no content published yet") {
          Ok(())
        } else {
          Err(str.concat("expected the no-content case to be stated gracefully, got: ", section))
        }
      },
    },
  }
}

fn test_distribution_section_sums_posts_and_views() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("distribution-latest")
        match company.record_operate_signal(db, id, 1, "content_reach", "{\"posts\": [{\"title\": \"Launch\", \"views\": 7}, {\"title\": \"Update\", \"views\": 5}]}") {
          Err(e) => Err(e),
          Ok(_) => {
            let section := company.distribution_section(db, id)
            if str.contains(section, "Published posts: 2") {
              if str.contains(section, "Total views recorded: 12") {
                Ok(())
              } else {
                Err(str.concat("expected total views to sum both posts, got: ", section))
              }
            } else {
              Err(str.concat("expected 2 published posts to be counted, got: ", section))
            }
          },
        }
      },
    },
  }
}

fn test_distribution_section_reports_unreachable() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("distribution-unreachable")
        match company.record_operate_signal(db, id, 1, "content_reach", "(unreachable)") {
          Err(e) => Err(e),
          Ok(_) => {
            let section := company.distribution_section(db, id)
            if str.contains(section, "unreachable") {
              Ok(())
            } else {
              Err(str.concat("expected the unreachable case to be reported, got: ", section))
            }
          },
        }
      },
    },
  }
}

fn test_fetch_distribution_signal_reports_unreachable_cleanly() -> [proc] Result[Unit, Str] {
  let out := company.fetch_distribution_signal("http://127.0.0.1:1")
  if str.contains(out, "unreachable") {
    Ok(())
  } else {
    Err(str.concat("expected a clean unreachable message for a refused connection, got: ", out))
  }
}

# ── CTL7 (#118/#125): Strategist consumes controller metrics ────────────────
# Records one closed incident with an evidence cost, an action, an effect,
# and its disposition — the minimum shape operate_metrics aggregates over.
fn seed_metrics_incident(db :: conn.ConnDb, cid :: Str, tag :: Str, status :: Str, disposition :: Str, evidence_milli :: Int, at :: Str) -> [sql] Result[Unit, Str] {
  match oledger.open_incident(db, cid, "liveness", str.concat(at, tag), "[\"liveness\"]", 100000) {
    Err(e) => Err(e),
    Ok(inc) => match oledger.record_evidence(db, inc, "probe", evidence_milli, "", at) {
      Err(e) => Err(e),
      Ok(_) => match oledger.record_action(db, inc, cid, "restart", cid, "{}", "auto", at) {
        Err(e) => Err(e),
        Ok(act_id) => match oledger.record_effect(db, kct.make(act_id, "restart", cid, { signal: "liveness", cmp: Below, threshold_milli: 1000 }, 0, 90, Rollback), inc, at, at) {
          Err(e) => Err(e),
          Ok(eff_id) => match oledger.record_disposition(db, eff_id, disposition, at) {
            Err(e) => Err(e),
            Ok(_) => oledger.close_incident(db, inc, status, at, ""),
          },
        },
      },
    },
  }
}

fn test_operate_section_no_controller_data_yet() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-metrics-none")
        let section := company.operate_section(db, id)
        if str.contains(section, "no controller data yet") {
          Ok(())
        } else {
          Err(str.concat("expected the no-data case to be stated gracefully, got: ", section))
        }
      },
    },
  }
}

# The acceptance criterion for #125: two companies with identical build-loop
# state produce materially different Strategist prompts once their
# operate-ledger profiles diverge — a heavy-escalation, low-hit-rate company
# must not read the same as a clean one, independent of the last QA verdict.
fn test_strategist_prompt_differs_by_controller_metrics() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let clean := rand_id("ctl7-clean")
        let rocky := rand_id("ctl7-rocky")
        match seed_metrics_incident(db, rocky, "-a", "escalated", "falsified", 100, "2026-01-01T00:00:00Z") {
          Err(e) => Err(e),
          Ok(_) => match seed_metrics_incident(db, rocky, "-b", "escalated", "falsified", 200, "2026-01-01T00:05:00Z") {
            Err(e) => Err(e),
            Ok(_) => {
              let iter_ctx := { idx: 1, last_verdict: "passed", digest_summary: "shipped the widget", accepted_count: 1, bounced_count: 0, spend_cents: 0 }
              let clean_operate := company.operate_section(db, clean)
              let rocky_operate := company.operate_section(db, rocky)
              let clean_prompt := company_runner.strategist_prompt("Build a widget factory", "widget v1", [], clean_operate, "(no product usage signal recorded yet)", "(no revenue source configured)", "(no content published yet)", "build status n/a", "", "Add widget v2", iter_ctx)
              let rocky_prompt := company_runner.strategist_prompt("Build a widget factory", "widget v1", [], rocky_operate, "(no product usage signal recorded yet)", "(no revenue source configured)", "(no content published yet)", "build status n/a", "", "Add widget v2", iter_ctx)
              if clean_prompt == rocky_prompt {
                Err("identical build-loop state produced identical prompts despite divergent controller metrics")
              } else {
                if str.contains(rocky_prompt, "escalated: 2") {
                  if str.contains(clean_prompt, "no controller data yet") {
                    Ok(())
                  } else {
                    Err(str.concat("clean company should read as no-data-yet: ", clean_prompt))
                  }
                } else {
                  Err(str.concat("rocky company's escalation count missing from its prompt: ", rocky_prompt))
                }
              }
            },
          },
        }
      },
    },
  }
}

# ── OP3 (#87): cost ledger ────────────────────────────────────────────────────
fn insert_test_usage(db :: conn.ConnDb, owner_id :: Str, total_tokens :: Int) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let json := str.join(["{\"prompt_tokens\":0,\"completion_tokens\":0,\"total_tokens\":", int.to_str(total_tokens), "}"], "")
  let q := ormq.for_dialect({ sql: "INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES (?, ?, 'llm_usage', ?, ?)", params: [PStr("r"), PStr(owner_id), PStr(json), PStr(now)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn test_real_usage_tokens_sums_multiple_calls() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let owner := rand_id("usage-owner")
        match insert_test_usage(db, owner, 100) {
          Err(e) => Err(e),
          Ok(_) => match insert_test_usage(db, owner, 50) {
            Err(e) => Err(e),
            Ok(_) => {
              let total := company.real_usage_tokens(db, owner)
              if total == 150 {
                Ok(())
              } else {
                Err(str.concat("expected 150 summed tokens, got ", int.to_str(total)))
              }
            },
          },
        }
      },
    },
  }
}

fn test_real_usage_tokens_zero_when_none_recorded() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let owner := rand_id("usage-none")
        let total := company.real_usage_tokens(db, owner)
        if total == 0 {
          Ok(())
        } else {
          Err(str.concat("expected 0 for an owner with no usage rows, got ", int.to_str(total)))
        }
      },
    },
  }
}

# When real token usage was recorded for a sprint, it must win over the old
# char-count proxy -- that's the entire point of #94 (the proxy undercounts
# real spend). 500 tokens * 30 cents/1k = 15 cents, NOT whatever the (much
# larger) artifact char count would estimate.
fn test_estimate_iteration_cost_prefers_real_tokens() -> [sql, fs_write, time, crypto, random, fs_read] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let sprint_id := rand_id("cost-real")
        match insert_test_artifact(db, sprint_id, "loom-build", str.join(list.map(list.range(0, 200), fn (_i :: Int) -> Str {
          "x"
        }), "")) {
          Err(e) => Err(e),
          Ok(_) => match insert_test_usage(db, sprint_id, 500) {
            Err(e) => Err(e),
            Ok(_) => {
              let cents := company.estimate_iteration_cost_cents(db, sprint_id)
              if cents == 15 {
                Ok(())
              } else {
                Err(str.concat("expected 15 cents from real tokens, got ", int.to_str(cents)))
              }
            },
          },
        }
      },
    },
  }
}

# A sprint with real artifacts but NO recorded usage (e.g. every provider
# involved doesn't report it) must fall back to the char-count proxy rather
# than silently reporting zero cost.
fn test_estimate_iteration_cost_falls_back_to_char_estimate() -> [sql, fs_write, time, crypto, random, fs_read] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let sprint_id := rand_id("cost-fallback")
        match insert_test_artifact(db, sprint_id, "loom-build", str.join(list.map(list.range(0, 4000), fn (_i :: Int) -> Str {
          "x"
        }), "")) {
          Err(e) => Err(e),
          Ok(_) => {
            let cents := company.estimate_iteration_cost_cents(db, sprint_id)
            if cents > 0 {
              Ok(())
            } else {
              Err("expected a nonzero char-estimate fallback when no usage was recorded")
            }
          },
        }
      },
    },
  }
}

# The strategist runs between iterations under a per-iteration owner id
# (strategist_cost_owner), not the bare company_id -- so a SECOND iteration's
# strategist usage adds on top of the first's rather than being invisible to
# real_usage_tokens (which sums only the exact owner id it's given).
fn test_record_strategist_cost_adds_per_iteration() -> [sql, fs_write, time, crypto, random, fs_read] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let company_id := rand_id("strategist-cost")
        let cfg := { id: company_id, goal: "g", model: "test", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
        match company.save_company(db, cfg) {
          Err(e) => Err(e),
          Ok(_) => match insert_test_usage(db, company.strategist_cost_owner(company_id, 1), 1000) {
            Err(e) => Err(e),
            Ok(_) => match company.record_strategist_cost(db, company_id, 1) {
              Err(e) => Err(e),
              Ok(total1) => if total1 == 30 {
                match insert_test_usage(db, company.strategist_cost_owner(company_id, 2), 1000) {
                  Err(e) => Err(e),
                  Ok(_) => match company.record_strategist_cost(db, company_id, 2) {
                    Err(e) => Err(e),
                    Ok(total2) => if total2 == 60 {
                      Ok(())
                    } else {
                      Err(str.concat("iter 2's own usage should add on top, expected 60, got ", int.to_str(total2)))
                    },
                  },
                }
              } else {
                Err(str.concat("expected 30 cents (1000 tokens) after iter 1, got ", int.to_str(total1)))
              },
            },
          },
        }
      },
    },
  }
}

fn test_parse_dollars_to_cents() -> Result[Unit, Str] {
  if company.parse_dollars_to_cents("5.00") == 500 {
    if company.parse_dollars_to_cents("5") == 500 {
      if company.parse_dollars_to_cents("0.30") == 30 {
        if company.parse_dollars_to_cents("5.5") == 550 {
          Ok(())
        } else {
          Err(str.concat("5.5 -> expected 550, got ", int.to_str(company.parse_dollars_to_cents("5.5"))))
        }
      } else {
        Err(str.concat("0.30 -> expected 30, got ", int.to_str(company.parse_dollars_to_cents("0.30"))))
      }
    } else {
      Err(str.concat("5 -> expected 500, got ", int.to_str(company.parse_dollars_to_cents("5"))))
    }
  } else {
    Err(str.concat("5.00 -> expected 500, got ", int.to_str(company.parse_dollars_to_cents("5.00"))))
  }
}

fn test_spend_condition() -> Result[Unit, Str] {
  let under := ctx_with_spend(3, "passed", "", 0, 0, 250)
  let over := ctx_with_spend(3, "passed", "", 0, 0, 600)
  match expect("spend ge 5.00 under", company.eval_condition("spend ge 5.00", under), false) {
    Err(e) => Err(e),
    Ok(_) => match expect("spend ge 5.00 over", company.eval_condition("spend ge 5.00", over), true) {
      Err(e) => Err(e),
      Ok(_) => match expect("spend lt 5.00 under", company.eval_condition("spend lt 5.00", under), true) {
        Err(e) => Err(e),
        Ok(_) => expect("spend wf", company.is_well_formed_condition("spend ge 5.00"), true),
      },
    },
  }
}

fn test_cost_ledger_roundtrip() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-cost")
        let cfg := { id: id, goal: "Build a widget factory", model: "test", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
        match company.save_company(db, cfg) {
          Err(e) => Err(e),
          Ok(_) => {
            let before := company.get_company_cost_cents(db, id)
            if before == 0 {
              match company.add_company_cost_cents(db, id, 123) {
                Err(e) => Err(e),
                Ok(_) => {
                  let after := company.get_company_cost_cents(db, id)
                  if after == 123 {
                    match company.add_company_cost_cents(db, id, 77) {
                      Err(e) => Err(e),
                      Ok(_) => {
                        let after2 := company.get_company_cost_cents(db, id)
                        if after2 == 200 {
                          Ok(())
                        } else {
                          Err(str.concat("expected cumulative 200 cents, got ", int.to_str(after2)))
                        }
                      },
                    }
                  } else {
                    Err(str.concat("expected 123 cents, got ", int.to_str(after)))
                  }
                },
              }
            } else {
              Err("fresh company should have 0 cost")
            }
          },
        }
      },
    },
  }
}

fn test_board_report_shows_spend() -> [sql, fs_write, fs_read, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-cost-report")
        let cfg := { id: id, goal: "Build a widget factory", model: "test", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
        match company.save_company(db, cfg) {
          Err(e) => Err(e),
          Ok(_) => match company.add_company_cost_cents(db, id, 530) {
            Err(e) => Err(e),
            Ok(_) => {
              let report := company.board_report(db, id)
              if str.contains(report, "$5.30") {
                Ok(())
              } else {
                Err(str.concat("report missing formatted spend: ", report))
              }
            },
          },
        }
      },
    },
  }
}

# ── OP6 (#90): rough-edge cleanups found live this session ───────────────────
fn test_should_consume_notes_continue_keeps_pending() -> Result[Unit, Str] {
  let notes := ["focus on licensing next"]
  let continue_decision := { decision: "continue", goal: "", reason: "still improving" }
  if company_runner.should_consume_notes(notes, continue_decision) == false {
    Ok(())
  } else {
    Err("a 'continue' decision should NOT consume pending notes")
  }
}

fn test_should_consume_notes_acted_on() -> Result[Unit, Str] {
  let notes := ["focus on licensing next"]
  let revise := { decision: "revise", goal: "add licensing", reason: "pivoting per board note" }
  let add := { decision: "add", goal: "add licensing", reason: "queueing per board note" }
  let stop := { decision: "stop", goal: "", reason: "mission complete" }
  if company_runner.should_consume_notes(notes, revise) {
    if company_runner.should_consume_notes(notes, add) {
      if company_runner.should_consume_notes(notes, stop) {
        Ok(())
      } else {
        Err("'stop' should consume pending notes")
      }
    } else {
      Err("'add' should consume pending notes")
    }
  } else {
    Err("'revise' should consume pending notes")
  }
}

fn test_should_consume_notes_empty_is_noop() -> Result[Unit, Str] {
  let stop := { decision: "stop", goal: "", reason: "mission complete" }
  if company_runner.should_consume_notes([], stop) == false {
    Ok(())
  } else {
    Err("no pending notes should never need consuming")
  }
}

fn test_resume_point_marks_running_as_interrupted() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-interrupt")
        match company.record_iteration(db, { company_id: id, idx: 1, sprint_id: str.concat(id, "/iter-1"), parent_sprint_id: "", status: "running", goal: "g1" }) {
          Err(e) => Err(e),
          Ok(_) => {
            let __rp := company.resume_point(db, id)
            let its := company.load_iterations(db, id)
            match list.head(its) {
              None => Err("expected the iteration row to still exist"),
              Some(it) => if it.status == "interrupted" {
                Ok(())
              } else {
                Err(str.join(["expected status 'interrupted', got '", it.status, "'"], ""))
              },
            }
          },
        }
      },
    },
  }
}

fn test_resume_point_leaves_terminal_status_alone() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-terminal")
        match company.record_iteration(db, { company_id: id, idx: 1, sprint_id: str.concat(id, "/iter-1"), parent_sprint_id: "", status: "success", goal: "g1" }) {
          Err(e) => Err(e),
          Ok(_) => {
            let __rp := company.resume_point(db, id)
            let its := company.load_iterations(db, id)
            match list.head(its) {
              None => Err("expected the iteration row to still exist"),
              Some(it) => if it.status == "success" {
                Ok(())
              } else {
                Err(str.join(["resume_point should not touch a terminal status, got '", it.status, "'"], ""))
              },
            }
          },
        }
      },
    },
  }
}

fn test_graduate_backlog_marks_previous_done() -> [sql, fs_write, time, crypto, random, io] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-graduate")
        match company.append_backlog(db, id, "ship v1") {
          Err(e) => Err(e),
          Ok(_) => match company.append_backlog(db, id, "ship v2") {
            Err(e) => Err(e),
            Ok(_) => {
              let __first := company_runner.graduate_backlog(db, id, 1)
              let __second := company_runner.graduate_backlog(db, id, 2)
              let items := company.load_backlog(db, id)
              let v1 := list.fold(items, None, fn (acc :: Option[Str], it :: company.BacklogItem) -> Option[Str] {
                match acc {
                  Some(_) => acc,
                  None => if it.idx == 1 {
                    Some(it.status)
                  } else {
                    None
                  },
                }
              })
              match v1 {
                Some(status) => if status == "done" {
                  Ok(())
                } else {
                  Err(str.join(["expected item 1 to be 'done' after graduating past it, got '", status, "'"], ""))
                },
                None => Err("expected backlog item 1 to exist"),
              }
            },
          },
        }
      },
    },
  }
}

fn test_json_escape_survives_a_realistic_llm_judge_verdict() -> Result[Unit, Str] {
  let verdict_raw := "{\"verdict\":\"FAIL\",\"reason\":\"The artifact does not label the figure \\\"No tracked spend\\\" as an ASSUMPTION.\\nSee section 2.\"}"
  let escaped := company.json_escape(verdict_raw)
  let wrapped := str.join(["{\"node\":\"finance-pricing\",\"reason\":\"", str.slice(escaped, 0, 500), "\",\"attempt\":1}"], "")
  match jv.parse(wrapped) {
    Err(e) => Err(str.concat("expected the wrapped trail event to stay valid JSON, got parse error: ", e.message)),
    Ok(j) => match jv.get_field(j, "reason") {
      Some(JStr(r)) => if str.is_empty(r) {
        Err("expected a non-empty reason field")
      } else {
        Ok(())
      },
      _ => Err("expected a 'reason' string field in the parsed trail event"),
    },
  }
}

# ── operate_sweep (#118): CTL3 sensing already ran; this closes the loop
# by actually invoking CTL4 diagnosis and CTL5 contract proposal +
# verification on what sensing opened — the three stages that existed as
# tested library code but were never called from anywhere in the live
# iteration loop or the cron monitor. Mirrors test_diagnosis.lex's
# degraded_latency episode shape (the live sensing.sense_company path,
# not the backfill path), since operate_sweep is what runs right after
# sensing in the real between-iteration hook.
fn seed_signal(db :: conn.ConnDb, company_id :: Str, idx :: Int, kind :: Str, value :: Str, at :: Str) -> [sql] Result[Unit, Str] {
  let id := str.join([company_id, "-", kind, "-", int.to_str(idx), "-", at], "")
  let q := ormq.for_dialect({ sql: "INSERT INTO company_operate_signals (id, company_id, idx, kind, value, observed_at, incident_id, score_milli) VALUES (?, ?, ?, ?, ?, ?, '', 0)", params: [PStr(id), PStr(company_id), PInt(idx), PStr(kind), PStr(value), PStr(at)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn seed_round(db :: conn.ConnDb, cid :: Str, idx :: Int, kind :: Str, value :: Str, at :: Str) -> [sql, time] Result[Int, Str] {
  match seed_signal(db, cid, idx, kind, value, at) {
    Err(e) => Err(str.concat("seed: ", e)),
    Ok(_) => sensing.sense_company(db, None, cid, sensing.default_policy()),
  }
}

fn build_degraded_episode(db :: conn.ConnDb, cid :: Str) -> [sql, time] Result[Str, Str] {
  let __1 := seed_round(db, cid, 1, "latency_ms", "100", "2026-01-01T00:00:01")
  let __2 := seed_round(db, cid, 2, "latency_ms", "110", "2026-01-01T00:00:02")
  let __3 := seed_round(db, cid, 3, "latency_ms", "95", "2026-01-01T00:00:03")
  let __4 := seed_round(db, cid, 4, "latency_ms", "105", "2026-01-01T00:00:04")
  let __5 := seed_round(db, cid, 5, "latency_ms", "5000", "2026-01-01T00:00:05")
  match list.head(oledger.incidents_for(db, cid)) {
    None => Err("latency spike did not open an incident"),
    Some(inc) => Ok(inc),
  }
}

fn test_operate_sweep_diagnoses_and_proposes_contract() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let cid := rand_id("sweep")
        match build_degraded_episode(db, cid) {
          Err(e) => Err(e),
          Ok(inc) => match company.operate_sweep(db, cid, 5, "2026-01-02T00:00:00") {
            Err(e) => Err(str.concat("operate_sweep: ", e)),
            Ok(_) => match oledger.incident_diag(db, inc) {
              None => Err("incident vanished after operate_sweep"),
              Some(d) => if d.diagnosed_cause == "degraded_latency" {
                let pending := oledger.pending_effects_for_company(db, cid)
                if list.len(pending) == 1 {
                  Ok(())
                } else {
                  Err(str.join(["expected exactly one proposed contract, got ", int.to_str(list.len(pending))], ""))
                }
              } else {
                Err(str.concat("expected diagnosed_cause=degraded_latency, got ", d.diagnosed_cause))
              },
            },
          },
        }
      },
    },
  }
}

# A second sweep must not double-propose a contract for the same
# still-diagnosed incident (`diagnosed_without_action` excludes incidents
# that already have an operate_actions row).
fn test_operate_sweep_does_not_double_propose() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let cid := rand_id("sweep-idem")
        match build_degraded_episode(db, cid) {
          Err(e) => Err(e),
          Ok(_) => match company.operate_sweep(db, cid, 5, "2026-01-02T00:00:00") {
            Err(e) => Err(str.concat("first sweep: ", e)),
            Ok(_) => match company.operate_sweep(db, cid, 6, "2026-01-02T00:00:10") {
              Err(e) => Err(str.concat("second sweep: ", e)),
              Ok(_) => {
                let pending := oledger.pending_effects_for_company(db, cid)
                if list.len(pending) == 1 {
                  Ok(())
                } else {
                  Err(str.join(["expected still exactly one contract after a second sweep, got ", int.to_str(list.len(pending))], ""))
                }
              },
            },
          },
        }
      },
    },
  }
}

fn test_operate_sweep_noop_on_empty_company() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => match company.operate_sweep(db, rand_id("sweep-empty"), 1, "2026-01-02T00:00:00") {
        Err(e) => Err(str.concat("expected a no-op Ok(()) for a company with no incidents, got: ", e)),
        Ok(_) => Ok(()),
      },
    },
  }
}

# Found while verifying the QA<->Implementation bounce: the trail recorded
# phase_bounced but every iteration summary still printed bounced=0, and
# `STOP_WHEN "bounced ge N"` could never fire. derive_ctx counted the event
# kind "node_bounced", which nothing in the codebase has ever emitted -- so
# the number was a structural zero, not a measurement.
fn test_bounced_count_reads_the_event_that_is_actually_emitted() -> [sql, fs_write, time, crypto, random, fs_read] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let sid := rand_id("sp-bounce")
        let __a := tr.trail(db, sid, "phase_bounced", "{\"from\":\"QA\",\"to\":\"Implementation\",\"bounce\":1}")
        let __b := tr.trail(db, sid, "phase_bounced", "{\"from\":\"QA\",\"to\":\"Implementation\",\"bounce\":2}")
        let derived := company.derive_ctx(db, rand_id("co-bounce"), sid, 1, false)
        if derived.bounced_count == 2 {
          Ok(())
        } else {
          Err(str.concat("expected bounced_count=2 from two phase_bounced events, got ", int.to_str(derived.bounced_count)))
        }
      },
    },
  }
}

fn suite() -> [env, sql, fs_read, fs_write, time, crypto, random, io, proc, net, concurrent, llm, vcs, approval] List[Result[Unit, Str]] {
  [test_always_empty_never(), test_iter_bounds(), test_verdict_and_counts(), test_well_formed(), test_iteration_sprint_id(), test_company_roundtrip(), test_board_report_shows_soft_section_when_configured(), test_board_report_soft_section_defaults_not_configured(), test_list_companies_returns_seeded_ids(), test_save_company_registers_in_registry(), test_add_contact_and_resolve_returns_human(), test_add_pool_agent_contact_and_resolve_returns_pool_agent(), test_resolve_oracle_contacts_empty_when_none_configured(), test_company_id_of_sprint_extracts_prefix(), test_is_authorized_resolver_true_when_no_contacts_registered(), test_is_authorized_resolver_true_for_the_registered_contact(), test_is_authorized_resolver_false_for_an_unregistered_id_once_a_contact_exists(), test_contacts_section_lists_configured_contacts(), test_all_contacts_returns_oracle_and_resolved_contact(), test_persist_memory(), test_persist_brand_memory_writes_to_all_reader_agents(), test_persist_brand_memory_noop_when_no_brand_artifact(), test_strategist_continue(), test_strategist_revise(), test_strategist_revise_no_goal_degrades(), test_strategist_stop_and_garbage(), test_stage_advances_on_pmf(), test_stage_empty_condition_never_advances(), test_stage_growth_to_maintenance(), test_stage_sunset_from_any_stage(), test_stage_persistence_roundtrip(), test_is_dormant(), test_resume_point_fresh(), test_resume_point_after_iterations(), test_save_company_preserves_stage(), test_strategist_add(), test_strategist_add_no_goal_degrades(), test_backlog_roundtrip(), test_track_company_id(), test_portfolio_roundtrip(), test_add_track_idempotent(), test_run_portfolio_advances_and_completes_a_sunset_track(), test_run_portfolio_empty_seed_advances_nothing(), test_shipped_summary_empty(), test_shipped_summary_lists_successes_only(), test_board_notes_roundtrip(), test_board_report_contains_sections(), test_find_launch_url_from_artifact(), test_find_launch_url_none_for_cli(), test_find_deploy_url_from_artifact(), test_liveness_target_prefers_deploy_over_launch(), test_liveness_target_falls_back_to_launch(), test_liveness_target_none_for_cli(), test_check_remote_errors_no_host_is_clean(), test_check_remote_errors_no_service_name_is_clean(), test_find_deploy_service_name_from_artifact(), test_find_deploy_service_name_none_when_absent(), test_operate_section_includes_errors_when_present(), test_operate_section_omits_errors_section_when_none_recorded(), test_operate_signal_roundtrip(), test_board_report_shows_operate_section(), test_strategist_prompt_includes_operate_signals(), test_strategist_prompt_no_signals_yet(), test_strategist_prompt_includes_product_signals(), test_product_signals_section_no_signal_yet(), test_product_signals_section_reads_latest_recorded_signal(), test_fetch_product_usage_reports_unreachable_cleanly(), test_strategist_prompt_includes_real_economics(), test_real_economics_section_no_revenue_configured(), test_real_economics_section_reads_latest_recorded_signal(), test_real_economics_section_reports_unreachable_without_inventing_zero(), test_check_and_record_revenue_noop_when_unset(), test_fetch_revenue_signal_reports_unreachable_cleanly(), test_strategist_prompt_includes_distribution(), test_distribution_section_no_content_published_yet(), test_distribution_section_sums_posts_and_views(), test_distribution_section_reports_unreachable(), test_fetch_distribution_signal_reports_unreachable_cleanly(), test_real_usage_tokens_sums_multiple_calls(), test_real_usage_tokens_zero_when_none_recorded(), test_estimate_iteration_cost_prefers_real_tokens(), test_estimate_iteration_cost_falls_back_to_char_estimate(), test_record_strategist_cost_adds_per_iteration(), test_parse_dollars_to_cents(), test_spend_condition(), test_cost_ledger_roundtrip(), test_board_report_shows_spend(), test_should_consume_notes_continue_keeps_pending(), test_should_consume_notes_acted_on(), test_should_consume_notes_empty_is_noop(), test_resume_point_marks_running_as_interrupted(), test_resume_point_leaves_terminal_status_alone(), test_graduate_backlog_marks_previous_done(), test_json_escape_survives_a_realistic_llm_judge_verdict(), test_find_build_artifact_matches_by_role_not_node_name(), test_find_build_artifact_falls_back_without_a_graph_row(), test_find_build_artifact_none_when_neither_matches(), test_has_shipped_build_node_false_when_only_py_build_accepted(), test_has_shipped_build_node_true_when_a_build_node_was_accepted(), test_has_shipped_build_node_false_when_build_node_was_never_accepted(), test_build_status_section_wording_matches_shipped_state(), test_build_status_section_true_when_most_recent_iteration_shipped_build(), test_build_status_section_flags_drift_when_recent_iteration_dropped_lex(), test_strategist_reply_is_parseable_true_for_valid_json(), test_strategist_reply_is_parseable_false_for_garbage(), test_operate_section_no_controller_data_yet(), test_strategist_prompt_differs_by_controller_metrics(), test_board_report_omits_non_escalate_pending_contracts(), test_operate_sweep_diagnoses_and_proposes_contract(), test_operate_sweep_does_not_double_propose(), test_operate_sweep_noop_on_empty_company(), test_bounced_count_reads_the_event_that_is_actually_emitted()]
}

fn run_all() -> [env, sql, fs_read, fs_write, time, crypto, random, io, proc, net, concurrent, llm, vcs, approval] Unit {
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

