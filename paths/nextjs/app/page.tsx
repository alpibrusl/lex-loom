// Landing page — the golden-path skeleton for `nextjs` (#256 weight class).
//
// A server component: it reads the in-process content store directly at
// request time (force-dynamic), which is the point of choosing Next.js over
// the web-pwa path — real SSR. Build agents EXTEND this app; .tsx sources
// are stored by ts_check and gated by the sprint↔workspace bridge running
// the real `next build`, so keep the build green — it is the path's
// compile gate.

import { POSTS } from "../lib/posts";

export const dynamic = "force-dynamic";

export default function Home() {
  return (
    <main style={{ fontFamily: "system-ui, sans-serif", maxWidth: "40rem", margin: "4rem auto", padding: "0 1rem" }}>
      <h1>nextjs</h1>
      <p>
        A Next.js app scaffolded by lex-loom&apos;s bootstrap-install golden path: dependencies
        installed once at company bootstrap, server-rendered by the standalone output, gated
        per sprint by the real <code>next build</code>.
      </p>
      <h2>Latest posts</h2>
      {POSTS.length === 0 ? (
        <p>No posts yet — the Content Creator publishes to /loom/content.</p>
      ) : (
        <ul>
          {POSTS.map((p) => (
            <li key={p.title}>
              {p.title} ({p.views} views)
            </li>
          ))}
        </ul>
      )}
    </main>
  );
}
