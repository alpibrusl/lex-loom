import type { NextConfig } from "next";

// Standalone output is what makes this path launchable the loom way:
// `next build` emits .next/standalone/server.js, runnable with PLAIN node
// (PORT from the environment) and no node_modules at runtime — the same
// cheap launch story as every other path. The build script copies public/
// and .next/static in (standalone does not, by design). Do not remove this
// without rethinking the Dockerfile and the launch node.
const nextConfig: NextConfig = {
  output: "standalone",
};

export default nextConfig;
