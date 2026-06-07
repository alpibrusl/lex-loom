FROM ubuntu:24.04

ARG LEX_VERSION=0.9.7

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git ca-certificates tar \
    && rm -rf /var/lib/apt/lists/*

# Install lex binary — detect arch at build time
RUN set -e; \
    ARCH=$(uname -m); \
    case "$ARCH" in \
      x86_64)  TRIPLE="x86_64-unknown-linux-gnu" ;; \
      aarch64) TRIPLE="aarch64-unknown-linux-gnu" ;; \
      *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac; \
    URL="https://github.com/alpibrusl/lex-lang/releases/download/v${LEX_VERSION}/lex-v${LEX_VERSION}-${TRIPLE}.tar.gz"; \
    curl -fsSL "$URL" -o /tmp/lex.tar.gz; \
    tar -xzf /tmp/lex.tar.gz -C /tmp; \
    mv /tmp/lex-v${LEX_VERSION}-${TRIPLE}/lex /usr/local/bin/lex; \
    chmod +x /usr/local/bin/lex; \
    rm /tmp/lex.tar.gz

WORKDIR /app
COPY . .

# Fetch all git deps — mount GitHub token as a secret so it's never baked into a layer
RUN --mount=type=secret,id=github_token \
    TOKEN=$(cat /run/secrets/github_token 2>/dev/null || true); \
    if [ -n "$TOKEN" ]; then \
      git config --global url."https://${TOKEN}@github.com/".insteadOf "https://github.com/"; \
    fi; \
    lex pkg install; \
    git config --global --unset-all 'url.https://github.com/.insteadof' 2>/dev/null || true

EXPOSE 8880

ENV PORT=8880 \
    DB_PATH=/data/loom.db \
    WEB_DIR=/app/src/web

VOLUME ["/data"]

CMD ["lex", "run", \
     "--allow-effects", "env,net,io,llm,proc,sql,fs_read,fs_write,time,crypto,random,concurrent", \
     "src/web/server.lex", "serve_loom"]
