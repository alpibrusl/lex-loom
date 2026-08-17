// Read by the company's own strategic planning (the Strategist agent between
// iterations), never by end users. Keep it returning a short, honest summary
// of REAL usage as the domain model grows.

export const dynamic = "force-dynamic";

export function GET(): Response {
  return Response.json({ summary: "no usage data yet" });
}
