// Application entry point — the golden-path skeleton for `web-pwa` (#92).
//
// An installable Progressive Web App on node:* builtins alone: node:http
// serves the static shell from ./public (index.html + manifest + service
// worker — the three pieces that make a browser offer "install"), plus the
// same /health and /loom/* surface every loom path carries. No npm install,
// no build step, no framework: the PWA is the €100-viable "mobile app" —
// installable from a URL, no app store, no store fee — and this skeleton is
// deliberately the simplest real one. Build agents EXTEND these files (app
// shell, styles, client logic in public/, API routes here) rather than
// inventing a fresh layout each sprint. Reads PORT from the environment so
// the loom `launch` node can boot it on any port.

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { escapeHtml, jsonBody } from "./lib.ts";

export interface Post {
  title: string;
  body: string;
  views: number;
}

// In-process store, deliberately the simplest thing that actually works for
// a single dev/demo server — build agents extend this into real persistence
// once the product needs it to survive a restart.
export const POSTS: Post[] = [];

const PUBLIC_DIR = path.join(path.dirname(new URL(import.meta.url).pathname), "public");

// Only types the shell actually ships; extend as the product grows. A file
// with an unlisted extension is served as octet-stream rather than guessed.
const CONTENT_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".webmanifest": "application/manifest+json",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
};

function sendJson(res: http.ServerResponse, status: number, payload: unknown): void {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(payload));
}

// Serve a file from public/ or fall through. Paths are resolved against
// PUBLIC_DIR and must stay inside it — a traversal request gets a 404, not
// a file.
function serveStatic(res: http.ServerResponse, urlPath: string): boolean {
  const rel = urlPath === "/" ? "index.html" : urlPath.replace(/^\/+/, "");
  const full = path.normalize(path.join(PUBLIC_DIR, rel));
  if (!full.startsWith(PUBLIC_DIR + path.sep) && full !== path.join(PUBLIC_DIR, "index.html")) {
    return false;
  }
  if (!fs.existsSync(full) || !fs.statSync(full).isFile()) {
    return false;
  }
  const type = CONTENT_TYPES[path.extname(full)] ?? "application/octet-stream";
  res.writeHead(200, { "content-type": type });
  res.end(fs.readFileSync(full));
  return true;
}

export function createApp(): http.Server {
  return http.createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    const route = `${req.method} ${url.pathname}`;

    if (route === "GET /health") {
      return sendJson(res, 200, { ok: true });
    }

    // Read by the company's own strategic planning (the Strategist agent
    // between iterations), never by end users. Keep it returning a short,
    // honest summary of REAL usage as the domain model grows.
    if (route === "GET /loom/usage") {
      return sendJson(res, 200, { summary: "no usage data yet" });
    }

    // Real, self-hosted distribution — the Content Creator agent publishes
    // here, /blog serves it to real visitors. Keep the routes and the
    // {title, body, views} shape so loom's distribution signal works.
    if (route === "POST /loom/content") {
      const data = await jsonBody(req);
      const title = String(data["title"] ?? "").trim();
      const body = String(data["body"] ?? "").trim();
      if (!title || !body) {
        return sendJson(res, 400, { error: "title and body are required" });
      }
      POSTS.push({ title, body, views: 0 });
      return sendJson(res, 201, { ok: true, post_count: POSTS.length });
    }
    if (route === "GET /loom/content") {
      return sendJson(res, 200, { posts: POSTS.map((p) => ({ title: p.title, views: p.views })) });
    }

    if (route === "GET /blog") {
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      if (POSTS.length === 0) {
        return res.end("<h1>Blog</h1><p>No posts yet.</p>");
      }
      const parts = ["<h1>Blog</h1>"];
      for (const p of POSTS) {
        p.views += 1;
        parts.push(`<article><h2>${escapeHtml(p.title)}</h2><p>${escapeHtml(p.body)}</p></article>`);
      }
      return res.end(parts.join(""));
    }

    // Read-only, by the CX agent (never end users) — {id, text, status}
    // items needing a human response once the product has real users.
    if (route === "GET /loom/support") {
      return sendJson(res, 200, { items: [] });
    }

    if (req.method === "GET" && serveStatic(res, url.pathname)) {
      return;
    }

    return sendJson(res, 404, { error: "not found" });
  });
}

const isMain = process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  const port = Number(process.env.PORT ?? 8082);
  createApp().listen(port, () => {
    console.log(`web-pwa listening on :${port}`);
  });
}
