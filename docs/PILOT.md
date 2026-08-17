# Running a loom pilot — and verifying a run you did not produce

This is the onboarding path for an external pilot (#68, Phase 3). The
claim being piloted is not "an agent did work" — it is **"verifiable
autonomous software delivery you don't have to trust"**: a loom run is a
record you can hand to someone else, and they can re-derive whether it is
what it claims to be, on their own machine, without trusting the
operator's bookkeeping.

## 60 seconds: see the whole property, offline

Prerequisites: the pinned `lex` toolchain on PATH (version in
`.github/workflows/ci.yml`; binaries at
<https://github.com/alpibrusl/lex-lang/releases>), `python3`, `bash`.

```sh
lex pkg install
bash demo/pilot-verify-roundtrip.sh
```

The demo plays both parties:

1. **The operator** runs a real 2-node sprint through the actual
   orchestrator (deterministic proc-executor agents — no LLM, no
   network, no API keys).
2. **The pilot** receives *only the DB file* and verifies it with an
   empty content store (`LEX_STORE_ROOT` pointed at a fresh directory —
   the "different machine" condition). All four layers re-derive green
   and signed `did:lex` attestations are minted with `verified:true`.
3. One artifact in the handed-over DB is **tampered** by a single
   phrase. The same verification now reports the hash mismatch, the
   verdict flips to `FAILED`, and the attestations are minted with
   `verified:false` — reputation only ever accrues from verified runs.

## What the verifier actually checks

`verify_sprint_cmd` (src/main.lex → src/verify.lex) re-derives four
layers from the record alone — every verdict is **recomputed, never
read back**:

| Layer | Question it answers | How |
|---|---|---|
| Integrity | Are the artifact bytes the ones the trail attested? | `sha256(content)` re-computed for every accepted artifact and compared to the content-addressed id the trail references |
| Grounded | Do grounded gates (`spec compiles` / `spec sh`) still pass? | The produced files are re-materialized and the real tool is re-run |
| Authority | Did every node act within the authority it was granted? | Node casts re-checked against the recorded `op_grant` set |
| Operations | Did every recorded operation stay inside the grant? | Operation events re-checked against the same grants |

A verified run mints one signed `did:lex` attestation per granted agent,
binding the four verdicts to that agent's portable identity. An
unverified run is still recorded — it just earns nothing.

## Verifying a run someone hands you

All you need is their DB file (and, if they mirror artifacts to a
content store, optionally that store — the verifier falls back to the
DB's own artifact table when the store has no copy):

```sh
LEX_STORE_ROOT="$(mktemp -d)" \
DB_PATH=/path/to/their.db SPRINT_ID=<company>/iter-<n> \
lex run --max-steps 0 \
  --allow-effects approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs \
  src/main.lex verify_sprint_cmd
```

Point `LEX_STORE_ROOT` at an empty directory on purpose: it forces every
artifact to be re-derived from the record you were actually handed,
rather than from any bytes already cached on your machine.

## Running your own company (the real thing)

The offline demo uses deterministic executors so the *verification*
property is checkable anywhere. A real company needs a model (local,
free: Ollama + the recommended model — see the README's "With Ollama"
section):

```sh
# Start from a manifest — copy examples/linksnap.company.toml, or let the
# /create-company skill interview you into one:
bin/bootstrap-company.sh examples/linksnap.company.toml
```

Companies live under `LOOM_WORKSPACE` (default `~/loom-companies`), one
directory per company with its own `company.db`. Every iteration writes
the same verifiable record the demo verifies —
`DB_PATH=$LOOM_WORKSPACE/<id>/company.db SPRINT_ID=<id>/iter-1` plugs
straight into the verification command above.

## The hosted verifier (POST a record, get verdicts)

`src/server/verify_api.lex` is the same verifier behind an HTTP surface —
one verifier, two transports (the service relays to the very
`verify_record_cmd` you'd run locally, so the two can never drift):

```sh
# host it (token-gated; LEX_STORE_ROOT MUST be an empty, dedicated dir
# so uploads are judged self-contained — it refuses to start without it):
VERIFY_API_TOKEN=<secret> LEX_STORE_ROOT=$(mktemp -d) \
lex run --max-steps 0 --allow-effects approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs \
  src/server/verify_api.lex serve_verify_api

# verify a record against it (body = raw base64 of the .db):
base64 -w0 their.db | curl -s -X POST \
  "http://host:9400/verify?sprint_id=<company>/iter-<n>" \
  -H "Authorization: Bearer <secret>" --data-binary @-
```

The grounded layer is **skipped by default and reported as skipped**:
re-running grounded gates executes build commands *from the upload* —
remote code execution by design — so a host enables
`VERIFY_RERUN_GROUNDED=1` only inside a sandbox it trusts (lex-os).
Integrity, authority, and operations always run; they only read the
record. `bash demo/hosted-verify-roundtrip.sh` proves the whole flow
offline, tampered-record refusal included.

## Honest limits (what this pilot is not yet)

- **The hosted verifier is self-hosted, not operated for you.** Anyone
  can run `verify_api.lex`; the project does not (yet) run a public
  instance. The trust anchor is unchanged either way: verdicts are
  *recomputed from the record*, not asserted by it, and the verifier is
  open source.
- **LLM outputs themselves are not re-derived.** Verification proves the
  recorded artifacts are intact, grounded gates still pass, and no agent
  exceeded its authority — it does not re-run model inference.
- The exit criterion for Phase 3 is a **named external pilot**: someone
  outside the project runs a company and independently verifies a result
  they did not produce. This kit is the packaged path to that; the pilot
  themselves is a person, not a feature.
