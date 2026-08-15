# test_identity.lex — did:lex portable reputation (#52): identity minting,
# signed attestation bundles, portable verification, verified-only reputation,
# and the cast preference for reputed agents. Offline — no LLM.

import "std.list" as list

import "std.io" as io

import "std.str" as str

import "std.crypto" as crypto

import "std.int" as int

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "std.fs" as fs

import "../src/migrate" as migrate

import "../src/identity" as identity

import "../src/cast" as cast

# Each open is a fresh per-run file DB (#242); per-test agent/sprint ids
# keep rows disjoint within a connection (same rule as test_ops.lex).
fn fresh_db() -> [sql, fs_write, time, random] Result[conn.ConnDb, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(m) => Err(str.concat("migrate failed: ", m)),
      Ok(_) => Ok(db),
    },
  }
}

fn seed_pool_agent(db :: conn.ConnDb, id :: Str, role :: Str, count :: Int) -> [sql, fs_write] Unit {
  let q := str.join(["INSERT OR IGNORE INTO agent_pool (id, role, system_prompt, attestation_count, created_at) VALUES ('", id, "', '", role, "', 'p', ", int.to_str(count), ", 't')"], "")
  let __r := sql.exec(db.handle, q, [])
  ()
}

# Minting is idempotent: same did and pubkey on every call, did derived from
# the pubkey.
fn test_identity_stable() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let __s := seed_pool_agent(db, "idops-stable", "build", 0)
      let i1 := identity.ensure_identity(db, "idops-stable")
      let i2 := identity.ensure_identity(db, "idops-stable")
      if str.starts_with(i1.did, "did:lex:agent:") {
        if i1.did == i2.did {
          if i1.pubkey_b64 == i2.pubkey_b64 {
            if i1.did == identity.did_of_pubkey(i1.pubkey_b64) {
              Ok(())
            } else {
              Err("did does not re-derive from pubkey")
            }
          } else {
            Err("pubkey changed between calls")
          }
        } else {
          Err(str.join(["did changed between calls: ", i1.did, " vs ", i2.did], ""))
        }
      } else {
        Err(str.concat("bad did prefix: ", i1.did))
      }
    },
  }
}

# Sign → verify round-trip; a tampered bundle or the wrong key fails.
fn test_sign_verify_tamper() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let __s1 := seed_pool_agent(db, "idops-signer", "build", 0)
      let __s2 := seed_pool_agent(db, "idops-other", "build", 0)
      let ident := identity.ensure_identity(db, "idops-signer")
      let other := identity.ensure_identity(db, "idops-other")
      let bundle := identity.attestation_bundle("idops-s0", ident.did, "idops-signer", "build", "{}", true)
      let sig := identity.sign_bundle(ident.secret_b64, bundle)
      if str.is_empty(sig) {
        Err("empty signature")
      } else {
        if identity.verify_attestation(ident.pubkey_b64, bundle, sig) {
          if identity.verify_attestation(ident.pubkey_b64, str.replace(bundle, "\"verified\":true", "\"verified\":false"), sig) {
            Err("tampered bundle verified")
          } else {
            if identity.verify_attestation(other.pubkey_b64, bundle, sig) {
              Err("wrong key verified")
            } else {
              Ok(())
            }
          }
        } else {
          Err("valid attestation did not verify")
        }
      }
    },
  }
}

# Reputation accrues from VERIFIED attestations only, and the stored bundle is
# portably checkable straight out of the table.
fn test_verified_only_reputation() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let __s := seed_pool_agent(db, "idops-rep", "build", 0)
      let i1 := identity.issue_attestation(db, "idops-s1", "idops-rep", "build", "{\"ok\":true}", true)
      let __i2 := identity.issue_attestation(db, "idops-s2", "idops-rep", "build", "{\"ok\":false}", false)
      let rep := identity.reputation_for_did(db, i1.did)
      if rep == 1 {
        let reg := identity.registry_json(db)
        if str.contains(reg, str.join(["\"did\":\"", i1.did, "\",\"reputation\":1,\"sessions\":2"], "")) {
          check_stored_bundle(db, i1.did)
        } else {
          Err(str.concat("registry missing profile: ", reg))
        }
      } else {
        Err(str.concat("expected reputation 1, got ", int.to_str(rep)))
      }
    },
  }
}

type AttRow = { bundle_json :: Str, sig_b64 :: Str, pubkey_b64 :: Str }

fn check_stored_bundle(db :: conn.ConnDb, did :: Str) -> [sql, crypto] Result[Unit, Str] {
  let q := str.join(["SELECT bundle_json, sig_b64, pubkey_b64 FROM attestations WHERE agent_did='", did, "' AND verified=1"], "")
  let rows :: Result[List[AttRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => Err("cannot read attestation back"),
    Ok(rs) => match list.head(rs) {
      None => Err("no verified attestation row"),
      Some(r) => if identity.verify_attestation(r.pubkey_b64, r.bundle_json, r.sig_b64) {
        Ok(())
      } else {
        Err("stored attestation does not verify portably")
      },
    },
  }
}

# The cast prefers the agent whose reputation is earned from verified runs:
# same local attestation_count, same (empty) tags — reputation breaks the tie.
fn test_cast_prefers_reputation() -> [sql, fs_read, fs_write, time, crypto, random] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let __a := seed_pool_agent(db, "idops-plain", "idops_role", 2)
      let __b := seed_pool_agent(db, "idops-proven", "idops_role", 2)
      let __att := identity.issue_attestation(db, "idops-s3", "idops-proven", "idops_role", "{}", true)
      let pool := cast.load_pool_for_role(db, "idops_role")
      if list.len(pool) == 2 {
        match cast.best_agent(pool, "some request") {
          None => Err("no best agent"),
          Some(a) => if a.id == "idops-proven" {
            Ok(())
          } else {
            Err(str.concat("cast ignored verified reputation, picked ", a.id))
          },
        }
      } else {
        Err(str.concat("expected 2 pool agents, got ", int.to_str(list.len(pool))))
      }
    },
  }
}

fn suite() -> [sql, fs_read, fs_write, time, crypto, random] List[Result[Unit, Str]] {
  [test_identity_stable(), test_sign_verify_tamper(), test_verified_only_reputation(), test_cast_prefers_reputation()]
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random] Unit {
  let failures := list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> [io] Int {
    match r {
      Ok(_) => n,
      Err(m) => {
        let __p := io.print(str.concat("test_identity FAIL: ", m))
        n + 1
      },
    }
  })
  if failures == 0 {
    ()
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

