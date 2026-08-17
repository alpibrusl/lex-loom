// Production server — the golden-path skeleton for `rn-expo-web` (#256).
//
// Serves the Expo WEB export (dist/, produced by `npm run build`) plus the
// same /health and /loom/* surface every loom path carries. The server
// itself is node:* builtins only and runs with type stripping — the ONLY
// third-party code on this path is the React Native app, whose deps were
// installed once at company bootstrap (.loom-install) and are bundled into
// dist/ at build time. Reads PORT from the environment so the loom `launch`
// node can boot it on any port. Without a dist/ (build not yet run) the
// API surface still answers — only the static shell 404s.

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

const DIST_DIR = path.join(path.dirname(new URL(import.meta.url).pathname), "dist");

const CONTENT_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
};

function sendJson(res: http.ServerResponse, status: number, payload: unknown): void {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(payload));
}

// Serve a file from dist/ or fall through. Paths resolve against DIST_DIR
// and must stay inside it — a traversal request gets a 404, not a file.
function serveStatic(res: http.ServerResponse, urlPath: string): boolean {
  const rel = urlPath === "/" ? "index.html" : urlPath.replace(/^\/+/, "");
  const full = path.normalize(path.join(DIST_DIR, rel));
  if (!full.startsWith(DIST_DIR + path.sep) && full !== path.join(DIST_DIR, "index.html")) {
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
    console.log(`rn-expo-web listening on :${port}`);
  });
}
