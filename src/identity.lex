# identity.lex — did:lex portable agent reputation (#52, kernel P2).
#
# Every pool agent gets a did:lex identity derived from an Ed25519 public key
# loom custodies for it (loom is the issuer; agents are prompts, not
# processes). A sprint that passes the four-layer verifier (integrity →
# grounded → authority → operations) becomes a SIGNED attestation bundle bound
# to the agent's did. Reputation is never stored — it is DERIVED as the count
# of verified attestations per did, so it accrues only from verified runs and
# a forged or tampered bundle contributes nothing (its signature fails
# verify_attestation, and an unverified run is recorded with verified=0).
#
# The bundle + signature + pubkey travel together, so a third party can check
# an attestation OUTSIDE the issuing loom — the same portability rule as
# lex-games' arena registry (reputation accrues solely from sessions whose
# trail replays clean).

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.sql" as sql

import "std.bytes" as bytes

import "std.crypto" as crypto

import "std.time" as time

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

# ── DID derivation ────────────────────────────────────────────────────────────
# Deterministic from the public key alone: anyone holding the pubkey can
# recompute the did and check they match.
fn did_of_pubkey(pubkey_b64 :: Str) -> [crypto] Str {
  str.concat("did:lex:agent:", str.slice(crypto.sha256_str(pubkey_b64), 0, 16))
}

type Identity = { did :: Str, pubkey_b64 :: Str, secret_b64 :: Str }

# Exactly 32 seed bytes regardless of how many hex chars random_str_hex(32)
# yields on this runtime.
fn new_seed() -> [crypto, random] Str {
  str.slice(str.concat(crypto.random_str_hex(32), crypto.random_str_hex(32)), 0, 32)
}

fn load_identity(db :: conn.ConnDb, agent_id :: Str) -> [sql] Option[Identity] {
  let qd := ormq.for_dialect({ sql: "SELECT did, pubkey_b64, secret_b64 FROM agent_pool WHERE id = ?", params: [PStr(agent_id)] }, db.dialect)
  let rows :: Result[List[Identity], SqlError] := sql.query(db.handle, qd.sql, qd.params)
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None => None,
      Some(r) => if str.is_empty(r.did) {
        None
      } else {
        Some({ did: r.did, pubkey_b64: r.pubkey_b64, secret_b64: r.secret_b64 })
      },
    },
  }
}

# Get-or-mint the agent's identity. Idempotent: once minted, the same did and
# keys come back on every call. An agent id with no pool row gets a transient
# identity (still signs and verifies) — it just isn't persisted.
fn ensure_identity(db :: conn.ConnDb, agent_id :: Str) -> [sql, fs_write, crypto, random] Identity {
  match load_identity(db, agent_id) {
    Some(found) => found,
    None => {
      let secret_str := new_seed()
      let secret := bytes.from_str(secret_str)
      match crypto.ed25519_public_key(secret) {
        Err(_) => { did: "", pubkey_b64: "", secret_b64: "" },
        Ok(pk) => {
          let pubkey_b64 := crypto.base64url_encode(pk)
          let minted := { did: did_of_pubkey(pubkey_b64), pubkey_b64: pubkey_b64, secret_b64: crypto.base64url_encode(secret) }
          let qd := ormq.for_dialect({ sql: "UPDATE agent_pool SET did = ?, pubkey_b64 = ?, secret_b64 = ? WHERE id = ?", params: [PStr(minted.did), PStr(minted.pubkey_b64), PStr(minted.secret_b64), PStr(agent_id)] }, db.dialect)
          let __u := sql.exec(db.handle, qd.sql, qd.params)
          minted
        },
      }
    },
  }
}

# ── Signing / portable verification ──────────────────────────────────────────
fn sign_bundle(secret_b64 :: Str, bundle_json :: Str) -> [crypto] Str {
  match crypto.base64url_decode(secret_b64) {
    Err(_) => "",
    Ok(secret) => match crypto.ed25519_sign(secret, bytes.from_str(bundle_json)) {
      Err(_) => "",
      Ok(sig) => crypto.base64url_encode(sig),
    },
  }
}

# The portable check: bundle + sig + pubkey are all a third party needs. Also
# recomputes the did binding — a bundle signed by one key but claiming another
# agent's did fails even with a valid signature.
fn verify_attestation(pubkey_b64 :: Str, bundle_json :: Str, sig_b64 :: Str) -> [crypto] Bool {
  match crypto.base64url_decode(pubkey_b64) {
    Err(_) => false,
    Ok(pk) => match crypto.base64url_decode(sig_b64) {
      Err(_) => false,
      Ok(sig) => if crypto.ed25519_verify(pk, bytes.from_str(bundle_json), sig) {
        str.contains(bundle_json, str.join(["\"agent_did\":\"", did_of_pubkey(pubkey_b64), "\""], ""))
      } else {
        false
      },
    },
  }
}

# ── Attestation issuance ──────────────────────────────────────────────────────
# Bind (sprint, agent, role, four-layer verdicts) into one signed credential.
# `all_verified` is the conjunction of the four verifier layers; it is recorded
# in the bundle AND in the queryable column, so reputation queries never have
# to re-parse bundles.
fn attestation_bundle(sprint_id :: Str, agent_did :: Str, agent_id :: Str, role :: Str, verdicts_json :: Str, all_verified :: Bool) -> Str {
  str.join(["{\"kind\":\"loom.sprint.attestation\",\"sprint_id\":\"", sprint_id, "\",\"agent_did\":\"", agent_did, "\",\"agent_id\":\"", agent_id, "\",\"role\":\"", role, "\",\"verified\":", if all_verified {
    "true"
  } else {
    "false"
  }, ",\"verdicts\":", verdicts_json, "}"], "")
}

fn issue_attestation(db :: conn.ConnDb, sprint_id :: Str, agent_id :: Str, role :: Str, verdicts_json :: Str, all_verified :: Bool) -> [sql, fs_write, crypto, random, time] Identity {
  let ident := ensure_identity(db, agent_id)
  let bundle := attestation_bundle(sprint_id, ident.did, agent_id, role, verdicts_json, all_verified)
  let sig := sign_bundle(ident.secret_b64, bundle)
  let id := crypto.random_str_hex(16)
  let now := time.now_str()
  let qd := ormq.for_dialect({ sql: "INSERT INTO attestations (id, sprint_id, agent_id, agent_did, role, bundle_json, sig_b64, pubkey_b64, verified, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)", params: [PStr(id), PStr(sprint_id), PStr(agent_id), PStr(ident.did), PStr(role), PStr(bundle), PStr(sig), PStr(ident.pubkey_b64), PInt(if all_verified {
    1
  } else {
    0
  }), PStr(now)] }, db.dialect)
  let __i := sql.exec(db.handle, qd.sql, qd.params)
  ident
}

# ── Reputation (derived, verified-only) ───────────────────────────────────────
type RepRow = { agent_did :: Str, sessions :: Int, reputation :: Int }

type CountRow = { n :: Int }

fn reputation_for_did(db :: conn.ConnDb, agent_did :: Str) -> [sql] Int {
  let qd := ormq.for_dialect({ sql: "SELECT COUNT(*) AS n FROM attestations WHERE agent_did = ? AND verified = 1", params: [PStr(agent_did)] }, db.dialect)
  let rows :: Result[List[CountRow], SqlError] := sql.query(db.handle, qd.sql, qd.params)
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => r.n,
    },
  }
}

# Registry export in the arena's shape (kind/profiles/did/reputation/sessions):
# reputation counts verified attestations only; sessions counts all.
fn registry_json(db :: conn.ConnDb) -> [sql] Str {
  let q := "SELECT agent_did, COUNT(*) AS sessions, SUM(verified) AS reputation FROM attestations WHERE agent_did <> '' GROUP BY agent_did ORDER BY reputation DESC, agent_did ASC"
  let rows :: Result[List[RepRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => "{\"kind\":\"reputation\",\"profiles\":[]}",
    Ok(rs) => {
      let parts := list.map(rs, fn (r :: RepRow) -> Str {
        str.join(["{\"did\":\"", r.agent_did, "\",\"reputation\":", int.to_str(r.reputation), ",\"sessions\":", int.to_str(r.sessions), "}"], "")
      })
      str.join(["{\"kind\":\"reputation\",\"profiles\":[", str.join(parts, ","), "]}"], "")
    },
  }
}

