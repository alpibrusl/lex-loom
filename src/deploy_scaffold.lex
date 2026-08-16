# deploy_scaffold.lex — deterministic TLS deploy scaffolding (#188).
#
# The principle: infrastructure is deterministic code, not agent output.
# The devops role may *narrate* a deploy plan for humans, but the bytes
# that actually reach the server come from these pure functions — same
# input, same file, every time, reviewable here rather than in a model
# transcript. deploy_hetzner (roles.lex) writes these into the work dir
# before rsync when DEPLOY_DOMAIN is set.
#
# The shape: one app container built from the project's own Dockerfile,
# fronted by Caddy, which terminates TLS with automatic Let's Encrypt
# certificates — no certbot choreography, no hand-managed renewals.
# Slice 1 assumes ONE service per box (Caddy binds 80/443 exclusively),
# matching the v1 single host:port deploy it upgrades. Multi-service
# routing on a shared box is a later slice.
#
# No secrets ever appear in generated files: compose builds from `.`,
# Caddy needs only the domain, and server credentials stay in the
# HETZNER_* environment of the *operator*, never in the artifact.

import "std.int" as int

import "std.str" as str

# docker-compose.yml for the app + Caddy pair. The app publishes its own
# port too (the legacy http://host:port path stays reachable for
# debugging); Caddy reaches the app over the compose network by service
# name, so the proxy works even if that publish is later dropped. The
# Caddy image is pinned to the 2.x major, never :latest.
fn compose_yaml(service_name :: Str, port :: Int) -> Str
  examples {
    compose_yaml("app", 8080) => "services:\n  app:\n    build: .\n    container_name: app\n    restart: unless-stopped\n    ports:\n      - \"8080:8080\"\n  caddy:\n    image: caddy:2\n    restart: unless-stopped\n    ports:\n      - \"80:80\"\n      - \"443:443\"\n    volumes:\n      - ./Caddyfile:/etc/caddy/Caddyfile:ro\n      - caddy_data:/data\n      - caddy_config:/config\nvolumes:\n  caddy_data:\n  caddy_config:\n"
  }
{
  let p := int.to_str(port)
  str.join(["services:", "  app:", "    build: .", str.concat("    container_name: ", service_name), "    restart: unless-stopped", "    ports:", str.join(["      - \"", p, ":", p, "\""], ""), "  caddy:", "    image: caddy:2", "    restart: unless-stopped", "    ports:", "      - \"80:80\"", "      - \"443:443\"", "    volumes:", "      - ./Caddyfile:/etc/caddy/Caddyfile:ro", "      - caddy_data:/data", "      - caddy_config:/config", "volumes:", "  caddy_data:", "  caddy_config:", ""], "\n")
}

# Caddyfile: the domain block proxies to the app service over the compose
# network. Naming a domain is what switches Caddy into automatic-HTTPS
# mode — certificates are provisioned and renewed by Caddy itself.
fn caddyfile(domain :: Str, port :: Int) -> Str
  examples {
    caddyfile("example.com", 8080) => "example.com {\n  reverse_proxy app:8080\n}\n"
  }
{
  str.join([str.concat(domain, " {"), str.join(["  reverse_proxy app:", int.to_str(port)], ""), "}", ""], "\n")
}

# The ONE url the health-check hits: the TLS front door when a domain is
# declared, the raw host:port otherwise. Checking https://domain proves
# the certificate actually provisioned — a green check through the raw
# port would say nothing about TLS.
fn health_url(domain :: Str, host :: Str, port :: Int, endpoint :: Str) -> Str
  examples {
    health_url("example.com", "203.0.113.7", 8080, "/health") => "https://example.com/health",
    health_url("", "203.0.113.7", 8080, "/health") => "http://203.0.113.7:8080/health"
  }
{
  if str.is_empty(domain) {
    str.join(["http://", host, ":", int.to_str(port), endpoint], "")
  } else {
    str.join(["https://", domain, endpoint], "")
  }
}

# The remote command for the compose path. `up -d --build` is idempotent:
# first deploy and redeploy are the same command, and compose only
# recreates containers whose inputs changed.
fn remote_up_command(remote_dir :: Str) -> Str
  examples {
    remote_up_command("/opt/loom-deploys/app") => "cd /opt/loom-deploys/app && docker compose up -d --build"
  }
{
  str.join(["cd ", remote_dir, " && docker compose up -d --build"], "")
}

# A shell fragment that writes `content` to `path` via a QUOTED heredoc —
# the single-quoted sentinel means the body is taken literally, so
# generated YAML/Caddyfile bytes survive with no shell expansion and no
# per-character escaping. Content is normalized to end with a newline so
# the sentinel always sits on its own line.
fn write_file_cmd(path :: Str, content :: Str) -> Str
  examples {
    write_file_cmd("/w/Caddyfile", "hi") => "cat > '/w/Caddyfile' <<'LOOM_SCAFFOLD_EOF'\nhi\nLOOM_SCAFFOLD_EOF\n"
  }
{
  let body := if str.ends_with(content, "\n") {
    content
  } else {
    str.concat(content, "\n")
  }
  str.join(["cat > '", path, "' <<'LOOM_SCAFFOLD_EOF'\n", body, "LOOM_SCAFFOLD_EOF\n"], "")
}

