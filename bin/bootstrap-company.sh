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

out = {
    "CID": cid, "CNAME": name, "CGOAL": goal, "CPATH": path,
    "CMODEL": model, "CMAXIT": str(maxit), "CREPO": repo,
    "CBUDGET": "" if budg is None else str(budg),
}
for k, v in out.items():
    print(f"{k}={shlex.quote(str(v))}")
PY
)"

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
done < <(find "$SKELETON" -type f -print0)

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

if [ "$NORUN" = "--no-run" ]; then
  echo "[bootstrap] --no-run: scaffold complete, not starting the company."
  echo "[bootstrap] to run:  LOOM_WORKSPACE='$WS' COMPANY_ID='$CID' MODEL='$CMODEL' MAX_ITERATIONS=$CMAXIT STOP_WHEN='$STOP_WHEN' DB_PATH='$DIR/company.db' GOAL=... bin/run-company.sh"
  exit 0
fi

# ── Hand off to the runtime (loom fills in features inside the skeleton).
export LOOM_WORKSPACE="$WS"
COMPANY_ID="$CID" MODEL="$CMODEL" MAX_ITERATIONS="$CMAXIT" STOP_WHEN="$STOP_WHEN" \
  DB_PATH="$DIR/company.db" GOAL="$CGOAL" \
  bin/run-company.sh
