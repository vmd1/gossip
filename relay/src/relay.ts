import { createServer } from "node:http";
import { WebSocketServer } from "ws";
import { ConnectionManager } from "./connectionManager.js";
import { logger } from "./logger.js";

const PORT = Number(process.env.PORT ?? 8080);
const PATH = process.env.RELAY_PATH ?? "/connect";

/**
 * Plain `ws://` over plain HTTP in dev. Production deployment should
 * terminate TLS (`wss://`) in front of this process (e.g. a reverse proxy
 * or a platform-managed load balancer) — see relay/README.md. Certificate
 * management is explicitly out of scope for this unit.
 */
export function createRelayServer() {
  const httpServer = createServer((req, res) => {
    if (req.url === "/healthz") {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end("ok");
      return;
    }
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found");
  });

  const wss = new WebSocketServer({ server: httpServer, path: PATH });
  const manager = new ConnectionManager();

  wss.on("connection", (ws) => {
    manager.registerConnection(ws);
  });

  wss.on("error", (err) => {
    logger.error("server.error", { message: err.message });
  });

  return { httpServer, wss, manager };
}

function main(): void {
  const { httpServer } = createRelayServer();
  httpServer.listen(PORT, () => {
    logger.info("server.listening", { port: PORT, path: PATH });
  });
}

const isMainModule = process.argv[1] && import.meta.url === `file://${process.argv[1]}`;
if (isMainModule) {
  main();
}
