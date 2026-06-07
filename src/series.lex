# series.lex — sprint series statistics for the improvement chart.
#
# Queries the traces and artifacts tables to produce one SprintStat per
# completed sprint: timestamp, overall success, and QA verdict.
# Used by GET /api/series to power the dashboard improvement chart.

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

type SprintIdRow  = { agent_id :: Str }
type TsRow        = { ts :: Str }
type CompleteRow  = { data_json :: Str }
type QaResultRow  = { data_json :: Str }
type ArtifactRow  = { content :: Str }

type QaInfo = { accepted :: Bool, verdict :: Str }

type SprintStat = { sprint_id :: Str, ts :: Str, success :: Bool, qa_accepted :: Bool, qa_verdict :: Str }

# ── Public API ────────────────────────────────────────────────────────────────
fn load_series(db :: Db) -> [sql, fs_read] List[SprintStat] {
  let q := "SELECT agent_id FROM traces WHERE event_kind='sprint_started' GROUP BY agent_id ORDER BY MIN(ts) ASC"
  let rows :: Result[List[SprintIdRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: SprintIdRow) -> [sql, fs_read] SprintStat {
      build_stat(db, r.agent_id)
    }),
  }
}

fn to_json(stats :: List[SprintStat]) -> Str {
  str.concat("[", str.concat(str.join(list.map(stats, stat_to_json), ","), "]"))
}

# ── Per-sprint helpers ────────────────────────────────────────────────────────
fn build_stat(db :: Db, sid :: Str) -> [sql, fs_read] SprintStat {
  let ts      := load_ts(db, sid)
  let success := load_success(db, sid)
  let qa      := load_qa_info(db, sid)
  { sprint_id: sid, ts: ts, success: success, qa_accepted: qa.accepted, qa_verdict: qa.verdict }
}

fn load_ts(db :: Db, sid :: Str) -> [sql, fs_read] Str {
  let q := str.join(["SELECT ts FROM traces WHERE agent_id='", sq(sid), "' AND event_kind='sprint_started' LIMIT 1"], "")
  let rows :: Result[List[TsRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(_) => "",
    Ok(rs) => match list.head(rs) { None => "", Some(r) => r.ts },
  }
}

fn load_success(db :: Db, sid :: Str) -> [sql, fs_read] Bool {
  let q := str.join(["SELECT data_json FROM traces WHERE agent_id='", sq(sid), "' AND event_kind='sprint_complete' LIMIT 1"], "")
  let rows :: Result[List[CompleteRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(_) => false,
    Ok(rs) => match list.head(rs) {
      None => false,
      Some(r) => match jv.parse(r.data_json) {
        Err(_) => false,
        Ok(j) => match jv.get_field(j, "success") {
          Some(JBool(b)) => b,
          _ => false,
        },
      },
    },
  }
}

fn load_qa_info(db :: Db, sid :: Str) -> [sql, fs_read] QaInfo {
  let q := str.join(["SELECT data_json FROM traces WHERE agent_id='", sq(sid), "' AND event_kind='node_accepted' AND data_json LIKE '%qa%' ORDER BY ts DESC LIMIT 1"], "")
  let rows :: Result[List[QaResultRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(_) => { accepted: false, verdict: "" },
    Ok(rs) => match list.head(rs) {
      None => { accepted: false, verdict: "" },
      Some(r) => {
        let hash := get_str_field(r.data_json, "artifact")
        let verdict := if str.is_empty(hash) { "" } else { load_verdict(db, hash) }
        { accepted: true, verdict: verdict }
      },
    },
  }
}

fn load_verdict(db :: Db, hash :: Str) -> [sql, fs_read] Str {
  let q := str.join(["SELECT content FROM artifacts WHERE hash='", sq(hash), "'"], "")
  let rows :: Result[List[ArtifactRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(_) => "",
    Ok(rs) => match list.head(rs) {
      None => "",
      Some(r) => get_str_field(r.content, "verdict"),
    },
  }
}

fn get_str_field(json_str :: Str, field :: Str) -> Str {
  match jv.parse(json_str) {
    Err(_) => "",
    Ok(j) => match jv.get_field(j, field) {
      Some(JStr(v)) => v,
      _ => "",
    },
  }
}

# ── JSON serialisation ────────────────────────────────────────────────────────
fn stat_to_json(s :: SprintStat) -> Str {
  str.join(["{\"sprint_id\":", jv.stringify(JStr(s.sprint_id)), ",\"ts\":", jv.stringify(JStr(s.ts)), ",\"success\":", if s.success {
    "true"
  } else {
    "false"
  }, ",\"qa_accepted\":", if s.qa_accepted {
    "true"
  } else {
    "false"
  }, ",\"qa_verdict\":", jv.stringify(JStr(s.qa_verdict)), "}"], "")
}

