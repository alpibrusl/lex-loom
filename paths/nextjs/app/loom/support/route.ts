// Read-only, by the CX agent (never end users) — {id, text, status} items
// needing a human response once the product has real users.

export const dynamic = "force-dynamic";

export function GET(): Response {
  return Response.json({ items: [] });
}
