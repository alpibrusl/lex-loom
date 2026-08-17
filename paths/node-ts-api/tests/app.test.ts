// Skeleton test — proves the app boots and /health responds.
//
// Build agents extend this file with real feature tests; keeping a passing
// test from iteration zero means the `ts_qa` gate has something green to
// start from rather than an empty suite. Runs with:
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

test("loom usage", async () => {
  await withApp(async (base) => {
    const resp = await fetch(`${base}/loom/usage`);
    assert.strictEqual(resp.status, 200);
    const data = (await resp.json()) as Record<string, unknown>;
    assert.ok("summary" in data);
  });
});

test("loom content publish and list", async () => {
  await withApp(async (base) => {
    const post = await fetch(`${base}/loom/content`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ title: "Launch post", body: "We shipped it." }),
    });
    assert.strictEqual(post.status, 201);
    const list = await fetch(`${base}/loom/content`);
    assert.strictEqual(list.status, 200);
    assert.deepStrictEqual(await list.json(), { posts: [{ title: "Launch post", views: 0 }] });
  });
});

test("loom content rejects missing fields", async () => {
  await withApp(async (base) => {
    const resp = await fetch(`${base}/loom/content`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ title: "No body" }),
    });
    assert.strictEqual(resp.status, 400);
  });
});

test("blog renders published posts and counts a view", async () => {
  await withApp(async (base) => {
    await fetch(`${base}/loom/content`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ title: "Hello", body: "World" }),
    });
    const blog = await fetch(`${base}/blog`);
    assert.strictEqual(blog.status, 200);
    assert.ok((await blog.text()).includes("Hello"));
    const stats = (await (await fetch(`${base}/loom/content`)).json()) as { posts: { views: number }[] };
    assert.strictEqual(stats.posts[0].views, 1);
  });
});

test("loom support starts empty", async () => {
  await withApp(async (base) => {
    const resp = await fetch(`${base}/loom/support`);
    assert.strictEqual(resp.status, 200);
    assert.deepStrictEqual(await resp.json(), { items: [] });
  });
});
