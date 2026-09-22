import type { RelaySocketLike } from "../src/connectionManager.js";

/**
 * In-process fake WebSocket used to unit-test ConnectionManager without a
 * real network socket. Each MockSocket stands in for the server-side handle
 * of one client connection: tests call `.deliver()` to simulate the client
 * sending data, and assert against `.sent` to see what the server sent back
 * to that client.
 */
export class MockSocket implements RelaySocketLike {
  public readonly sent: Array<string | Buffer> = [];
  public closed = false;
  public closeCode: number | undefined;
  public closeReason: string | undefined;

  private messageListeners: Array<(data: Buffer, isBinary: boolean) => void> = [];
  private closeListeners: Array<() => void> = [];

  send(data: string | Buffer): void {
    this.sent.push(data);
  }

  close(code?: number, reason?: string): void {
    if (this.closed) return;
    this.closed = true;
    this.closeCode = code;
    this.closeReason = reason;
    for (const listener of this.closeListeners) listener();
  }

  on(event: "message", listener: (data: Buffer, isBinary: boolean) => void): void;
  on(event: "close", listener: () => void): void;
  on(event: "message" | "close", listener: (...args: never[]) => void): void {
    if (event === "message") {
      this.messageListeners.push(listener as (data: Buffer, isBinary: boolean) => void);
    } else {
      this.closeListeners.push(listener as () => void);
    }
  }

  /** Simulates the remote peer (real client) sending data to the server side. */
  deliver(data: Buffer, isBinary: boolean): void {
    for (const listener of this.messageListeners) listener(data, isBinary);
  }

  /** Simulates the last JSON control message this socket received (sent to it by the server). */
  lastJson(): Record<string, unknown> {
    const last = [...this.sent].reverse().find((m) => typeof m === "string");
    if (!last || typeof last !== "string") throw new Error("no JSON message sent yet");
    return JSON.parse(last);
  }

  jsonMessagesOfType(type: string): Record<string, unknown>[] {
    return this.sent
      .filter((m): m is string => typeof m === "string")
      .map((m) => JSON.parse(m))
      .filter((m) => m.type === type);
  }
}
