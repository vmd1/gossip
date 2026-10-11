import { pathToFileURL } from "node:url";
import { loadConfig, type RelayConfig } from "./config.js";
import { Relay, type RelayOptions } from "./hub.js";
import { logger } from "./logger.js";

export { Relay, loadConfig };
export type { RelayConfig, RelayOptions };

export function createRelay(config: RelayConfig = loadConfig(), opts: RelayOptions = {}): Relay {
  return new Relay(config, opts);
}

async function main(): Promise<void> {
  const config = loadConfig();
  const relay = createRelay(config);
  if (!process.env.RELAY_ORIGIN) {
    logger.warn("config.relay_origin_default", { origin: config.relayOrigin });
  }
  await relay.start();
  logger.info("server.listening", { port: relay.port, path: config.path, powBits: config.powBits });
  // SIGUSR2 toggles the kill switch at runtime (see README).
  process.on("SIGUSR2", () => {
    relay.toggleKillSwitch();
  });
  const shutdown = () => {
    void relay.close().then(() => process.exit(0));
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

const isMainModule = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMainModule) {
  main().catch((err) => {
    logger.error("server.fatal", { message: (err as Error).message });
    process.exit(1);
  });
}
