// In-process content store shared by the /loom/content, /blog, and landing
// routes. Deliberately the simplest thing that actually works for a single
// dev/demo server — build agents extend this into real persistence once the
// product needs it to survive a restart.

export interface Post {
  title: string;
  body: string;
  views: number;
}

export const POSTS: Post[] = [];

export function escapeHtml(s: string): string {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
