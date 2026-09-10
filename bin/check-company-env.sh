#!/usr/bin/env bash
# check-company-env.sh — can this company actually run, before a token is spent?
#
# Every prerequisite loom needs is discovered at the moment it is missing, hours
# into a run, wearing an agent's name. A model endpoint that is not reachable
# looks like "empty output after retries". A missing pytest looks like QA
# failing its own suite. A stack path that does not exist scaffolds nothing and
# the build node is blamed for producing no files. Each of those cost a real
# 2.5-hour run to discover, and none of them is about the model.
#
# Deterministic, free, and makes no LLM call. Run it before bootstrap:
#
#   bin/check-company-env.sh <company.toml>
set -euo pipefail
cd "$(dirname "$0")/.."
TOML="${1:?usage: check-company-env.sh <company.toml>}"
[ -f "$TOML" ] || { echo "no such file: $TOML" >&2; exit 2; }

pass=0; fail=0; warn=0
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '  warn  %s\n' "$1"; warn=$((warn+1)); }

read -r CID CPATH CMODEL CPACKS < <(python3 - "$TOML" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f: d = tomllib.load(f)
g = lambda s,k,dflt="": (d.get(s) or {}).get(k, dflt)
packs = ",".join((d.get("roles") or {}).get("packs", []) ) or "core"
print(g("identity","id","-"), g("stack","path","-"), g("stack","model","-"), packs)
PY
)

echo "== can $CID run?"
echo

# --- the config itself -------------------------------------------------------
[ "$CID" != "-" ]    && ok "identity.id = $CID"       || bad "identity.id is required"
[ "$CMODEL" != "-" ] && ok "stack.model = $CMODEL"    || bad "stack.model is required"
if [ "$CPATH" = "-" ]; then
  bad "stack.path is required"
elif [ -d "paths/$CPATH" ]; then
  ok "stack.path = $CPATH (skeleton exists)"
else
  bad "stack.path '$CPATH' has no skeleton under paths/ — available: $(ls paths 2>/dev/null | tr '\n' ' ')"
fi

# --- the toolchain -----------------------------------------------------------
command -v lex >/dev/null && ok "lex on PATH ($(lex --version 2>&1 | head -1))" || bad "lex is not on PATH"
command -v git >/dev/null && ok "git on PATH" || bad "git is not on PATH"

case "$CPATH" in
  python-*)
    command -v python3 >/dev/null && ok "python3 on PATH" || bad "python3 is required by the $CPATH stack"
    if python3 -m pytest --version >/dev/null 2>&1; then
      ok "pytest importable (QA runs the real suite)"
    else
      bad "pytest is not installed — every py_qa node will fail its own suite and be blamed for it"
    fi ;;
  node-ts-api|nextjs|rn-expo-web|web-pwa)
    if command -v node >/dev/null; then
      if node -e 'require("node:module").stripTypeScriptTypes' >/dev/null 2>&1; then
        ok "node $(node --version) supports stripTypeScriptTypes"
      else
        bad "node $(node --version) lacks stripTypeScriptTypes — the ts_check gate cannot run (needs node >= 22)"
      fi
    else
      bad "node is required by the $CPATH stack"
    fi ;;
esac

# --- the model endpoint, the one that costs hours to discover ---------------
# The decision comes from the runtime itself (src/main.lex provider_cmd, the
# same roles.choose_provider every model call dispatches on), not from a
# shell mirror of it. The mirror is how #427 happened: this preflight said
# "LiteLLM serves the model" and the run went to Mistral, because the
# runtime's fall-through honoured an ambient MISTRAL_API_KEY the mirror did
# not know about. Whatever this section checks is now, by construction, the
# provider the run uses. The company's own model wins over the environment,
# exactly as run-company.sh passes it.
EFFECTS=approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,stream,time,vcs
PROVIDER_LINE="$(MODEL="$CMODEL" lex run --allow-effects "$EFFECTS" src/main.lex provider_cmd 2>/dev/null | grep '^provider=' | head -1 || true)"
if [ -z "$PROVIDER_LINE" ]; then
  bad "could not resolve the provider (lex run src/main.lex provider_cmd printed nothing)"
  PROVIDER=""; ENDPOINT=""
else
  PROVIDER="$(printf '%s' "$PROVIDER_LINE" | sed -n 's/^provider=\([^ ]*\).*/\1/p')"
  ENDPOINT="$(printf '%s' "$PROVIDER_LINE" | sed -n 's/.* endpoint=\([^ ]*\).*/\1/p')"
  if [ -n "${LOOM_PROVIDER:-}" ]; then
    ok "$PROVIDER_LINE (LOOM_PROVIDER=$LOOM_PROVIDER)"
  else
    ok "$PROVIDER_LINE (default; name another with LOOM_PROVIDER=ollama|opencode|mlx|vertex|anthropic|openai|google|mistral)"
  fi
fi

# A key check that only proves the variable is set: the vendor adapters
# authenticate on the first call, and a hand-rolled probe here would test a
# different call shape than lex-llm uses (which is how an earlier opencode
# probe reported 401 for a key that worked).
need_var() { # var-name provider
  eval "v=\${$1:-}"
  if [ -n "$(printf '%s' "${v:-}" | tr -d ' \n')" ]; then ok "$1 is set for LOOM_PROVIDER=$2"; else bad "LOOM_PROVIDER=$2 but $1 is unset — every call would fail on auth"; fi
}

case "$PROVIDER" in
  litellm|mlx)
    if curl -s -m 8 "$ENDPOINT/v1/models" -H "Authorization: Bearer ${LITELLM_API_KEY:-sk-1234}" >/dev/null 2>&1; then
      if curl -s -m 8 "$ENDPOINT/v1/models" -H "Authorization: Bearer ${LITELLM_API_KEY:-sk-1234}" 2>/dev/null | grep -q "\"$CMODEL\""; then
        # Serving the model is not the same as being usable. A proxy routing
        # ollama through the legacy `ollama/` prefix answers completions
        # perfectly and returns NO tool calls at all — and every build, QA and
        # launch node in loom is a tool-calling agent, so the run dies on step
        # limits with no hint of why. Measured: `ollama/` 0 tool calls,
        # `ollama_chat/` 1, same model, same request.
        TOOL_PROBE=$(curl -s -m 120 "$ENDPOINT/v1/chat/completions" \
          -H 'Content-Type: application/json' \
          -H "Authorization: Bearer ${LITELLM_API_KEY:-sk-1234}" \
          -d "{\"model\":\"$CMODEL\",\"max_tokens\":600,\"messages\":[{\"role\":\"user\",\"content\":\"Call the ping tool.\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"ping\",\"description\":\"ping\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}}]}" 2>/dev/null || true)
        if printf '%s' "$TOOL_PROBE" | grep -q '"tool_calls"'; then
          ok "$PROVIDER at $ENDPOINT serves '$CMODEL' and returns tool calls"
        else
          bad "$PROVIDER at $ENDPOINT serves '$CMODEL' but returned NO tool call — every build/QA/launch node is a tool-calling agent, so the run would burn its step budget and fail with no explanation. If this is an ollama route, use the ollama_chat/ prefix, not ollama/"
        fi
      else
        bad "$PROVIDER at $ENDPOINT is up but does not list '$CMODEL' — the run will fail on its first node"
      fi
    else
      bad "no $PROVIDER at $ENDPOINT — this is the provider the run would use and there is no silent fallback. Start it with:  bin/litellm-up.sh   …or name another with LOOM_PROVIDER=ollama|opencode|mlx|vertex|anthropic|openai|google|mistral"
    fi ;;
  ollama)
    if curl -sf -m 5 "$ENDPOINT/api/tags" >/dev/null 2>&1; then
      if curl -sf -m 5 "$ENDPOINT/api/tags" 2>/dev/null | grep -q "\"$CMODEL\""; then
        ok "ollama at $ENDPOINT serves '$CMODEL' (native adapter, no proxy)"
      else
        bad "ollama at $ENDPOINT is up but does not have '$CMODEL' — pull it first, or the run fails on its first node"
      fi
    else
      bad "no ollama at $ENDPOINT (LOOM_PROVIDER=ollama) — start it, or set OLLAMA_URL"
    fi ;;
  opencode)
    # Mirror run-company.sh exactly: with LOOM_PROVIDER=opencode it loads the
    # credentials file when the key is not already exported.
    OC_FROM_FILE=""
    if [ -z "${OPENCODE_API_KEY:-}" ] && [ -f "$HOME/.credentials/opencode/key" ]; then
      OPENCODE_API_KEY="$(tr -d '\n' < "$HOME/.credentials/opencode/key")"; OC_FROM_FILE=1
    fi
    if [ -z "$(printf '%s' "${OPENCODE_API_KEY:-}" | tr -d ' \n')" ]; then
      bad "LOOM_PROVIDER=opencode but no OPENCODE_API_KEY and no ~/.credentials/opencode/key"
    else
      OCB="${OPENCODE_BASE_URL:-https://opencode.ai/zen/v1}"
      OC_MODELS=$(curl -s -m 10 -H "Authorization: Bearer $OPENCODE_API_KEY" "$OCB/models" 2>/dev/null || true)
      # Only what /models can actually prove. It needs no auth, so it cannot
      # validate the key -- and lex-llm's opencode-go provider uses a different
      # call shape than a plain curl, so a hand-rolled auth probe here reports
      # 401 for a key that works. Claiming "the key is good" on that basis
      # would be the same lie this preflight exists to prevent.
      if [ -z "$OC_MODELS" ]; then
        bad "opencode at $OCB did not answer — the run cannot reach its provider"
      elif printf '%s' "$OC_MODELS" | grep -q "\"$CMODEL\""; then
        ok "opencode serves '$CMODEL'${OC_FROM_FILE:+ (key from ~/.credentials/opencode/key)}; the key itself is not exercised here"
      else
        bad "opencode does not serve '$CMODEL' — every call fails on the model id (this is what sent an ollama model id to opencode and produced HTTP 401 on every node)"
      fi
    fi ;;
  vertex)    need_var VERTEX_ACCESS_TOKEN vertex; need_var VERTEX_PROJECT vertex ;;
  anthropic) need_var ANTHROPIC_API_KEY anthropic ;;
  openai)    need_var OPENAI_API_KEY openai ;;
  google)    need_var GOOGLE_API_KEY google ;;
  mistral)   need_var MISTRAL_API_KEY mistral ;;
  "") : ;;
  *)  bad "provider '$PROVIDER' has no preflight — add one before trusting a run on it" ;;
esac

# --- the operator profile: which providers this machine can reach -----------
# company.toml says what to BUILD; the profile says what this machine can REACH.
# Without it, [infra].hosting is read by nothing — a company declaring "fly.io"
# silently gets no deploy — and every credential is merely assumed present.
PROFILE="${LOOM_PROFILE:-$HOME/.loom/profile.toml}"
if [ ! -f "$PROFILE" ]; then
  note "no operator profile at $PROFILE — provider choices and grants are undeclared (see examples/loom.profile.toml)"
else
  LOOM_ENV="${LOOM_ENV:-local}"
  read -r PHOST PVCS PMODEL PDEPLOY PPUB PHOSTENV EKIND EKNOWN EGATE EHOSTENV < <(python3 - "$PROFILE" "$LOOM_ENV" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f: d = tomllib.load(f)
pr = d.get("providers") or {}
g  = d.get("grants") or {}
envs = d.get("environments") or {}
want = sys.argv[2]
e = envs.get(want)
sel = lambda k, f, dflt="-": (pr.get(k) or {}).get(f, dflt)
print(sel("hosting","kind"), sel("vcs","kind"), sel("model","kind"),
      str(g.get("allow_real_deploy", False)).lower(),
      str(g.get("allow_publishing", False)).lower(),
      sel("hosting","host_env","-"),
      (e or {}).get("kind", "-"),
      "yes" if e is not None else ("none" if not envs else "no:" + ",".join(sorted(envs))),
      str((e or {}).get("requires_human_gate", False)).lower(),
      (e or {}).get("host_env", "-"))
PY
)
  ok "operator profile: $PROFILE"

  case "$PHOST" in
    hetzner) ok "hosting adapter '$PHOST' is supported"
             if [ "$PHOSTENV" != "-" ]; then
               eval "hv=\${$PHOSTENV:-}"
               [ -n "${hv:-}" ] && ok "$PHOSTENV is set" || note "$PHOSTENV is not set — deploy nodes cannot reach a host"
             fi ;;
    none|-)  note "no hosting adapter declared — deploy nodes cannot run" ;;
    *)       bad "hosting.kind '$PHOST' has no adapter (available: hetzner, none) — a company declaring it would silently never deploy" ;;
  esac
  case "$PVCS" in
    github|-|none) : ;;
    *) bad "vcs.kind '$PVCS' has no adapter (available: github, none)" ;;
  esac
  case "$PMODEL" in
    litellm|opencode|anthropic|openai|-) : ;;
    *) bad "model.kind '$PMODEL' has no adapter (available: litellm, opencode, anthropic, openai)" ;;
  esac

  # Which target this run may reach. `local` deploys nowhere: launch starts the
  # server on localhost and nothing leaves the machine. Today that choice is a
  # per-run LLM judgement, so the same company can deploy on one iteration and
  # not the next; naming an environment makes it declared instead.
  case "$EKNOWN" in
    yes)   ok "environment '$LOOM_ENV' (kind=$EKIND)" ;;
    none)  note "profile declares no [environments] — falling back to local-only behaviour" ;;
    no:*)  bad "LOOM_ENV='$LOOM_ENV' is not declared in the profile (declared: ${EKNOWN#no:})" ;;
  esac
  if [ "$EKNOWN" = "yes" ]; then
    case "$EKIND" in
      none) ok "'$LOOM_ENV' deploys nowhere — launch only, nothing leaves this machine" ;;
      hetzner)
        [ "$PDEPLOY" = "true" ] || bad "environment '$LOOM_ENV' targets hetzner but grants.allow_real_deploy is false — the deploy tool stays disarmed and the run would silently never deploy"
        if [ "$EHOSTENV" != "-" ]; then
          eval "ehv=\${$EHOSTENV:-}"
          [ -n "${ehv:-}" ] && ok "$EHOSTENV is set for '$LOOM_ENV'" || bad "environment '$LOOM_ENV' names $EHOSTENV, which is unset"
        fi
        [ "$EGATE" = "true" ] && ok "'$LOOM_ENV' requires a human gate before promotion" || note "'$LOOM_ENV' reaches a real host with no human gate declared" ;;
      *) bad "environment '$LOOM_ENV' has kind '$EKIND', which has no adapter (available: hetzner, none)" ;;
    esac
  fi

  # Grants are the operator's decision and are OFF unless declared here.
  [ "$PDEPLOY" = "true" ] && ok "grants.allow_real_deploy = true (deploy may reach a real server)" \
                          || note "grants.allow_real_deploy = false — deploy_hetzner stays disarmed"
  [ "$PPUB" = "true" ]    && ok "grants.allow_publishing = true (content_creator may publish for real)" \
                          || note "grants.allow_publishing = false — publish_content stays disarmed"
fi

# --- things that only matter if the company asks for them -------------------
# [infra].hosting in company.toml is read by NOTHING. The profile's
# providers.hosting.kind is what selects an adapter, and it is checked above.
if grep -q '^\s*hosting' "$TOML" 2>/dev/null && [ ! -f "${LOOM_PROFILE:-$HOME/.loom/profile.toml}" ]; then
  note "[infra].hosting is declared in company.toml but nothing reads it — declare providers.hosting.kind in an operator profile instead"
fi
case "$CPACKS" in
  *content*) [ -n "${PUBLISH_URL:-}" ] || note "the 'content' pack includes content_creator, whose publish_content tool is not permitted by its manifest — it will be stripped" ;;
esac

echo
printf '== %d ok, %d failed, %d warnings\n' "$pass" "$fail" "$warn"
if [ "$fail" -gt 0 ]; then
  echo "   Fix the failures first: each one costs a full run to discover otherwise."
  exit 1
fi
echo "   Ready: bin/bootstrap-company.sh $TOML"
