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

