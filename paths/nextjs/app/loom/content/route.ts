// Real, self-hosted distribution — the Content Creator agent publishes here,
// /blog serves it to real visitors. Keep the routes and the
// {title, body, views} shape so loom's distribution signal works.

import { POSTS } from "../../../lib/posts";

export const dynamic = "force-dynamic";

export function GET(): Response {
  return Response.json({ posts: POSTS.map((p) => ({ title: p.title, views: p.views })) });
}

export async function POST(req: Request): Promise<Response> {
  let data: Record<string, unknown>;
  try {
    data = (await req.json()) as Record<string, unknown>;
  } catch {
    return Response.json({ error: "body must be JSON" }, { status: 400 });
  }
  const title = String(data["title"] ?? "").trim();
  const body = String(data["body"] ?? "").trim();
  if (!title || !body) {
    return Response.json({ error: "title and body are required" }, { status: 400 });
  }
  POSTS.push({ title, body, views: 0 });
  return Response.json({ ok: true, post_count: POSTS.length }, { status: 201 });
}
