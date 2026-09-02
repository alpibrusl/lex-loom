#!/usr/bin/env bash
# evidence-report.sh — what was each of a sprint's claims actually backed by?
#
# Borrowed from the "Prompt to..." series (creative/prompt-to-production,
# creative/prompt-to-evidence), whose closing checklists turn on one
# distinction loom states as philosophy and never reports:
#
#   [checkable]  a property a file or command can settle — go look
#   [ask-human]  a claim about something that HAPPENED — no amount of reading
#                the repository proves it
#
# and the rule that follows: marking the second kind done because the machinery
# for it exists is the most misleading thing a report can do.
#
# That is this repo's own recurring failure. The import gate existed for days
# before anything proved it had ever run. The role contract shipped and I could
# not say whether zero violations meant "nothing violated" or "never fired". A
# reliability-classifier fix was reported as landed when half of it had never
# been written to the file. In every case the machinery was present and the
# event was unwitnessed.
#
# loom already ranks gates (grounded > judge > human). It has never reported
# where each sealed claim actually sat on that ladder, so a sprint gated
# entirely on "output longer than 50 characters" reports SUCCESS in exactly the
# same words as one gated on a compiler and a test run.
#
#   bin/evidence-report.sh <company.db>
set -euo pipefail
DB="${1:?usage: evidence-report.sh <company.db>}"
[ -f "$DB" ] || { echo "no such database: $DB" >&2; exit 2; }

q() { sqlite3 "$DB" "$1" 2>/dev/null; }

# Gate -> evidence strength. Deliberately blunt; the point is the split, not a score.
classify() {
  case "$1" in
    "spec compiles"|"spec json-verdict-pass"|"spec json-ok-true") echo "grounded" ;;
    "spec sh "*)        echo "grounded" ;;
    "spec judge "*)     echo "judged" ;;
    "human "*)          echo "human" ;;
    "spec len-gt "*|"spec non-empty"|"spec json") echo "presence" ;;
    *)                  echo "unknown" ;;
  esac
}

echo "== evidence report: $(basename "$(dirname "$DB")")"
echo

python3 - "$DB" <<'PY'
import json, sqlite3, sys

db = sqlite3.connect(sys.argv[1])

# node -> gate comes from the STORED GRAPHS, not from denial records. Reading it
# off denials only would leave every node that passed first time labelled
# "gate not recorded" and counted as unwitnessed -- a report that misreports,
# which is the failure these books are about. Checked: the first version of this
# script did exactly that.
gates = {}
for (gj,) in db.execute("select graph_json from sprint_graphs"):
    try:
        g = json.loads(gj)
    except Exception:
        continue
    for n in g.get("nodes", []):
        if n.get("id") and n.get("gate"):
            gates.setdefault(n["id"], n["gate"])

def strength(gate):
    if gate is None:                       return ("unknown", "[NO GATE FOUND]")
    if gate.startswith(("spec compiles", "spec json-verdict-pass", "spec json-ok-true", "spec sh ")):
        return ("grounded", "[checkable]")
    if gate.startswith("spec judge "):     return ("judged",   "[judged]")
    if gate.startswith("human "):          return ("human",    "[human]")
    if gate.startswith(("spec len-gt", "spec non-empty", "spec json")):
        return ("presence", "[UNWITNESSED]")
    return ("unknown", "[NO GATE FOUND]")

accepted = []
for (dj,) in db.execute("select data_json from traces where event_kind='node_accepted'"):
    try:
        n = json.loads(dj).get("node")
    except Exception:
        continue
    if n and n not in accepted:
        accepted.append(n)

strong = weak = 0
for n in accepted:
    g = gates.get(n)
    kind, tag = strength(g)
    if kind in ("grounded", "human", "judged"):
        strong += 1
    else:
        weak += 1
    print(f"   {tag:<15} {n:<22} {g or '(no gate in any stored graph)'}")

print()
print(f"   sealed on a real check: {strong}    sealed on presence alone: {weak}")
if weak:
    print("   A claim sealed on 'output longer than N characters' is a claim nobody checked.")
PY
echo
echo "-- mechanisms present but never exercised in this run"
none=1
for m in "role contract:contract_violation" "qa_skipped_no_producer:producer precondition" \
         "check_imports:import gate" "NO TEST FILE:test-file check" "PASTED:derived-values gate" \
         "phase_bounce_stalled:bounce-stall detector"; do
  pat="${m%%:*}"; label="${m##*:}"
  n=$(q "select count(*) from traces where data_json like '%${pat}%';")
  if [ "${n:-0}" -eq 0 ]; then
    printf '   never fired   %s\n' "$label"; none=0
  fi
done
[ $none -eq 1 ] && echo "   (every mechanism fired at least once)"
echo
echo "   A mechanism that never fires is either unnecessary or broken, and this"
echo "   report cannot tell you which. That is the point of listing it."
