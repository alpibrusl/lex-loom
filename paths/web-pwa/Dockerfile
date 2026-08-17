# Vetted golden-path Dockerfile for web-pwa. Pre-supplied by the bootstrap so
# devops never has to improvise one. `COPY . .` copies whatever the build
# agents actually wrote (public/ shell included), so it can't drift out of
# sync with the real file layout. No npm install and no build step — the
# image is the pinned slim base plus the source: the cheap infra profile the
# golden-path bundle requires (#92).
FROM node:22-slim

WORKDIR /app

COPY . .

ENV PORT=8082
EXPOSE 8082

USER node

CMD ["node", "--experimental-strip-types", "app.ts"]
