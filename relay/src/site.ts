import { createHash } from "node:crypto";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { extname, join } from "node:path";
import type { IncomingMessage, ServerResponse } from "node:http";

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".svg": "image/svg+xml",
  ".mp4": "video/mp4",
  ".ico": "image/x-icon",
  ".txt": "text/plain; charset=utf-8",
  ".webmanifest": "application/manifest+json",
};

/** The site loads no scripts, fonts, frames or third-party resources, so the policy can be this tight. */
const SECURITY_HEADERS = {
  "content-security-policy": "default-src 'none'; img-src 'self'; media-src 'self'; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
};

const MAX_FILES = 200;
const MAX_TOTAL_BYTES = 20 * 1024 * 1024;

interface Asset {
  body: Buffer;
  type: string;
  etag: string;
}

/**
 * The static project site served at the root of the relay. Every file is read into memory once at startup and looked
 * up by exact URL path, so a request can never reach anything on disk that was not listed then (no path joining, no
 * traversal) and serving costs no file system access.
 */
export class Site {
  private readonly assets = new Map<string, Asset>();

  constructor(dir: string) {
    let total = 0;
    const walk = (rel: string): void => {
      for (const name of readdirSync(join(dir, rel)).sort()) {
        if (name.startsWith(".")) continue;
        const relPath = rel ? `${rel}/${name}` : name;
        const full = join(dir, relPath);
        const st = statSync(full);
        if (st.isDirectory()) {
          walk(relPath);
          continue;
        }
        const type = TYPES[extname(name).toLowerCase()];
        if (!st.isFile() || !type) continue;
        total += st.size;
        if (this.assets.size >= MAX_FILES || total > MAX_TOTAL_BYTES) throw new Error(`site directory too large: ${dir}`);
        const body = readFileSync(full);
        this.assets.set("/" + relPath, { body, type, etag: `"${createHash("sha256").update(body).digest("hex").slice(0, 16)}"` });
      }
    };
    walk("");
    const index = this.assets.get("/index.html");
    if (!index) throw new Error(`site directory has no index.html: ${dir}`);
    this.assets.set("/", index);
  }

  get size(): number {
    return this.assets.size;
  }

  /** Answers GET and HEAD for a known file; returns false (so the caller sends its 404) for anything else. */
  handle(req: IncomingMessage, res: ServerResponse, url: string): boolean {
    if (req.method !== "GET" && req.method !== "HEAD") return false;
    let path: string;
    try {
      path = decodeURIComponent(url);
    } catch {
      return false;
    }
    const asset = this.assets.get(path);
    if (!asset) return false;
    const headers = {
      ...SECURITY_HEADERS,
      "content-type": asset.type,
      "content-length": asset.body.length,
      etag: asset.etag,
      "accept-ranges": "bytes",
      // The page can change with a release; the icon and stylesheet are small. Revalidate cheaply.
      "cache-control": "public, max-age=300, must-revalidate",
    };
    if (req.headers["if-none-match"] === asset.etag) {
      res.writeHead(304, { etag: asset.etag, ...SECURITY_HEADERS });
      res.end();
      return true;
    }
    const range = req.headers.range === undefined ? null : parseRange(req.headers.range, asset.body.length);
    if (range === "unsatisfiable") {
      res.writeHead(416, { ...SECURITY_HEADERS, "content-range": `bytes */${asset.body.length}` });
      res.end();
      return true;
    }
    if (range) {
      // Safari will not play a video from a server that cannot answer byte ranges.
      const [start, end] = range;
      res.writeHead(206, { ...headers, "content-length": end - start + 1, "content-range": `bytes ${start}-${end}/${asset.body.length}` });
      res.end(req.method === "HEAD" ? undefined : asset.body.subarray(start, end + 1));
      return true;
    }
    res.writeHead(200, headers);
    res.end(req.method === "HEAD" ? undefined : asset.body);
    return true;
  }
}

/**
 * Parses a single `bytes=` range into inclusive offsets. Multi-range and malformed headers return null, so the whole
 * file is sent (which RFC 9110 allows); a well-formed range outside the file is "unsatisfiable".
 */
function parseRange(header: string, size: number): [number, number] | "unsatisfiable" | null {
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!m || (m[1] === "" && m[2] === "")) return null;
  let start: number, end: number;
  if (m[1] === "") {
    const suffix = Number(m[2]);
    if (suffix === 0) return "unsatisfiable";
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(m[1]);
    end = m[2] === "" ? size - 1 : Math.min(Number(m[2]), size - 1);
    if (m[2] !== "" && Number(m[2]) < start) return null;
  }
  if (start >= size) return "unsatisfiable";
  return [start, end];
}
