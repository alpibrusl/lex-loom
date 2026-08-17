// Skeleton test — proves the server's /health and /loom/* surface without
// needing a build (dist/ may not exist yet; the API answers regardless).
// Runs OFFLINE with node:* builtins only:
//   node --experimental-strip-types --test tests/*.test.ts
// The React Native app itself is gated by the workspace `npm run build`
// (expo export), which needs the one-time bootstrap install.

import test from "node:test";
import assert from "node:assert";
import type http from "node:http";
import { createApp, POSTS } from "../server.ts";

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

test("static traversal is refused", async () => {
  await withApp(async (base) => {
    const resp = await fetch(`${base}/..%2Fserver.ts`);
    assert.strictEqual(resp.status, 404);
  });
});
