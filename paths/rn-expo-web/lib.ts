// Small shared helpers for the node-ts-api skeleton. node:* builtins only.

import type http from "node:http";

// Minimal HTML escaping for user-supplied text rendered into /blog. The
// skeleton has no template engine (no npm install exists on this path), so
// this is the one place escaping lives — route every user string through it.
export function escapeHtml(s: string): string {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

// Read and parse a JSON request body; malformed or non-object JSON becomes
// an empty record so route handlers can validate fields uniformly instead
// of try/catching around every read.
export async function jsonBody(req: http.IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    chunks.push(chunk as Buffer);
  }
  try {
    const parsed: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
    if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
    return {};
  } catch {
    return {};
  }
}
