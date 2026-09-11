#!/usr/bin/env python3
"""Check that a public form endpoint actually refuses abuse -- by abusing it.

A form endpoint is a spam relay and a dumping ground unless it decides
otherwise, and "we added a honeypot" is a claim until something fills it in.
This gate STARTS the product, sends it the four submissions that matter, and
requires the right answer to each:

  checkable:genuine-accepted   a plain, well-formed submission is accepted
                               (2xx, or a 3xx redirect to the success page)
  checkable:honeypot-refused   the same submission with the honeypot field
                               filled is refused (4xx)
  checkable:oversize-refused   a body over the size cap is refused (413/4xx)
  checkable:rate-limited       a burst of requests draws at least one 429

The first is not decoration: a filter that drops a real lead has failed the
product however many bots it stopped, so the genuine case is checked FIRST and
the gate fails if it is refused.

The build node declares how to drive its product in abuse-probe.json at the
workspace root:
  {"start": "python3 app.py", "port": 8093, "endpoint": "/f/probe",
   "health": "/healthz", "honeypot_field": "website",
   "fields": {"email": "probe@example.com", "message": "hello"},
   "burst": 60}
Only start/endpoint are required; the rest default as above. The product is
started in the workspace with PORT set, waited on, exercised, and killed --
process group and all -- whatever the outcome.

Prints `ABUSE_CONTROLS_VERIFIED <attrs met>` always, `ABUSE_CONTROLS_OK` on a
full pass (exit 0), otherwise exit 1 naming what failed.
"""
import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

DEFAULTS = {"port": 8093, "health": "/healthz", "honeypot_field": "website",
            "fields": {"email": "probe@example.com", "message": "hello from the abuse gate"},
            "burst": 60, "oversize_bytes": 2_000_000, "timeout_s": 20}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A 3xx is the product's answer, not an instruction to go elsewhere: a
    form backend's success is very often a 302 to a thanks page, and following
    it would score the redirect target instead of the submission."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(_NoRedirect)


def post(url: str, data: bytes, ctype="application/x-www-form-urlencoded") -> int:
    """HTTP status of a POST; 0 when the connection itself was refused or reset."""
    req = urllib.request.Request(url, data=data, method="POST", headers={"Content-Type": ctype})
    try:
        with OPENER.open(req, timeout=10) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0


def port_holder(port: int) -> str:
    try:
        return subprocess.run(["lsof", "-ti", f"tcp:{port}"], capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""


def wait_healthy(base: str, health: str, timeout_s: int) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(base + health, timeout=3) as r:
                if 200 <= r.status < 300:
                    return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    probe_path = root / "abuse-probe.json"
    if not probe_path.is_file():
        print("ABUSE_CONTROLS_VERIFIED")
        print("check_abuse_controls: no abuse-probe.json in the workspace. The build node declares how to start and drive its endpoint there.")
        return 1
    try:
        probe = {**DEFAULTS, **json.loads(probe_path.read_text())}
        start, endpoint = probe["start"], probe["endpoint"]
    except Exception as e:
        print("ABUSE_CONTROLS_VERIFIED")
        print(f"check_abuse_controls: abuse-probe.json is not usable ({e}); need at least start and endpoint")
        return 1

    port = int(probe["port"])
    if port in (8000, 8080):
        print("ABUSE_CONTROLS_VERIFIED")
        print("check_abuse_controls: ports 8000 and 8080 are permanently held on this host; pick another in abuse-probe.json")
        return 1
    holder = port_holder(port)
    if holder:
        print("ABUSE_CONTROLS_VERIFIED")
        print(f"check_abuse_controls: port {port} is already held by pid {holder}; the gate will not kill something it did not start")
        return 1

    env = {**os.environ, "PORT": str(port)}
    proc = subprocess.Popen(start, shell=True, cwd=str(root), env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    base = f"http://127.0.0.1:{port}"
    met, unmet = [], []
    try:
        if not wait_healthy(base, probe["health"], int(probe["timeout_s"])):
            print("ABUSE_CONTROLS_VERIFIED")
            print(f"check_abuse_controls: the product did not answer {probe['health']} on port {port} within {probe['timeout_s']}s after `{start}`")
            return 1
        url = base + endpoint
        fields = dict(probe["fields"])
        genuine = urllib.parse.urlencode(fields).encode()

        s = post(url, genuine)
        if 200 <= s < 400:
            met.append("checkable:genuine-accepted")
        else:
            unmet.append(("checkable:genuine-accepted", f"a plain well-formed submission got {s}; a filter that drops a real lead has failed the product"))

        s = post(url, urllib.parse.urlencode({**fields, probe["honeypot_field"]: "http://spam.example"}).encode())
        if 400 <= s < 500:
            met.append("checkable:honeypot-refused")
        else:
            unmet.append(("checkable:honeypot-refused", f"a submission with the honeypot field `{probe['honeypot_field']}` filled got {s}, not a refusal"))

        # A server may answer 413 without draining the body, so the client sees
        # a reset (status 0) rather than a code. That IS a refusal -- but only
        # if the server is still standing afterwards; a crash must not pass.
        big = urllib.parse.urlencode({**fields, "message": "x" * int(probe["oversize_bytes"])}).encode()
        s = post(url, big)
        still_up = wait_healthy(base, probe["health"], 5)
        if (400 <= s < 500 or s == 0) and still_up:
            met.append("checkable:oversize-refused")
        elif not still_up:
            unmet.append(("checkable:oversize-refused", f"a {len(big)}-byte body took the server down (status {s}, then {probe['health']} stopped answering)"))
        else:
            unmet.append(("checkable:oversize-refused", f"a {len(big)}-byte body got {s}, not a refusal"))

        codes = [post(url, genuine) for _ in range(int(probe["burst"]))]
        if 429 in codes:
            met.append("checkable:rate-limited")
        else:
            unmet.append(("checkable:rate-limited", f"{len(codes)} rapid submissions drew no 429 (statuses seen: {sorted(set(codes))})"))
    finally:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            proc.wait(timeout=5)
        except Exception:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except Exception:
                pass

    print("ABUSE_CONTROLS_VERIFIED " + " ".join(met))
    if unmet:
        print("check_abuse_controls: the endpoint does not refuse abuse the way it must:\n")
        for attr, why in unmet:
            print(f"  {attr}: {why}")
        return 1
    print("ABUSE_CONTROLS_OK " + " ".join(met))
    return 0


if __name__ == "__main__":
    sys.exit(main())
