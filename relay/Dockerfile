# syntax=docker/dockerfile:1

FROM node:22-slim AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:22-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY --from=build /app/dist ./dist

# TLS termination (wss://) is expected to happen in front of this
# container (reverse proxy / platform load balancer). Where and how to
# host this is an explicit deferred decision — see relay/README.md.
ENV PORT=8080
ENV RELAY_PATH=/connect
EXPOSE 8080

CMD ["node", "dist/relay.js"]
