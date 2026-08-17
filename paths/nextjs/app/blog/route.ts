import { POSTS, escapeHtml } from "../../lib/posts";

export const dynamic = "force-dynamic";

export function GET(): Response {
  const headers = { "content-type": "text/html; charset=utf-8" };
  if (POSTS.length === 0) {
    return new Response("<h1>Blog</h1><p>No posts yet.</p>", { headers });
  }
  const parts = ["<h1>Blog</h1>"];
  for (const p of POSTS) {
    p.views += 1;
    parts.push(`<article><h2>${escapeHtml(p.title)}</h2><p>${escapeHtml(p.body)}</p></article>`);
  }
  return new Response(parts.join(""), { headers });
}
