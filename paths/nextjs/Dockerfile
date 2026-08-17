# Vetted golden-path Dockerfile for nextjs (#256 weight class). Two stages:
# the builder re-runs the same install + build the bootstrap ran (npm ci
# from the committed lockfile, then next build with standalone output), and
# the runtime stage is node:22-slim plus the standalone server — no full
# node_modules ships, keeping the runtime profile cheap.
FROM node:22 AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run build

FROM node:22-slim
WORKDIR /app
COPY --from=builder /app/.next/standalone ./

ENV PORT=8083
EXPOSE 8083

USER node

CMD ["node", "server.js"]
