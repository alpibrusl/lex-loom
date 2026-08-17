#!/usr/bin/env bash
# bootstrap-company.sh — deterministically scaffold a company from a
# declarative company.toml, then hand off to run-company.sh (#91).
#
# The DESIGN principle: repo layout, chosen stack, infra, budget and policy
# are plumbing, not judgment — decided ONCE here, from config, by a script.
# The LLM agents never decide structure; they only fill in features inside a
# pre-decided skeleton. loom's runtime stays env-var driven (unchanged); this
# script is the only thing that reads company.toml.
#
# Usage:
#   bin/bootstrap-company.sh <company.toml> [--no-run]
#
#   --no-run   scaffold the workspace + skeleton + git, print the resolved run
#              command, but do NOT start the company. (Deterministic, free —
#              safe to run in tests / to inspect the scaffold.)
#
# Env:
#   LOOM_WORKSPACE   where companies live (default: ~/loom-companies)
#   GITHUB_PUBLISH   =1 to `gh repo create` (private) from infra.repo; else local git only
set -euo pipefail
cd "$(dirname "$0")/.."
LOOM_ROOT="$(pwd)"

MANIFEST="${1:-}"
NORUN="${2:-}"
if [ -z "$MANIFEST" ] || [ ! -f "$MANIFEST" ]; then
  echo "usage: bin/bootstrap-company.sh <company.toml> [--no-run]" >&2
  exit 2
fi

# ── Parse the manifest deterministically (python tomllib → shell assignments).
# shlex.quote makes every value safe to eval; the manifest is operator-authored.
eval "$(python3 - "$MANIFEST" <<'PY'
import sys, tomllib, shlex
with open(sys.argv[1], "rb") as f:
    m = tomllib.load(f)

def get(section, key, default=None, required=False):
    v = m.get(section, {}).get(key, default)
    if required and (v is None or v == ""):
        sys.stderr.write(f"company.toml: missing required [{section}].{key}\n"); sys.exit(2)
    return v

cid   = get("identity", "id", required=True)
name  = get("identity", "name", cid)
goal  = get("identity", "mission", required=True)
path  = get("stack", "path", required=True)
model = get("stack", "model", "glm-5.2")
maxit = get("policy", "max_iterations", 12)
budg  = get("policy", "budget_eur", None)
repo  = get("infra", "repo", "")
revenue_url = get("finance", "revenue_url", "")

# [soft] (SA1, lex-loom#178): declarative only -- a mesh node URL, this
# company's org identity on it (defaults to the company id), and which role
# kinds may register there once SA2 actually wires registration up. Nothing
# here dials out to soft; bootstrap only threads it through as env vars.
soft_mesh_url = get("soft", "mesh_url", "")
soft_org_id   = get("soft", "org_id", cid) if get("soft", "mesh_url", "") else ""
soft_roles_list = get("soft", "roles", [])
soft_roles    = ",".join(soft_roles_list) if isinstance(soft_roles_list, list) else str(soft_roles_list)
# SA3 (lex-loom#180): opt-in only -- "1" routes the per-iteration revenue
# signal through soft's evidence-gated settlement (src/soft_settlement.lex)
# instead of trusting the raw REVENUE_URL reading at face value; unset/false
# keeps today's behavior (revenue_url stays the data source either way).
soft_settlement = "1" if get("soft", "settlement", False) else ""
# OA1 (lex-loom#182): declarative-and-reportable only -- a role kind ->
# lex-os grant preset override table (values must name one of
# manifests.lex's 5 presets: Design/Implementation/QA/Demo/Retro; an
# unrecognised name safely falls back to Demo). No enforcement change:
# cast.roster_grant_report reads this, the real proc_cmd mediation path
# (LEX_OS_ISOLATION) does not, until OA2.
policy_isolation_table = get("policy", "isolation", {})
policy_isolation = ",".join(f"{k}:{v}" for k, v in policy_isolation_table.items()) if isinstance(policy_isolation_table, dict) else ""

# ORG1 (lex-loom#216): reporting lines. [org] maps each role to its manager:
#   [org]
#   build = "eng_manager"
#   qa = "eng_manager"
#   eng_manager = "founder"
# Flattened to "child:parent,child:parent" for ORG_EDGES; run_company_cmd
# validates (cycles, unknown leaf roles) and REFUSES to start on a bad org.
org_table = m.get("org", {}) if isinstance(m.get("org", {}), dict) else {}
org_edges = ",".join(f"{child}:{parent}" for child, parent in org_table.items())

# ORG5 (lex-loom#220): [roles].packs names the optional role sets the
# company staffs (e.g. packs = ["finance", "content"]). Flattened to a CSV
# for ROLE_PACKS; run_company_cmd validates against the closed pack
# registry and REFUSES to start on an unknown pack.
roles_table = m.get("roles", {}) if isinstance(m.get("roles", {}), dict) else {}
role_packs = ",".join(str(x) for x in roles_table.get("packs", []) if str(x).strip())

# GOV2 (lex-loom#222): [budget.envelopes] declares per-scope spend caps in
# integer cents: total = 5000, "role:build" = 2000. Flattened to
# "scope:cents,..." for BUDGET_ENVELOPES; run_company_cmd validates and
# REFUSES to start on an invalid declaration.
budget_table = m.get("budget", {}) if isinstance(m.get("budget", {}), dict) else {}
envelopes_table = budget_table.get("envelopes", {}) if isinstance(budget_table.get("envelopes", {}), dict) else {}
budget_envelopes = ",".join(f"{k}:{v}" for k, v in envelopes_table.items())

out = {
    "CID": cid, "CNAME": name, "CGOAL": goal, "CPATH": path,
    "CMODEL": model, "CMAXIT": str(maxit), "CREPO": repo,
    "CBUDGET": "" if budg is None else str(budg),
    "CREVENUE_URL": revenue_url,
    "CSOFT_MESH_URL": soft_mesh_url, "CSOFT_ORG_ID": soft_org_id, "CSOFT_ROLES": soft_roles,
    "CSOFT_SETTLEMENT": soft_settlement,
    "CPOLICY_ISOLATION": policy_isolation,
    "CORG_EDGES": org_edges,
    "CROLE_PACKS": role_packs,
    "CBUDGET_ENVELOPES": budget_envelopes,
}
for k, v in out.items():
    print(f"{k}={shlex.quote(str(v))}")
PY
)"

# ── Warn if the mission names a Python package py_build can't actually use.
# Found live (pdfx company run, #107): a manifest's mission named
# `pdfplumber`, which was never on the Architect's own "AVAILABLE PYTHON
# PACKAGES" whitelist (roles.lex: stdlib/flask/fastapi/jinja2/markdown/pytest
# only — no pip/install step exists anywhere in the sandbox). py_build wrote
# code importing it for 4+ real, billed iterations before a real execution
# gate (not just py_compile, which never resolves imports) caught the
# ModuleNotFoundError. A heuristic word-boundary check here catches the
# exact real mistake for $0, before any spend happens. Warns, does not
# hard-fail -- a plain-English word match can false-positive on a valid
# manifest, and this should never block a real one.
python3 - "$CGOAL" <<'PY'
import re, sys
mission = sys.argv[1]
# Keep this curated list in sync with roles.lex's architect_system_prompt
# "AVAILABLE PYTHON PACKAGES" section if that list ever changes.
AVAILABLE = {"flask", "fastapi", "jinja2", "markdown", "pytest"}
COMMONLY_UNAVAILABLE = [
    "pdfplumber", "pandas", "numpy", "scipy", "pypdf2", "pypdf", "pillow",
    "opencv", "cv2", "torch", "tensorflow", "scikit-learn", "sklearn",
    "beautifulsoup4", "bs4", "lxml", "selenium", "requests",
]
hits = []
low = mission.lower()
for pkg in COMMONLY_UNAVAILABLE:
    if pkg in AVAILABLE:
        continue
    if re.search(r"\b" + re.escape(pkg) + r"\b", low):
        hits.append(pkg)
if hits:
    sys.stderr.write(
        "[bootstrap] WARNING: mission text mentions "
        + ", ".join(sorted(set(hits)))
        + " -- py_build's sandbox has NO pip/install step and can only use: "
        + ", ".join(sorted(AVAILABLE))
        + " (plus stdlib). If the mission needs one of these, either drop it "
        "for a stdlib-only approach or plan a Lex-side implementation instead. "
        "This is a heuristic word match, not a hard stop -- proceeding.\n"
    )
PY

# ── Validate the path is a vetted golden path (a skeleton must exist).
SKELETON="$LOOM_ROOT/paths/$CPATH"
if [ ! -d "$SKELETON" ]; then
  echo "company.toml: [stack].path='$CPATH' is not a vetted path (no $SKELETON/). Available:" >&2
  ls "$LOOM_ROOT/paths" 2>/dev/null | sed 's/^/  - /' >&2
  exit 2
fi

# ── Resolve the workspace (OUTSIDE the loom repo) and scaffold.
WS="${LOOM_WORKSPACE:-$HOME/loom-companies}"
DIR="$WS/$CID"
mkdir -p "$DIR"

# Lay down the skeleton ONLY into empty slots — never clobber existing product
# code (idempotent: re-bootstrapping a live company is safe).
copied=0
while IFS= read -r -d '' src; do
  rel="${src#"$SKELETON"/}"
  dest="$DIR/$rel"
  if [ ! -e "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    copied=$((copied + 1))
  fi
# Excludes generated junk (__pycache__, .pytest_cache, .DS_Store, node_modules)
# that could accidentally end up in a skeleton dir (e.g. from running its own
# tests directly) — a path skeleton must only ever contain hand-authored files.
done < <(find "$SKELETON" -type f \
  -not -path '*/__pycache__/*' -not -name '*.pyc' \
  -not -path '*/.pytest_cache/*' -not -name '.DS_Store' \
  -not -path '*/node_modules/*' -print0)

# ── Bootstrap-time install (#256): the ONE moment loom may run a package
# install. A path skeleton that needs third-party dependencies (rn-expo-web:
# npm ci) ships a `.loom-install` script; it runs here, once, in the
# scaffolded workspace — human-triggered and network-trusted at exactly the
# same level as the git init / gh repo create below. Sprint agents NEVER
# install anything (that invariant is unchanged and enforced by their
# tools); a `.loom-installed` marker makes re-bootstrapping a live company
# a no-op instead of a silent re-install. Refuse, don't downgrade: a failed
# install aborts the bootstrap loudly rather than leaving a half-usable
# workspace.
if [ -f "$DIR/.loom-install" ]; then
  if [ -f "$DIR/.loom-installed" ]; then
    echo "[bootstrap] .loom-installed marker present — skipping one-time install (delete the marker to force)"
  else
    echo "[bootstrap] running one-time bootstrap install (.loom-install)..."
    if (cd "$DIR" && bash .loom-install); then
      date -u +"%Y-%m-%dT%H:%M:%SZ" > "$DIR/.loom-installed"
      echo "[bootstrap] one-time install complete — .loom-installed marker written"
    else
      echo "[bootstrap] FATAL: .loom-install failed — refusing to continue with a half-installed workspace" >&2
      exit 2
    fi
  fi
fi

# The company keeps its own copy of the manifest + a generated README.
cp "$MANIFEST" "$DIR/company.toml"
if [ ! -e "$DIR/README.md" ]; then
  cat > "$DIR/README.md" <<EOF
# $CNAME

$CGOAL

**Stack:** \`$CPATH\`  ·  built by [lex-loom](https://github.com/alpibrusl/lex-loom).
Scaffolded from \`company.toml\` — see it for the full manifest.
EOF
fi

# Git: init locally; optionally create a private GitHub repo (declared-intent
# in infra.repo, only realized on explicit opt-in — outward-facing action).
if [ ! -d "$DIR/.git" ]; then
  git -C "$DIR" init -q
  git -C "$DIR" add -A
  git -C "$DIR" -c user.email=bootstrap@loom -c user.name=loom commit -qm "Scaffold $CID from company.toml ($CPATH path)" || true
fi
if [ "${GITHUB_PUBLISH:-}" = "1" ] && [ -n "$CREPO" ]; then
  echo "[bootstrap] GITHUB_PUBLISH=1 → gh repo create $CREPO (private)"
  gh repo create "${CREPO#github:}" --private --source "$DIR" --remote origin --push 2>&1 | sed 's/^/  /' || \
    echo "  (gh repo create failed or repo exists — continuing with local git)"
fi

# ── Map [policy] → run-company.sh env vars.
STOP_WHEN=""
[ -n "$CBUDGET" ] && STOP_WHEN="spend ge ${CBUDGET}.00"   # rough guard (cost is an estimate; EUR≈USD)

echo "[bootstrap] company='$CID' path='$CPATH' workspace='$DIR' (${copied} skeleton files laid down)"
echo "[bootstrap] policy → MAX_ITERATIONS=$CMAXIT STOP_WHEN='${STOP_WHEN:-<none>}' MODEL=$CMODEL"
if [ -n "$CSOFT_MESH_URL" ]; then
  echo "[bootstrap] soft → mesh_url=$CSOFT_MESH_URL org_id=$CSOFT_ORG_ID roles=${CSOFT_ROLES:-<none>} settlement=${CSOFT_SETTLEMENT:-off}"
fi
if [ -n "$CPOLICY_ISOLATION" ]; then
  echo "[bootstrap] policy.isolation → ${CPOLICY_ISOLATION} (reportable via cast.roster_grant_report; not yet enforced — OA2)"
fi

if [ "$NORUN" = "--no-run" ]; then
  echo "[bootstrap] --no-run: scaffold complete, not starting the company."
  echo "[bootstrap] to run:  LOOM_WORKSPACE='$WS' COMPANY_ID='$CID' MODEL='$CMODEL' MAX_ITERATIONS=$CMAXIT STOP_WHEN='$STOP_WHEN' DB_PATH='$DIR/company.db' GOAL=... ORG_EDGES='$CORG_EDGES' ROLE_PACKS='$CROLE_PACKS' BUDGET_ENVELOPES='$CBUDGET_ENVELOPES' bin/run-company.sh"
  exit 0
fi

# ── Hand off to the runtime (loom fills in features inside the skeleton).
export LOOM_WORKSPACE="$WS"
COMPANY_ID="$CID" MODEL="$CMODEL" MAX_ITERATIONS="$CMAXIT" STOP_WHEN="$STOP_WHEN" \
  DB_PATH="$DIR/company.db" GOAL="$CGOAL" REVENUE_URL="$CREVENUE_URL" \
  SOFT_MESH_URL="$CSOFT_MESH_URL" SOFT_ORG_ID="$CSOFT_ORG_ID" SOFT_ROLES="$CSOFT_ROLES" \
  SOFT_SETTLEMENT="$CSOFT_SETTLEMENT" POLICY_ISOLATION="$CPOLICY_ISOLATION" \
  ORG_EDGES="$CORG_EDGES" ROLE_PACKS="$CROLE_PACKS" BUDGET_ENVELOPES="$CBUDGET_ENVELOPES" \
  bin/run-company.sh
