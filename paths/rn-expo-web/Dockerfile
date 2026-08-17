# Vetted golden-path Dockerfile for rn-expo-web (#256). Two stages: the
# builder re-runs the same install + export the bootstrap ran (npm ci from
# the committed lockfile, then expo export), and the runtime stage is just
# node:22-slim plus the exported dist/ and the builtins server — no
# node_modules ships in the final image, keeping the runtime profile as
# cheap as the no-install paths.
FROM node:22 AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npx expo export --platform web

FROM node:22-slim
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY server.ts lib.ts ./

ENV PORT=8082
EXPOSE 8082

USER node

CMD ["node", "--experimental-strip-types", "server.ts"]
