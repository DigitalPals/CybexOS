FROM node:24-bookworm-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6 AS build

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run build

FROM node:24-bookworm-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6 AS runtime

ENV NODE_ENV=production \
    PORT=3000 \
    WRANGLER_WRITE_LOGS=false

WORKDIR /app
RUN mkdir -p .wrangler && chown node:node .wrangler
# vinext traces server externals and emits its standalone Node server. Keep
# the Worker-compatible build in the build stage, and ship the runtime closure.
COPY --from=build --chown=node:node /app/dist/standalone/ ./

USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:3000/').then(r => { if (!r.ok) process.exit(1); }).catch(() => process.exit(1))"

CMD ["node", "server.js"]
