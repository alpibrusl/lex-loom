// Skeleton test — proves the shell serves, the PWA wiring is intact
// (manifest + service worker referenced and served with the right content
// types), and the /loom/* surface matches every other path. Runs with:
//   node --experimental-strip-types --test tests/*.test.ts
// (node:test + node:assert only — no npm packages exist on this path).

import test from "node:test";
import assert from "node:assert";
import type http from "node:http";
import { createApp, POSTS } from "../app.ts";

async function withApp(run: (base: string) => Promise<void>): Promise<void> {
  POSTS.length = 0;
  const server: http.Server = createApp();
  await new Promise<void>((resolve) => server.listen(0, resolve));
  const addr = server.address();
  if (addr === null || typeof addr === "string") {
    throw new Error("server did not bind a port");
  }
  try {
    await run(`http://127.0.0.1:${addr.port}`);
  } finally {
    await new Promise<void>((resolve, reject) => server.close((e) => (e ? reject(e) : resolve())));
    POSTS.length = 0;
  }
}

test("health", async () => {
  await withApp(async (base) => {
    const resp = await fetch(`${base}/health`);
    assert.strictEqual(resp.status, 200);
    assert.deepStrictEqual(await resp.json(), { ok: true });
  });
});

test("shell serves and references the PWA pieces", async () => {
  await withApp(async (base) => {
    const resp = await fetch(`${base}/`);
    assert.strictEqual(resp.status, 200);
    assert.match(resp.headers.get("content-type") ?? "", /text\/html/);
    const html = await resp.text();
    assert.ok(html.includes('rel="manifest"'), "index.html must link the manifest");
    assert.ok(html.includes("/app.js"), "index.html must load the client script");
  });
});

test("manifest is valid JSON with install-required fields", async () => {
  await withApp(async (base) => {
    const resp = await fetch(`${base}/manifest.webmanifest`);
    assert.strictEqual(resp.status, 200);
    assert.match(resp.headers.get("content-type") ?? "", /application\/manifest\+json/);
    const manifest = (await resp.json()) as Record<string, unknown>;
    assert.ok(manifest["name"], "manifest needs a name");
    assert.strictEqual(manifest["display"], "standalone");
    assert.ok(Array.isArray(manifest["icons"]) && (manifest["icons"] as unknown[]).length > 0, "manifest needs icons");
  });
});

test("service worker serves and registers the shell cache", async () => {
  await withApp(async (base) => {
    const resp = await fetch(`${base}/sw.js`);
    assert.strictEqual(resp.status, 200);
    assert.match(resp.headers.get("content-type") ?? "", /text\/javascript/);
    const sw = await resp.text();
    assert.ok(sw.includes("caches.open"), "sw.js must cache the shell");
    const client = await (await fetch(`${base}/app.js`)).text();
    assert.ok(client.includes('serviceWorker.register("/sw.js")'), "app.js must register the worker");
  });
});

test("static traversal is refused", async () => {
  await withApp(async (base) => {
    const resp = await fetch(`${base}/..%2Fapp.ts`);
    assert.strictEqual(resp.status, 404);
  });
});

test("loom content publish, list, and blog parity", async () => {
  await withApp(async (base) => {
    const post = await fetch(`${base}/loom/content`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ title: "Launch post", body: "We shipped it." }),
    });
    assert.strictEqual(post.status, 201);
    const list = await fetch(`${base}/loom/content`);
    assert.deepStrictEqual(await list.json(), { posts: [{ title: "Launch post", views: 0 }] });
    const blog = await fetch(`${base}/blog`);
    assert.ok((await blog.text()).includes("Launch post"));
  });
});

test("loom usage and support surface", async () => {
  await withApp(async (base) => {
    const usage = (await (await fetch(`${base}/loom/usage`)).json()) as Record<string, unknown>;
    assert.ok("summary" in usage);
    assert.deepStrictEqual(await (await fetch(`${base}/loom/support`)).json(), { items: [] });
  });
});
