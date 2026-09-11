# economy_binding.lex -- loom's side of lex-economy (#398).
#
# The first, smallest piece of the consortium binding: a company gets a
# treasury on loom's OWN database handle. lex-economy's treasury takes a
# std.sql Db, which is exactly conn.ConnDb.handle, so nothing is copied or
# adapted. Idempotent: a company that already has a treasury keeps it (with
# its balance), so resuming a company does not re-fund it.
#
# Mechanism only: no opening balance is invented here; the caller (company
# start, from the manifest's policy) decides the cents.

import "std.str" as str

import "lex-orm/src/connection" as conn

import "lex-economy/src/treasury" as treasury

import "lex-economy/src/capability" as capability

import "lex-schema/json_value" as jv

import "lex-orm/src/query" as ormq

import "std.sql" as sql

import "std.list" as list

import "std.time" as time

import "./budget" as budget

import "lex-trail/src/log" as tlog

fn ensure_treasury(db :: conn.ConnDb, company_id :: Str, currency :: Str, opening_cents :: Int) -> [sql] Result[treasury.Treasury, Str] {
  match treasury.init_schema(db.handle) {
    Err(e) => Err(str.concat("economy: treasury schema: ", e)),
    Ok(_) => match treasury.get_treasury(db.handle, company_id) {
      Err(e) => Err(str.concat("economy: read treasury: ", e)),
      Ok(Some(t)) => Ok(t),
      Ok(None) => match treasury.open_treasury(db.handle, company_id, currency, opening_cents) {
        Err(e) => Err(str.concat("economy: open treasury: ", e)),
        Ok(_) => match treasury.get_treasury(db.handle, company_id) {
          Ok(Some(t)) => Ok(t),
          Ok(None) => Err("economy: the treasury did not open"),
          Err(e) => Err(str.concat("economy: read treasury after open: ", e)),
        },
      },
    },
  }
}

# Reserve funds for a contract through lex-economy's own invariant checks
# (balance and policy). Returns the commitment id on success.
fn commit_for_contract(db :: conn.ConnDb, log :: tlog.Log, company_id :: Str, contract_id :: Str, commitment_id :: Str, amount_cents :: Int, currency :: Str) -> [sql, time] Result[Str, Str] {
  match treasury.commit_funds(db.handle, log, company_id, contract_id, commitment_id, amount_cents, currency) {
    Err(e) => Err(e),
    Ok(_) => Ok(commitment_id),
  }
}

# Piece 2 (#398): a company's opening balance is the `total` budget envelope
# it already runs under -- one number, one source of truth. A company with
# no total envelope gets no treasury (no budget, no funds), and says so.
fn fund_from_total_envelope(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] Result[Option[treasury.Treasury], Str] {
  match budget.envelope_for(db, company_id, "total") {
    None => Ok(None),
    Some(e) => match ensure_treasury(db, company_id, "EUR", e.cap_cents) {
      Err(err) => Err(err),
      Ok(t) => Ok(Some(t)),
    },
  }
}

# Piece 3 (#398): what a company can SELL follows from what it is staffed
# with. Run-1 vocabulary (docs/consortium-freeze.md owns it): a stack path
# yields software-delivery/v1 in that language; the content pack yields
# content-drafting/v1; the finance pack yields pricing-and-economics/v1.
# Pure, so a manifest can be checked before anything runs.
fn language_of_path(path :: Str) -> Str {
  if str.starts_with(path, "python-") {
    "python"
  } else {
    if str.starts_with(path, "lex-") {
      "lex"
    } else {
      if str.starts_with(path, "node-") or str.starts_with(path, "nextjs") or str.starts_with(path, "web-") or str.starts_with(path, "rn-") {
        "node"
      } else {
        ""
      }
    }
  }
}

fn offers_for(packs :: List[Str], path :: Str) -> List[capability.Offer] {
  let lang := language_of_path(path)
  let delivery := if str.is_empty(lang) {
    []
  } else {
    [{ capability: "software-delivery/v1", attrs: JObj([("language", JStr(lang)), ("path", JStr(path))]) }]
  }
  list.fold(packs, delivery, fn (acc :: List[capability.Offer], pack :: Str) -> List[capability.Offer] {
    if pack == "content" {
      list.concat(acc, [{ capability: "content-drafting/v1", attrs: JObj([("pack", JStr("content"))]) }])
    } else {
      if pack == "finance" {
        list.concat(acc, [{ capability: "pricing-and-economics/v1", attrs: JObj([("pack", JStr("finance"))]) }])
      } else {
        if pack == "research" {
          list.concat(acc, [{ capability: "opportunity-research/v1", attrs: JObj([("pack", JStr("research")), ("gate", JStr("check_research_report"))]) }])
        } else {
          if pack == "ops" {
            list.concat(acc, [{ capability: "operable-delivery/v1", attrs: JObj([("pack", JStr("ops")), ("gate", JStr("check_operable_delivery"))]) }])
          } else {
            if pack == "growth" {
              list.concat(acc, [{ capability: "launch-delivery/v1", attrs: JObj([("pack", JStr("growth")), ("gate", JStr("check_launch_delivery"))]) }])
            } else {
              acc
            }
          }
        }
      }
    }
  })
}

type OfferRow = { company_id :: Str, capability :: Str, attrs_json :: Str }

# Declare (idempotently) the company's offers in the shared table.
fn declare_capabilities(db :: conn.ConnDb, company_id :: Str, packs :: List[Str], path :: Str) -> [sql, fs_write, time] Result[List[capability.Offer], Str] {
  let offers := offers_for(packs, path)
  let del := ormq.for_dialect({ sql: "DELETE FROM capability_offers WHERE company_id=?", params: [PStr(company_id)] }, db.dialect)
  match sql.exec(db.handle, del.sql, del.params) {
    Err(e) => Err(str.concat("economy: clear offers: ", e.message)),
    Ok(_) => list.fold(offers, Ok(offers), fn (acc :: Result[List[capability.Offer], Str], o :: capability.Offer) -> [sql, fs_write, time] Result[List[capability.Offer], Str] {
      match acc {
        Err(e) => Err(e),
        Ok(_) => {
          let ins := ormq.for_dialect({ sql: "INSERT INTO capability_offers (company_id, capability, attrs_json, created_at) VALUES (?, ?, ?, ?)", params: [PStr(company_id), PStr(o.capability), PStr(jv.stringify(o.attrs)), PStr(time.now_str())] }, db.dialect)
          match sql.exec(db.handle, ins.sql, ins.params) {
            Err(e) => Err(str.concat("economy: declare offer: ", e.message)),
            Ok(_) => Ok(offers),
          }
        },
      }
    }),
  }
}

# Every company's offers, in the shape lex-economy's capability.find takes.
fn company_offers(db :: conn.ConnDb) -> [sql, fs_read] List[capability.CompanyOffers] {
  let q := ormq.for_dialect({ sql: "SELECT company_id, capability, attrs_json FROM capability_offers ORDER BY company_id, capability", params: [] }, db.dialect)
  let rows :: Result[List[OfferRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.fold(rs, [], fn (acc :: List[capability.CompanyOffers], r :: OfferRow) -> List[capability.CompanyOffers] {
      let offer := { capability: r.capability, attrs: match jv.parse(r.attrs_json) {
        Ok(j) => j,
        Err(_) => JObj([]),
      } }
      match list.head(list.filter(acc, fn (c :: capability.CompanyOffers) -> Bool {
        c.company == r.company_id
      })) {
        Some(_) => list.map(acc, fn (c :: capability.CompanyOffers) -> capability.CompanyOffers {
          if c.company == r.company_id {
            { company: c.company, offers: list.concat(c.offers, [offer]) }
          } else {
            c
          }
        }),
        None => list.concat(acc, [{ company: r.company_id, offers: [offer] }]),
      }
    }),
  }
}

