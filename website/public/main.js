// Shared page controls. Native app previews are implemented in demo.js.
(() => {
  const toast = document.getElementById("toast");
  let toastTimer;
  const notify = (message) => {
    if (!toast) return;
    toast.textContent = message;
    toast.classList.add("visible");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove("visible"), 2600);
  };
  const icon = (name) => `<svg aria-hidden="true"><use href="#i-${name}"/></svg>`;

  document.querySelectorAll("[data-copy]").forEach((button) => {
    let resetTimer;
    button.addEventListener("click", async () => {
      const text = button.dataset.copy;
      let copied = false;
      try {
        if (navigator.clipboard && window.isSecureContext) {
          try {
            await navigator.clipboard.writeText(text);
            copied = true;
          } catch { /* Older browsers can still copy a selected text field. */ }
        }
        if (!copied) {
          const field = document.createElement("textarea");
          field.value = text;
          field.style.cssText = "position:fixed;left:-9999px;top:0;";
          document.body.append(field);
          try {
            field.select();
            copied = document.execCommand("copy");
          } finally {
            field.remove();
            button.focus({ preventScroll: true });
          }
        }
        if (!copied) throw new Error("Clipboard unavailable");
        button.innerHTML = icon("check");
        notify("Command copied to clipboard");
        clearTimeout(resetTimer);
        resetTimer = setTimeout(() => { button.innerHTML = icon("copy"); }, 2000);
      } catch {
        notify("Copy unavailable — select and copy the command above.");
      }
    });
  });

  const toggle = document.querySelector(".menu-toggle");
  const nav = document.getElementById("main-nav");
  if (toggle && nav) {
    const closeMenu = () => {
      nav.classList.remove("is-open");
      toggle.setAttribute("aria-expanded", "false");
      toggle.setAttribute("aria-label", "Open navigation");
    };
    toggle.addEventListener("click", () => {
      const open = toggle.getAttribute("aria-expanded") !== "true";
      toggle.setAttribute("aria-expanded", String(open));
      toggle.setAttribute("aria-label", open ? "Close navigation" : "Open navigation");
      nav.classList.toggle("is-open", open);
    });
    nav.querySelectorAll("a").forEach((link) => link.addEventListener("click", closeMenu));
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && nav.classList.contains("is-open")) {
        closeMenu();
        toggle.focus();
      }
    });
    document.addEventListener("click", (event) => {
      if (!event.target.closest(".nav-wrap")) closeMenu();
    });
  }
  const header = document.querySelector(".site-header");
  if (header) {
    const updateHeader = () => header.classList.toggle("scrolled", window.scrollY > 20);
    window.addEventListener("scroll", updateHeader, { passive: true });
    updateHeader();
  }
  const year = document.getElementById("year");
  if (year) year.textContent = new Date().getFullYear();

  // The hero is a separate, read-only MCP illustration, not a live connection.
  const output = document.getElementById("terminal-output");
  const run = document.getElementById("run-demo");
  if (!output || !run) return;
  let agent = "Claude Code";
  let timers = [];
  const results = `<div class="terminal-log"><i class="status-dot"></i> tamio.list_hosts <span class="terminal-indent">3 connected</span></div><div class="terminal-log"><i class="status-dot"></i> tamio.get_metrics</div><div class="terminal-server-row"><span>web-01</span><span>● healthy</span><span>CPU 12%</span></div><div class="terminal-server-row"><span>web-02</span><span>● healthy</span><span>CPU 8%</span></div><div class="terminal-server-row"><span>db-01</span><span>● healthy</span><span>CPU 24%</span></div><div class="terminal-success">✓ All clear. Your servers are doing great.</div>`;
  const reset = () => {
    timers.forEach(clearTimeout);
    timers = [];
    output.innerHTML = results;
    run.disabled = false;
    run.innerHTML = "Run demo <span>↵</span>";
  };
  const tabs = [...document.querySelectorAll("[data-agent]")];
  tabs.forEach((button) => button.addEventListener("click", () => {
    agent = button.dataset.agent;
    tabs.forEach((tab) => {
      const selected = tab === button;
      tab.setAttribute("aria-selected", String(selected));
      tab.tabIndex = selected ? 0 : -1;
    });
    document.getElementById("hero-console").setAttribute("aria-labelledby", button.id);
    reset();
  }));
  document.querySelector(".agent-switch").addEventListener("keydown", (event) => {
    const current = tabs.indexOf(document.activeElement);
    if (current < 0) return;
    const next = event.key === "ArrowRight" ? (current + 1) % tabs.length
      : event.key === "ArrowLeft" ? (current - 1 + tabs.length) % tabs.length
      : event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : null;
    if (next === null) return;
    event.preventDefault();
    tabs[next].click();
    tabs[next].focus();
  });
  run.addEventListener("click", () => {
    timers.forEach(clearTimeout);
    run.disabled = true;
    run.textContent = "Running…";
    output.innerHTML = `<div class="terminal-log"><span class="terminal-loader">●</span> ${agent} is connecting to Tamio…</div><div class="terminal-indent">Local MCP · read-only health check</div>`;
    timers.push(setTimeout(() => {
      output.innerHTML = '<div class="terminal-log"><i class="status-dot"></i> tamio.list_hosts</div><div class="terminal-indent">Found web-01, web-02, db-01</div><div class="terminal-log"><span class="terminal-loader">●</span> tamio.get_metrics</div><div class="terminal-indent">Reading CPU, memory and disk…</div>';
    }, 650));
    timers.push(setTimeout(() => {
      output.innerHTML = results;
      run.disabled = false;
      run.innerHTML = "Replay demo <span>↵</span>";
    }, 1700));
  });
  reset();
})();
