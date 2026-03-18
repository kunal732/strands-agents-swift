const NAV = [
  {
    label: "Blog",
    items: [
      { title: "All Posts", href: "blog.html" },
    ],
  },
  {
    label: "Getting Started",
    items: [
      { title: "Installation", href: "getting-started.html" },
      { title: "Quick Start",  href: "getting-started.html#quickstart" },
    ],
  },
  {
    label: "Concepts",
    items: [
      { title: "Agents",             href: "agents.html" },
      { title: "Tools",              href: "tools.html" },
      { title: "Structured Output",  href: "structured-output.html" },
      { title: "Streaming",          href: "streaming.html" },
      { title: "Local Inference",    href: "local-inference.html" },
      { title: "Hybrid Routing",     href: "local-inference.html#hybrid-routing", sub: true },
    ],
  },
  {
    label: "Multi-Agent",
    items: [
      { title: "Overview",              href: "multi-agent.html" },
      { title: "Graph",                 href: "multi-agent-graph.html",  sub: true },
      { title: "Swarm",                 href: "multi-agent-swarm.html",  sub: true },
      { title: "Agent-to-Agent (A2A)",  href: "multi-agent-a2a.html",   sub: true },
    ],
  },
  {
    label: "Voice Agents",
    items: [
      { title: "Cloud Backends", href: "voice-agents.html" },
      { title: "On-Device (MLX)", href: "voice-agents.html#local", sub: true },
    ],
  },
  {
    label: "Model Providers",
    items: [
      { title: "Overview",       href: "providers.html" },
      { title: "AWS Bedrock",    href: "providers.html#bedrock",    sub: true },
      { title: "Anthropic",      href: "providers.html#anthropic",  sub: true },
      { title: "OpenAI",         href: "providers.html#openai",     sub: true },
      { title: "Google Gemini",  href: "providers.html#gemini",     sub: true },
      { title: "MLX (Local)",    href: "providers.html#mlx",        sub: true },
    ],
  },
  {
    label: "Reference",
    items: [
      { title: "Observability",        href: "observability.html" },
      { title: "API Key Safety",       href: "observability.html#api-key-safety", sub: true },
      { title: "Lambda Proxy",         href: "observability.html#lambda-proxy",   sub: true },
      { title: "DDOT Collector",       href: "observability.html#ddot-collector", sub: true },
      { title: "Session Persistence",  href: "session.html" },
      { title: "Modules",              href: "modules.html" },
    ],
  },
];

function buildHeader() {
  const header = document.querySelector("header");
  if (!header) return;
  header.innerHTML = `
    <button class="menu-toggle" onclick="document.getElementById('sidebar').classList.toggle('open')" aria-label="Toggle menu">☰</button>
    <a class="logo" href="index.html">
      <div class="logo-icon">S</div>
      <span>Strands Swift</span>
    </a>
    <span class="header-badge">Community</span>
    <nav>
      <a href="getting-started.html">Docs</a>
      <a href="modules.html">Modules</a>
      <a href="blog.html">Blog</a>
      <a class="gh" href="https://github.com/kunal732/strands-agents-swift" target="_blank">
        <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>
        GitHub
      </a>
    </nav>
  `;
}

function buildSidebar() {
  const sidebar = document.getElementById("sidebar");
  if (!sidebar) return;
  const current = window.location.pathname.split("/").pop() || "index.html";
  let html = "";
  for (const section of NAV) {
    html += `<div class="nav-section"><div class="nav-section-label">${section.label}</div>`;
    for (const item of section.items) {
      const page = item.href.split("#")[0];
      const active = page === current ? " active" : "";
      const sub = item.sub ? " sub" : "";
      html += `<a class="nav-item${sub}${active}" href="${item.href}">${item.title}</a>`;
    }
    html += `</div>`;
  }
  sidebar.innerHTML = html;
}

function buildTOC() {
  const toc = document.getElementById("toc");
  if (!toc) return;
  const headings = Array.from(document.querySelectorAll("article h2, article h3"));
  if (headings.length < 2) return;
  let html = `<div class="toc-label">On This Page</div><ul class="toc-list">`;
  for (const h of headings) {
    if (!h.id) {
      h.id = h.textContent.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
    }
    const isH3 = h.tagName === "H3";
    html += `<li><a href="#${h.id}" class="${isH3 ? "toc-h3" : ""}">${h.textContent}</a></li>`;
  }
  html += `</ul>`;
  toc.innerHTML = html;

  // Highlight active section on scroll
  const links = toc.querySelectorAll("a");
  const obs = new IntersectionObserver(entries => {
    for (const e of entries) {
      if (e.isIntersecting) {
        links.forEach(l => l.classList.remove("active"));
        const a = toc.querySelector(`a[href="#${e.target.id}"]`);
        if (a) a.classList.add("active");
      }
    }
  }, { rootMargin: "-20% 0px -70% 0px" });
  headings.forEach(h => obs.observe(h));
}

document.addEventListener("DOMContentLoaded", () => {
  buildHeader();
  buildSidebar();
  buildTOC();
  if (typeof hljs !== "undefined") hljs.highlightAll();
});
