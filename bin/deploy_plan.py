#!/usr/bin/env python3
"""Emit the deploy's plan, Terraform-plan-shaped, for lex-iac to gate.

    deploy_plan.py --host H --service S --port P [--domain D] [--release R] [--out plan.json]

loom's Hetzner deploy is rsync + docker on one host. Before it runs, what
it is about to do is written down as resource changes under the provider
`registry.terraform.io/alpibrusl/loom`, so `lex-iac check` can hold it
against the company's grant with the same mechanics it applies to a
Terraform plan: every effect named, creates needing their verb in the
grant, deletes and replaces of the host refused unless granted, the
provider's identity checked, the verdict on a hash-chained audit log.

The plan is deterministic code, never model output: the same inputs give
byte-identical JSON, so the gate is reasoning about what the tool will do,
not about what an agent said it would do.
"""
import argparse
import json
import re
import sys


def slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_") or "x"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--service", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--domain", default="")
    ap.add_argument("--release", default="")
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    prov = "registry.terraform.io/alpibrusl/loom"
    changes = [
        {"address": f"hetzner_host.{slug(a.host)}", "mode": "managed", "type": "hetzner_host", "name": slug(a.host), "provider_name": prov,
         "change": {"actions": ["update"], "before": {"host": a.host}, "after": {"host": a.host, "release": a.release}}},
        {"address": f"docker_compose.{slug(a.service)}", "mode": "managed", "type": "docker_compose", "name": slug(a.service), "provider_name": prov,
         "change": {"actions": ["create"], "before": None, "after": {"service": a.service, "host": a.host}}},
        {"address": f"host_port.p{a.port}", "mode": "managed", "type": "host_port", "name": f"p{a.port}", "provider_name": prov,
         "change": {"actions": ["create"], "before": None, "after": {"port": a.port, "host": a.host}}},
    ]
    if a.domain:
        changes.append({"address": f"caddy_site.{slug(a.domain)}", "mode": "managed", "type": "caddy_site", "name": slug(a.domain), "provider_name": prov,
                        "change": {"actions": ["create"], "before": None, "after": {"domain": a.domain, "upstream_port": a.port}}})
    plan = {"format_version": "1.2", "terraform_version": "loom-deploy", "resource_changes": changes}
    out = json.dumps(plan, indent=2, sort_keys=True) + "\n"
    if a.out:
        open(a.out, "w").write(out)
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
