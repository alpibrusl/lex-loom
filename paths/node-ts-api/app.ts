// Application entry point — the golden-path skeleton for `node-ts-api` (#92).
//
// The bootstrap lays this down so every company on this path starts from the
// SAME known-good structure: build agents EXTEND these files rather than
// inventing a fresh layout each sprint. Runs directly with
// `node --experimental-strip-types app.ts` — no npm install, no build step,
// node:* built-in modules ONLY (the sandbox has no package registry access,
// mirroring the Python path's no-pip rule). Reads PORT from the environment
// so the loom `launch` node can boot it on any port.

import http from "node:http";
import { pathToFileURL } from "node:url";
import { escapeHtml, jsonBody } from "./lib.ts";

export interface Post {
  title: string;
  body: string;
  views: number;
}

// In-process store, deliberately the simplest thing that actually works for
// a single dev/demo server (same scope as the rest of this skeleton) — build
// agents extend this into real persistence once the product needs it to
// survive a restart.
export const POSTS: Post[] = [];

function sendJson(res: http.ServerResponse, status: number, payload: unknown): void {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(payload));
}

function sendHtml(res: http.ServerResponse, status: number, html: string): void {
  res.writeHead(status, { "content-type": "text/html; charset=utf-8" });
  res.end(html);
}

export function createApp(): http.Server {
  return http.createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    const route = `${req.method} ${url.pathname}`;

    if (route === "GET /health") {
      return sendJson(res, 200, { ok: true });
    }

    // Read by the company's own strategic planning (the Strategist agent
    // between iterations), never by end users. As the product's domain model
    // grows, keep this returning a short, honest summary of REAL usage (row
    // counts, notable trends) so the company can steer itself on its own
    // data instead of flying blind between iterations. Build agents extend
    // this — do not leave it as the trivial stub past the first real feature.
    if (route === "GET /loom/usage") {
      return sendJson(res, 200, { summary: "no usage data yet" });
    }

    // Real, self-hosted distribution — no external platform, no API keys.
    // The Content Creator agent POSTs here to actually publish (not just
    // write prose nobody reads); /blog serves it to real visitors and the
    // sibling GET here is how loom measures whether anyone showed up. Build
    // agents may extend this with real templates/styling, but keep the two
    // routes and the {title, body, views} shape so loom's distribution
    // signal keeps working.
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
      if (POSTS.length === 0) {
        return sendHtml(res, 200, "<h1>Blog</h1><p>No posts yet.</p>");
      }
      const parts = ["<h1>Blog</h1>"];
      for (const p of POSTS) {
        p.views += 1;
        parts.push(`<article><h2>${escapeHtml(p.title)}</h2><p>${escapeHtml(p.body)}</p></article>`);
      }
      return sendHtml(res, 200, parts.join(""));
    }

    // Read-only, by the CX agent (never end users). Starts empty — the
    // product has no real users yet. As the domain model grows, build agents
    // extend this to surface REAL items needing a human response (support
    // requests, negative feedback, error reports — whatever this product's
    // domain actually generates), each as {id, text, status}. CX only ever
    // drafts replies from what's returned here; it never sends anything.
    if (route === "GET /loom/support") {
      return sendJson(res, 200, { items: [] });
    }

    return sendJson(res, 404, { error: "not found" });
  });
}

const isMain = process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  const port = Number(process.env.PORT ?? 8082);
  createApp().listen(port, () => {
    console.log(`node-ts-api listening on :${port}`);
  });
}
