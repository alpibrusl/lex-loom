#!/usr/bin/env bash
# prof1-operator-profile-roundtrip.sh — the operator layer, checked for real.
#
# company.toml was carrying two different kinds of decision: what to BUILD (per
# company) and what this machine can REACH (per operator). Seven example
# companies each restated the same Hetzner size and the same GitHub org, and
# every credential was merely assumed to be in the environment, declared
# nowhere. Worse, [infra].hosting is read by NOTHING — a company declaring
# "fly.io" silently got no deploy at all.
#
# The profile fixes that by naming an ADAPTER, and an unknown adapter must fail
# loudly rather than silently mean nothing. That is what this proves.
set -euo pipefail
cd "$(dirname "$0")/.."
W="$(mktemp -d "${TMPDIR:-/tmp}/loom-prof.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

P="$W/profile.toml"; cp examples/loom.profile.toml "$P"
TOML=examples/tzconvert.company.toml

# Capture rather than pipe. With `set -o pipefail`, piping the checker into grep
# folds its exit status into the match, so a content assertion fails whenever
# the checker happens to exit non-zero for an unrelated reason — which is
# exactly what the first version of this file did, and it reported three
# failures that had nothing to do with what it was testing.
says() { LOOM_PROFILE="$1" bash bin/check-company-env.sh "$TOML" 2>&1 || true; }

echo "== 1. a supported adapter is accepted"
case "$(says "$P")" in
  *"hosting adapter 'hetzner' is supported"*) ok "hetzner is recognised" ;;
  *) bad "the supported adapter was not recognised" ;;
esac

echo "== 2. an unknown adapter FAILS, rather than silently meaning nothing"
sed 's|^kind         = "hetzner"|kind         = "fly"|' examples/loom.profile.toml > "$W/fly.toml"
if LOOM_PROFILE="$W/fly.toml" bash bin/check-company-env.sh "$TOML" >/dev/null 2>&1; then
  bad "hosting.kind = fly was accepted — a company declaring it would never deploy and never be told"
else
  ok "an unknown hosting adapter is refused"
fi
sed 's|^kind      = "github"|kind      = "gitlab"|' examples/loom.profile.toml > "$W/gl.toml"
if LOOM_PROFILE="$W/gl.toml" bash bin/check-company-env.sh "$TOML" >/dev/null 2>&1; then
  bad "an unknown vcs adapter was accepted"
else
  ok "an unknown vcs adapter is refused"
fi

echo "== 3. grants are OFF unless the operator declares them"
case "$(says "$P")" in
  *"allow_real_deploy = false"*) ok "real deploy stays disarmed by default" ;;
  *) bad "deploy grant did not default to off" ;;
esac
sed 's|^allow_real_deploy = false|allow_real_deploy = true|' examples/loom.profile.toml > "$W/dep.toml"
case "$(says "$W/dep.toml")" in
  *"allow_real_deploy = true"*) ok "an operator can turn it on, in their own profile" ;;
  *) bad "the grant could not be enabled" ;;
esac

echo "== 4. the profile holds REFERENCES, never secrets"
if grep -qE '(token_env|host_env|base_url_env)' examples/loom.profile.toml; then
  ok "credentials are named by env var, not stored"
else
  bad "the example profile stopped using references"
fi
if grep -qiE '^[a-z_]*(token|secret|password|api_key) *=' examples/loom.profile.toml; then
  bad "the example profile contains something shaped like a secret VALUE"
else
  ok "no secret value appears in the profile"
fi

echo "== 5. a missing profile warns, and does not block"
case "$(says "$W/absent.toml")" in
  *"no operator profile at"*) ok "a missing profile is reported as a warning" ;;
  *) bad "a missing profile was not reported" ;;
esac

echo "== 6. environments: local is the default and deploys nowhere"
case "$(says "$P")" in
  *"deploys nowhere"*) ok "the default environment reaches nothing" ;;
  *) bad "the default environment was not local-only" ;;
esac

cat "$P" > "$W/prod.toml"
printf '\n[environments.prod]\nkind = "hetzner"\nhost_env = "HETZNER_PROD_HOST"\nrequires_human_gate = true\n' >> "$W/prod.toml"

echo "== 7. an undeclared environment is refused, not silently ignored"
if LOOM_ENV=staging LOOM_PROFILE="$W/prod.toml" bash bin/check-company-env.sh "$TOML" >/dev/null 2>&1; then
  bad "LOOM_ENV=staging was accepted although the profile never declares it"
else
  ok "an undeclared environment is refused"
fi

echo "== 8. reaching a real host requires the operator's grant"
if LOOM_ENV=prod LOOM_PROFILE="$W/prod.toml" bash bin/check-company-env.sh "$TOML" >/dev/null 2>&1; then
  bad "prod targeted hetzner while allow_real_deploy was false — the run would silently never deploy"
else
  ok "a real target with the grant off is refused"
fi

printf '\n== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
