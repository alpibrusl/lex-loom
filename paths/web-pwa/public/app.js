// Client shell logic — plain JS (browsers do not strip TypeScript types;
// keep TypeScript on the server side only). Registers the service worker
// (the second half of installability, with the manifest) and proves the
// API round-trip by loading published posts.

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js");
}

async function load() {
  const status = document.getElementById("status");
  try {
    const health = await (await fetch("/health")).json();
    status.textContent = health.ok ? "API is up." : "API answered, but not ok.";
  } catch {
    status.textContent = "offline — showing the cached shell.";
    return;
  }
  try {
    const data = await (await fetch("/loom/content")).json();
    if (Array.isArray(data.posts) && data.posts.length > 0) {
      const list = document.getElementById("post-list");
      list.textContent = "";
      for (const post of data.posts) {
        const li = document.createElement("li");
        li.textContent = `${post.title} (${post.views} views)`;
        list.appendChild(li);
      }
      document.getElementById("posts").hidden = false;
    }
  } catch {
    // posts are optional decoration for the shell; the health line already
    // told the user what state we're in
  }
}

load();
