# a2a.lex — outgoing agent-to-agent messages.

import "std.http" as http

import "std.bytes" as bytes

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-orm/src/connection" as conn

import "./registry" as reg

fn http_err(e :: HttpError) -> Str {
  match e {
    TimeoutError => "timeout",
    TlsError(m) => str.concat("tls: ", m),
    NetworkError(m) => str.concat("network: ", m),
    DecodeError(m) => str.concat("decode: ", m),
  }
}

fn build_envelope(from_id :: Str, topic :: Str, payload_json :: Str) -> Str {
  jv.stringify(JObj([("from", JStr(from_id)), ("topic", JStr(topic)), ("payload_json", JStr(payload_json))]))
}

fn send(db :: conn.ConnDb, from_id :: Str, to_id :: Str, topic :: Str, payload_json :: Str) -> [sql, fs_read, net] Result[Unit, Str] {
  match reg.find_by_id(db, to_id) {
    Err(e) => Err(e),
    Ok(None) => Err(str.concat("agent not found: ", to_id)),
    Ok(Some(peer)) => {
      let body := build_envelope(from_id, topic, payload_json)
      match http.post(peer.inbox_url, bytes.from_str(body), "application/json") {
        Err(e) => Err(http_err(e)),
        Ok(_) => Ok(()),
      }
    },
  }
}

fn broadcast(db :: conn.ConnDb, from_id :: Str, to_ids :: List[Str], topic :: Str, payload_json :: Str) -> [sql, fs_read, net] List[Result[Unit, Str]] {
  list.map(to_ids, fn (to_id :: Str) -> [sql, fs_read, net] Result[Unit, Str] {
    send(db, from_id, to_id, topic, payload_json)
  })
}
