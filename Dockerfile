FROM ubuntu:24.04

ARG LEX_VERSION=0.9.7

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install lex binary
RUN curl -fsSL \
    "https://github.com/alpibrusl/lex-lang/releases/download/v${LEX_VERSION}/lex-linux-x86_64" \
    -o /usr/local/bin/lex \
    && chmod +x /usr/local/bin/lex

WORKDIR /app
COPY . .

# Fetch all git deps declared in lex.toml
RUN lex pkg install

EXPOSE 8880

ENV PORT=8880 \
    DB_PATH=/data/loom.db \
    WEB_DIR=/app/src/web \
    OLLAMA_URL=http://ollama:11434

VOLUME ["/data"]

CMD ["lex", "run", \
     "--allow-effects", "env,net,io,llm,proc,sql,fs_read,fs_write,time,crypto,random,concurrent", \
     "src/web/server.lex", "serve_loom"]
