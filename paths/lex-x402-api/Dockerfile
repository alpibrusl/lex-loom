# Vetted golden-path Dockerfile for lex-x402-api. Pre-supplied by the
# bootstrap so devops never has to improvise one, same reasoning as
# python-fastapi's Dockerfile: `COPY . .` copies whatever the build agents
# actually wrote, so it can't drift out of sync with the real file layout.
FROM debian:bookworm-slim

# git is required by `lex pkg install` -- dependencies are fetched via git clone.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

# Architecture-aware: Cloud Run/Hetzner are amd64, but a local build on
# Apple Silicon (or an arm64 host) needs the aarch64 asset -- lex-lang
# publishes both.
ARG LEX_VERSION=0.10.5
RUN ARCH="$(dpkg --print-architecture)"; \
    if [ "$ARCH" = "arm64" ]; then LEX_TARGET=aarch64-unknown-linux-gnu; else LEX_TARGET=x86_64-unknown-linux-gnu; fi; \
    curl -fsSL "https://github.com/alpibrusl/lex-lang/releases/download/v${LEX_VERSION}/lex-v${LEX_VERSION}-${LEX_TARGET}.tar.gz" -o /tmp/lex.tgz \
    && tar -xzf /tmp/lex.tgz -C /usr/local \
    && ln -s "/usr/local/lex-v${LEX_VERSION}-${LEX_TARGET}/lex" /usr/local/bin/lex \
    && rm /tmp/lex.tgz

WORKDIR /app

COPY lex.toml .
RUN lex pkg install

COPY . .

ENV PORT=8080
EXPOSE 8080

CMD ["lex", "run", "--allow-effects", "env,net", "main.lex", "main"]
