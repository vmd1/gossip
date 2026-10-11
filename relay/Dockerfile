# syntax=docker/dockerfile:1

# Build from the repository root, because the image also carries the project website (site/):
#   docker build -f relay/Dockerfile -t gossip-relay .
FROM node:22-slim AS build
WORKDIR /app
COPY relay/package.json relay/package-lock.json* ./
RUN npm ci
COPY relay/tsconfig.json ./
COPY relay/src ./src
COPY relay/scripts ./scripts
RUN npm run build

FROM node:22-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY relay/package.json relay/package-lock.json* ./
RUN npm ci --omit=dev
COPY --from=build /app/dist ./dist
# The website, served by the relay at the root of its HTTP port (SITE_DIR).
COPY site ./site

# TLS termination (wss://) happens in front of this container (reverse proxy /
# platform load balancer). Set RELAY_ORIGIN to the public wss:// origin clients
# use; it is bound into every join signature. Set TRUSTED_PROXY=true only when
# the proxy overwrites X-Forwarded-For. See relay/README.md for every setting.
ENV PORT=8080
ENV RELAY_PATH=/connect
ENV RELAY_ORIGIN=wss://relay.example.invalid
ENV ABUSE_CONTACT=
ENV SITE_DIR=/app/site
EXPOSE 8080
USER node

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "dist/src/relay.js"]
