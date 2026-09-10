# The deploy plan gate (lex-iac)

`deploy_hetzner` used to rsync a project to `HETZNER_HOST` and run it. It
still does, but only after **lex-iac** has held what it is about to do
against the company's grant.

1. `bin/deploy_plan.py` writes the deploy as a Terraform-shaped plan under
   the provider `registry.terraform.io/alpibrusl/loom`: update the host,
   create the compose service, open the port, create a Caddy site when a
   domain is declared. Deterministic code, never model output.
2. `src/manifests.lex deploy_grant_json` is the grant: the deploy role's
   Implementation manifest plus `facets.infra` naming the verbs
   (`hetzner.host.update`, `docker.compose.create`, `host.port.create`,
   `caddy.site.create`), the provider, and the host. It never admits a
   delete or a replace. A company narrows or widens it with
   `[infra] iac_allow = [...]` in company.toml (env `LOOM_IAC_ALLOW`).
3. `bin/iac-gate.sh` runs `lex-iac check` and prints one line the tool keys
   on: `IAC_ADMITTED plan=<sha> head=<audit head>`, `IAC_REFUSED ...`, or
   `IAC_UNAVAILABLE` when lex-iac is not installed -- refused, never run
   unchecked. Plan, verdict and audit log land in `/tmp/loom-iac-<sprint>/`.
4. The deploy tool refuses on anything but `IAC_ADMITTED`; the refusal text
   is the tool's error, so the node is denied with the effect and wall named.

`grants.allow_real_deploy` is unchanged: real deploys stay off by default.
The gate runs before that switch is even consulted.

Next: the same grant passed to `lex-iac apply --box-rootfs` so the apply
itself runs inside a lex-os box ("one manifest, two enforcement points"),
and `checkable:deploy-admitted` on the software-delivery contract from the
audit head.
