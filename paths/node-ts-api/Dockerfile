# Vetted golden-path Dockerfile for node-ts-api. Pre-supplied by the bootstrap
# so devops never has to improvise one. `COPY . .` copies whatever the build
# agents actually wrote, so it can't drift out of sync with the real file
# layout. No npm install and no build step — the path is node:* builtins
# only, run with Node's native type stripping — so the image is just the
# pinned slim base plus the source: the cheap infra profile the golden-path
# bundle requires (#92).
FROM node:22-slim

WORKDIR /app

COPY . .

ENV PORT=8082
EXPOSE 8082

USER node

CMD ["node", "--experimental-strip-types", "app.ts"]
