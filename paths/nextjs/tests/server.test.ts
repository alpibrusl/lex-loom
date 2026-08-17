// Skeleton test — boots the BUILT standalone server (run `npm run build`
// first; the bootstrap demo does) and proves the /health + /loom/* surface
// and blog parity over real HTTP. node:* builtins only:
//   node --test tests/
// (package.json's `npm test` runs exactly that.)

import test from "node:test";
import assert from "node:assert";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const ROOT = path.join(import.meta.dirname, "..");
const SERVER = path.join(ROOT, ".next", "standalone", "server.js");
const PORT = 8183;
const BASE = `http://127.0.0.1:${PORT}`;

async function waitForHealth(): Promise<void> {
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(`${BASE}/health`);
      if (r.ok) return;
    } catch {
      // not up yet
    }
    await new Promise((res) => setTimeout(res, 250));
  }
  throw new Error("standalone server never answered /health");
}

test("standalone surface: health, content publish/list, blog parity, usage, support", async () => {
  assert.ok(
    fs.existsSync(SERVER),
    "no .next/standalone/server.js — run `npm run build` before `npm test` (the bootstrap demo does)",
  );
  const child: ChildProcess = spawn("node", [SERVER], {
    env: { ...process.env, PORT: String(PORT), HOSTNAME: "127.0.0.1" },
    stdio: "ignore",
  });
  try {
    await waitForHealth();
    assert.deepStrictEqual(await (await fetch(`${BASE}/health`)).json(), { ok: true });

    const post = await fetch(`${BASE}/loom/content`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ title: "Launch post", body: "We shipped it." }),
    });
    assert.strictEqual(post.status, 201);
    assert.deepStrictEqual(await (await fetch(`${BASE}/loom/content`)).json(), {
      posts: [{ title: "Launch post", views: 0 }],
    });
    assert.ok((await (await fetch(`${BASE}/blog`)).text()).includes("Launch post"));

    const usage = (await (await fetch(`${BASE}/loom/usage`)).json()) as Record<string, unknown>;
    assert.ok("summary" in usage);
    assert.deepStrictEqual(await (await fetch(`${BASE}/loom/support`)).json(), { items: [] });

    const bad = await fetch(`${BASE}/loom/content`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ title: "" }),
    });
    assert.strictEqual(bad.status, 400);
  } finally {
    child.kill();
  }
});
