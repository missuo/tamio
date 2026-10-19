// Tamio's window, the approval prompt and a server's Activity, drawn from
// data like the app draws them, and live: cards select, tabs switch, the
// readings move, the prompt answers.

(() => {
  "use strict";

  // Icons, drawn to SF Symbols' proportions.
  const icon = (d, size = 17, extra = "") =>
    `<svg aria-hidden="true" focusable="false" style="width:${size}px;height:${size}px" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" ${extra}>${d}</svg>`;
  const I = {
    home: icon('<path d="M3.5 11 12 4l8.5 7"/><path d="M5.5 9.5V20h4.5v-5.5h4V20h4.5V9.5"/>'),
    servers: icon('<rect x="3" y="4" width="18" height="7" rx="1.6"/><rect x="3" y="13" width="18" height="7" rx="1.6"/><path d="M7 7.5h.01M7 16.5h.01M11 7.5h6M11 16.5h6"/>'),
    identities: icon('<circle cx="10" cy="8" r="3.4"/><path d="M3.5 20c.6-3.6 3.2-5.6 6.5-5.6 1.3 0 2.5.3 3.4.9"/><circle cx="17.5" cy="15" r="1.8"/><path d="M17.5 16.8V21M17.5 19h1.6"/>'),
    snippets: icon('<path d="m8 7-5 5 5 5M16 7l5 5-5 5M14 4l-4 16"/>'),
    forward: icon('<path d="M4 8h14l-3.5-3.5M20 16H6l3.5 3.5"/>'),
    gear: icon('<circle cx="12" cy="12" r="3"/><path d="M12 2.8v2.4M12 18.8v2.4M2.8 12h2.4M18.8 12h2.4M5.5 5.5l1.7 1.7M16.8 16.8l1.7 1.7M5.5 18.5l1.7-1.7M16.8 7.2l1.7-1.7"/>'),
    search: icon('<circle cx="10.5" cy="10.5" r="6"/><path d="m15 15 5 5"/>', 15),
    terminal: icon('<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m7 10 3 2-3 2M12 15h4"/>', 14),
    close: icon('<path d="m6 6 12 12M18 6 6 18"/>', 13, 'stroke-width="2"'),
    list: icon('<path d="M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01"/>', 12, 'stroke-width="2.2"'),
    network: icon('<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.4 2.4 3.5 5.2 3.5 8.5s-1.1 6.1-3.5 8.5c-2.4-2.4-3.5-5.2-3.5-8.5S9.6 5.9 12 3.5Z"/>', 11),
    chevron: icon('<path d="m9 6 6 6-6 6"/>', 10, 'stroke-width="2.4"'),
  };
  const logos = {
    // Simple Icons (CC0), drawn small.
    ubuntu: '<svg aria-hidden="true" focusable="false" class="tw-logo" width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><path d="M12 0a12 12 0 1 0 0 24 12 12 0 0 0 0-24Zm3.6 4.3a1.7 1.7 0 1 1 1.7 2.9 1.7 1.7 0 0 1-1.7-2.9ZM4.7 13.7a1.7 1.7 0 1 1 0-3.4 1.7 1.7 0 0 1 0 3.4Zm.6 1.6a6.9 6.9 0 0 0 4.3 3.5 2.6 2.6 0 0 1 .6 2.6 9.5 9.5 0 0 1-6.6-5.3 2.6 2.6 0 0 1 1.7-.8Zm11.8 4.8a1.7 1.7 0 1 1-1.7-2.9 1.7 1.7 0 0 1 1.7 2.9Zm.6-2.6a2.6 2.6 0 0 0-2.6-.7 6.9 6.9 0 0 1-5.5.9 6.9 6.9 0 0 1-2.4-1.2 2.6 2.6 0 0 0 .1-2.7 6.9 6.9 0 0 1 0-4.4 2.6 2.6 0 0 0-.1-2.7 6.9 6.9 0 0 1 7.9-.3 2.6 2.6 0 0 0 2.6-.7 9.5 9.5 0 0 1 0 12Z"/></svg>',
    debian: '<svg aria-hidden="true" focusable="false" class="tw-logo" width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M14.5 21.2A9 9 0 1 1 20.6 9.5"/><path d="M12.6 16.6a4.6 4.6 0 1 1 4.5-5.7"/></svg>',
  };

  // The fleet: what a small team's servers read on an ordinary afternoon.
  const fleet = [
    { name: "web-01", os: "ubuntu", release: "Ubuntu 24.04", cpu: 34, mem: 62, cache: 14, disk: 41, cores: 8, up: "41d 6h", ram: 16, ip: "10.0.4.21", rx: 1.8, tx: 6.2 },
    { name: "web-02", os: "ubuntu", release: "Ubuntu 24.04", cpu: 29, mem: 58, cache: 12, disk: 39, cores: 8, up: "41d 6h", ram: 16, ip: "10.0.4.22", rx: 1.5, tx: 5.1 },
    { name: "api-01", os: "debian", release: "Debian 12", cpu: 47, mem: 71, cache: 9, disk: 55, cores: 16, up: "12d 3h", ram: 32, ip: "10.0.5.11", rx: 3.4, tx: 2.9 },
    { name: "db-primary", os: "ubuntu", release: "Ubuntu 22.04", cpu: 22, mem: 81, cache: 11, disk: 77, cores: 16, up: "88d 19h", ram: 64, ip: "10.0.6.2", rx: 0.9, tx: 1.2 },
    { name: "cache-01", os: "debian", release: "Debian 12", cpu: 12, mem: 46, cache: 30, disk: 18, cores: 4, up: "88d 19h", ram: 8, ip: "10.0.6.9", rx: 2.2, tx: 2.4 },
    { name: "staging-01", os: "ubuntu", release: "Ubuntu 24.04", cpu: 6, mem: 33, cache: 20, disk: 24, cores: 4, up: "3d 1h", ram: 8, ip: "10.0.9.4", rx: 0.1, tx: 0.2 },
  ];
  for (const s of fleet) s.history = Array.from({ length: 60 }, () => Math.max(2, s.cpu + (Math.random() - 0.5) * 22));

  const processes = {
    default: [["nginx: worker process", 8.4, 182], ["node /srv/app/server.js", 6.1, 412], ["postgres: checkpointer", 2.3, 96], ["dockerd", 1.6, 88], ["sshd: deploy [priv]", 0.4, 12], ["systemd-journald", 0.2, 64], ["cron", 0.0, 4]],
    "db-primary": [["postgres: writer", 9.2, 2140], ["postgres: walwriter", 3.1, 512], ["postgres: autovacuum", 2.6, 388], ["pgbouncer", 1.2, 38], ["node_exporter", 0.3, 22], ["sshd: deploy", 0.1, 9]],
  };
  const containers = {
    "api-01": [
      { name: "api", status: "Up 12 days (healthy)", cpu: 31, mem: "612MiB", block: "1.2GB / 340MB", net: "24GB / 31GB" },
      { name: "worker", status: "Up 12 days", cpu: 18, mem: "420MiB", block: "220MB / 1.1GB", net: "3.4GB / 2.1GB" },
      { name: "redis", status: "Up 12 days", cpu: 2, mem: "88MiB", block: "12MB / 640MB", net: "8.8GB / 9.2GB" },
    ],
  };
  const activity = {
    "web-01": [
      { title: "Install nginx", meta: "claude-code · MacBook Pro · 4 steps · last: exit 0 on 1", when: "2 min ago", open: true, steps: [
        ["add-apt-repository -y ppa:ondrej/nginx", "exit 0 on 1"],
        ["apt-get update", "exit 0 on 1"],
        ["apt-get install -y nginx", "exit 0 on 1"],
        ["systemctl enable --now nginx", "exit 0 on 1"],
      ] },
      { title: "Rotate nginx logs", meta: "codex · Mac Studio · reported", when: "Yesterday", steps: [["logrotate -f /etc/logrotate.d/nginx", "reported"]] },
    ],
  };

  const pct = (v) => Math.round(v);
  const usage = (v) => (v >= 90 ? "var(--tw-danger)" : v >= 75 ? "var(--tw-warning)" : "var(--tw-success)");
  const C = 2 * Math.PI * 18;

  function ring(value, cache = 0) {
    const used = Math.min(value, 100) / 100;
    const cached = Math.min(cache / 100, 1 - used);
    return `<span class="tw-ring">
      <svg aria-hidden="true" focusable="false" viewBox="0 0 40 40"><circle class="track" cx="20" cy="20" r="18" fill="none" stroke-width="4"/>
      <circle class="cache" cx="20" cy="20" r="18" fill="none" stroke-width="4" stroke-dasharray="${C}" stroke-dashoffset="${C * (1 - cached)}" transform="rotate(${used * 360} 20 20)"/>
      <circle class="fill" cx="20" cy="20" r="18" fill="none" stroke-width="4" stroke-linecap="round" stroke="${usage(value)}" stroke-dasharray="${C}" stroke-dashoffset="${C * (1 - used)}"/></svg>
      <span>${pct(value)}%</span></span>`;
  }

  // MARK: The window

  const views = ["overview", "processes", "containers", "activity"];
  let mountID = 0;

  function tabsMarkup(id) {
    return `<div class="tw-tabs" role="tablist" aria-label="Server details">${views.map((view) =>
      `<button type="button" id="${id}-${view}" role="tab" data-tab="${view}" aria-selected="false" aria-controls="${id}-pane" tabindex="-1">${view[0].toUpperCase() + view.slice(1)}</button>`
    ).join("")}</div>`;
  }

  function windowMarkup(id) {
    const side = (ic, title, badge = "", sel = false) =>
      `<div class="tw-row${sel ? " sel" : ""}"><span class="ic">${ic}</span>${title}${badge ? `<span class="badge">${badge}</span>` : ""}</div>`;
    return `
      <aside class="tw-side" aria-label="App sidebar preview">
        <div class="tw-side-top"><span class="tw-lights" aria-hidden="true"><i></i><i></i><i></i></span><span class="tw-preview-label">App preview</span></div>
        ${side(I.home, "Home", "", true)}
        <div class="tw-head">Manage</div>
        ${side(I.servers, "Servers", fleet.length)}
        ${side(I.identities, "Identities", 3)}
        ${side(I.snippets, "Snippets", 12)}
        ${side(I.forward, "Port Forward", 2)}
        <div class="tw-side-bottom">${side(I.gear, "Settings")}</div>
      </aside>
      <section class="tw-main" aria-label="Sample server fleet">
        <div class="tw-toolbar">
          <span class="tw-demo-label">Sample servers · interactive demo</span>
          <button type="button" class="tw-pause" aria-pressed="false">Pause readings</button>
          <label class="tw-search">${I.search}<input type="search" placeholder="Search servers" aria-label="Search sample servers" autocomplete="off" spellcheck="false"></label>
        </div>
        <div class="tw-body">
          <div class="tw-cards" role="group" aria-label="Choose a sample server"></div>
          <section class="tw-panel" aria-label="Selected server">
            <div class="tw-panel-head"><b class="tw-panel-name"></b><button type="button" class="tw-close" aria-label="Close server details">${I.close}</button></div>
            ${tabsMarkup(id)}
            <div class="tw-pane" id="${id}-pane" role="tabpanel" tabindex="0"></div>
          </section>
        </div>
      </section>`;
  }

  function cardContents(s) {
    return `<span class="tw-card-head"><span class="tw-dot"></span><span class="tw-name">${s.name.toUpperCase()}</span>
        <span class="tw-os" title="${s.release}">${logos[s.os]}${s.name.length > 7 ? "" : s.release}</span>
        <span class="tw-card-arrow">${I.chevron}</span></span>
      <span class="tw-slots">
        <span class="tw-slot">${ring(s.cpu)}<b>CPU</b></span>
        <span class="tw-slot">${ring(s.mem, s.cache)}<b>MEM</b></span>
        <span class="tw-slot">${ring(s.disk)}<b>DISK</b></span>
      </span>`;
  }

  function card(s) {
    return `<button type="button" class="tw-card" data-name="${s.name}" aria-label="${s.name}, ${s.release}. Show server details" aria-pressed="false" title="${s.name} · ${s.release}">${cardContents(s)}</button>`;
  }

  const fact = (label, value, unit = "", color = "") =>
    `<div class="tw-fact"${color ? ` style="--c:${color};--d:block"` : ""}><i>${label}</i><b>${value}</b>${unit ? `<small>${unit}</small>` : ""}</div>`;

  function overview(s) {
    const sys = s.cpu * 0.38, user = s.cpu * 0.55, wait = s.cpu * 0.05, nice = s.cpu * 0.02;
    const pills = s.history.slice(-56).map((v) => `<i class="${v > 75 ? "warm" : v > 1 ? "on" : ""}" style="height:${6 + Math.min(v, 100) / 100 * 14}px"></i>`).join("");
    const used = (s.ram * s.mem) / 100, cache = (s.ram * s.cache) / 100, free = Math.max(0.2, s.ram - used - cache);
    const diskSize = s.name === "db-primary" ? 1000 : s.name.startsWith("cache") ? 80 : 200;
    return `
      <div class="tw-osline">${logos[s.os]}${s.release} · up ${s.up}</div>
      <div class="tw-box">
        <div class="tw-facts"><div class="tw-big"><b>${pct(s.cpu)}</b><small> %</small></div>
          ${fact("Sys", pct(sys), "%", "var(--tw-danger)")}${fact("User", pct(user), "%", "var(--tw-success)")}${fact("IO wait", pct(wait), "%", "#a855f7")}${fact("Nice", pct(nice), "%", "#eab308")}</div>
        <div class="tw-pills">${pills}</div>
        <div class="tw-facts">${fact("Cores", s.cores)}${fact("Idle", pct(100 - s.cpu), "%")}${fact("Uptime", s.up)}${fact("Load", (s.cpu / 100 * s.cores).toFixed(2))}</div>
      </div>
      <div class="tw-box"><div class="tw-facts">
        ${fact("Free", free.toFixed(1), "GB")}${fact("Used", used.toFixed(1), "GB", "var(--tw-success)")}${fact("Cache", cache.toFixed(1), "GB", "var(--tw-ink-3)")}${ring(s.mem, s.cache)}</div></div>
      <div class="tw-box">
        <div class="tw-facts">${fact("↑/s", s.tx.toFixed(1), "MB/s")}${fact("↓/s", s.rx.toFixed(1), "MB/s")}${fact("TCP", "1.2K", "open")}</div>
        <div class="tw-hair"></div>
        <div class="tw-iface"><span style="color:var(--tw-success)">${I.network}</span><span>eth0</span><span>${s.ip}</span></div>
      </div>
      <div class="tw-box"><div class="tw-disk"><code>/</code>
        <div><b>${Math.round(diskSize * s.disk / 100)}G / ${diskSize}G</b><small>${pct(s.disk)}% used · ${Math.round(diskSize * (100 - s.disk) / 100)}G free</small></div>
        <div class="tw-fill"><i style="height:${Math.max(3, 34 * s.disk / 100)}px;background:${usage(s.disk)}"></i></div></div></div>`;
  }

  function processList(s) {
    const rows = (processes[s.name] || processes.default)
      .map(([cmd, cpu, mem]) => [cmd, Math.max(0, cpu + (Math.random() - 0.5) * cpu * 0.4), mem])
      .sort((a, b) => b[1] - a[1]);
    return `<div class="tw-table-head"><span>Process</span><span>CPU% ↓</span><span>Mem</span></div>` +
      rows.map(([cmd, cpu, mem]) => `<div class="tw-proc"><span>${cmd}</span><span>${cpu.toFixed(1)}</span><span>${mem >= 1024 ? (mem / 1024).toFixed(1) + " GB" : mem + " MB"}</span></div>`).join("");
  }

  function containerList(s) {
    const list = containers[s.name];
    if (!list) return `<div class="tw-box" style="align-items:center;text-align:center;padding:28px 12px"><b>No containers</b><span style="color:var(--tw-ink-2);font-size:12px">Docker isn't installed on this server.</span></div>`;
    return list.map((c) => `<div class="tw-container">
      <div class="tw-container-head"><b>${c.name}</b><small>${c.status}</small></div>
      <div class="tw-container-row">${ring(c.cpu)}${fact("Mem", c.mem)}${fact("Block R / W", c.block)}${fact("Net ↓ / ↑", c.net)}</div></div>`).join("");
  }

  function activityList(name, openEntries) {
    const list = activity[name];
    if (!list) return `<div class="tw-box tw-empty"><b>No agent activity</b><span>What agents run or change here, through Tamio or reported by them, shows here.</span></div>`;
    return list.map((e, i) => {
      const key = `${name}:${i}`;
      const open = openEntries.has(key) ? openEntries.get(key) : Boolean(e.open);
      return `<details class="tw-entry" data-entry="${key}"${open ? " open" : ""}>
        <summary><span class="tw-entry-head"><span style="color:var(--tw-accent)">${e.steps.length > 1 ? I.list : I.terminal}</span><b>${e.title}</b><small>${e.when}</small></span>
          <span class="tw-entry-meta">${e.meta}</span><span class="tw-more">${I.chevron}<span class="tw-entry-show">Show ${e.steps.length} ${e.steps.length === 1 ? "step" : "steps"}</span><span class="tw-entry-hide">Hide steps</span></span></summary>
        ${e.steps.map(([cmd, out], n) => `<div class="tw-step"><p>${n + 1}. Run on 1 server · ${out}</p><pre>$ ${cmd}</pre></div>`).join("")}
      </details>`;
    }).join("");
  }

  function panelContents(s, tab, openEntries) {
    return tab === "overview" ? overview(s) : tab === "processes" ? processList(s) : tab === "containers" ? containerList(s) : activityList(s.name, openEntries);
  }

  function syncTabs(root, id, tab) {
    root.querySelectorAll('[role="tab"]').forEach((button) => {
      const current = button.dataset.tab === tab;
      button.classList.toggle("sel", current);
      button.setAttribute("aria-selected", String(current));
      button.tabIndex = current ? 0 : -1;
    });
    root.querySelector('[role="tabpanel"]').setAttribute("aria-labelledby", `${id}-${tab}`);
  }

  function bindTabs(root, select) {
    const tablist = root.querySelector('[role="tablist"]');
    tablist.addEventListener("click", (event) => {
      const button = event.target.closest('[role="tab"]');
      if (button) select(button.dataset.tab);
    });
    tablist.addEventListener("keydown", (event) => {
      const buttons = Array.from(tablist.querySelectorAll('[role="tab"]'));
      const index = buttons.indexOf(event.target);
      if (index < 0 || !["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
      event.preventDefault();
      const next = event.key === "Home" ? 0 : event.key === "End" ? buttons.length - 1
        : (index + (event.key === "ArrowRight" ? 1 : -1) + buttons.length) % buttons.length;
      select(buttons[next].dataset.tab);
      buttons[next].focus();
    });
  }

  function trackEntries(pane, openEntries) {
    pane.addEventListener("toggle", (event) => {
      if (event.target.matches(".tw-entry")) openEntries.set(event.target.dataset.entry, event.target.open);
    }, true);
  }

  function mountWindow(frame) {
    const scale = frame.querySelector(".demo-scale");
    if (!scale) return;
    const id = `tamio-window-${++mountID}`;
    const tw = document.createElement("div");
    tw.className = "tw tw-theme";
    tw.setAttribute("role", "group");
    tw.setAttribute("aria-label", "Interactive Tamio preview with six sample servers");
    tw.innerHTML = windowMarkup(id);
    scale.appendChild(tw);

    const cards = tw.querySelector(".tw-cards");
    const pane = tw.querySelector(".tw-pane");
    const search = tw.querySelector(".tw-search input");
    const pause = tw.querySelector(".tw-pause");
    const openEntries = new Map();
    let selected = "web-01";
    let tab = "overview";
    let paused = false;
    let onscreen = true;
    cards.innerHTML = fleet.map(card).join("") + '<p class="tw-no-results" role="status" hidden>No sample servers match your search.</p>';

    // Keep each button mounted so a reading never takes keyboard focus away.
    const drawCards = () => {
      cards.style.setProperty("--cols", selected ? 2 : 3);
      const query = search.value.trim().toLowerCase();
      let shown = 0;
      fleet.forEach((s) => {
        const button = cards.querySelector(`[data-name="${s.name}"]`);
        button.classList.toggle("sel", s.name === selected);
        button.setAttribute("aria-pressed", String(s.name === selected));
        button.hidden = !`${s.name} ${s.release} ${s.ip}`.toLowerCase().includes(query);
        button.innerHTML = cardContents(s);
        if (!button.hidden) shown++;
      });
      cards.querySelector(".tw-no-results").hidden = shown > 0;
    };
    const drawPanel = () => {
      tw.classList.toggle("closed", !selected);
      if (!selected) return;
      const s = fleet.find((f) => f.name === selected);
      tw.querySelector(".tw-panel-name").textContent = s.name.toUpperCase();
      syncTabs(tw, id, tab);
      const scroll = pane.scrollTop;
      pane.innerHTML = panelContents(s, tab, openEntries);
      pane.scrollTop = scroll;
    };
    const draw = () => { drawCards(); drawPanel(); };

    cards.addEventListener("click", (event) => {
      const button = event.target.closest(".tw-card");
      if (!button || button.dataset.name === selected) return;
      selected = button.dataset.name;
      pane.scrollTop = 0;
      draw();
    });
    tw.querySelector(".tw-close").addEventListener("click", () => {
      const previous = selected;
      selected = null;
      draw();
      const button = cards.querySelector(`[data-name="${previous}"]`);
      (button && !button.hidden ? button : search).focus();
    });
    bindTabs(tw, (view) => {
      if (tab === view) return;
      tab = view;
      pane.scrollTop = 0;
      drawPanel();
    });
    trackEntries(pane, openEntries);
    search.addEventListener("input", drawCards);
    pause.addEventListener("click", () => {
      paused = !paused;
      pause.setAttribute("aria-pressed", String(paused));
      pause.textContent = paused ? "Resume readings" : "Pause readings";
    });

    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
    if ("IntersectionObserver" in window) {
      new IntersectionObserver(([entry]) => { onscreen = entry.isIntersecting; }).observe(frame);
    }
    // Match the native reading interval, but do no work for hidden previews.
    setInterval(() => {
      if (paused || reduce.matches || document.hidden || !onscreen || !frame.isConnected || !frame.getClientRects().length) return;
      for (const s of fleet) {
        s.cpu = Math.min(96, Math.max(2, s.cpu + (Math.random() - 0.5) * 9));
        s.mem = Math.min(95, Math.max(20, s.mem + (Math.random() - 0.5) * 1.2));
        s.rx = Math.max(0.05, s.rx * (0.85 + Math.random() * 0.3));
        s.tx = Math.max(0.05, s.tx * (0.85 + Math.random() * 0.3));
        s.history.push(s.cpu); s.history.shift();
      }
      drawCards();
      if (tab === "overview" || tab === "processes") drawPanel();
    }, 2000);

    // Desktop keeps the app's measurements; small screens use a readable layout.
    const fit = () => {
      if (window.matchMedia("(max-width: 680px)").matches) {
        scale.style.transform = "none";
        frame.style.height = "auto";
        return;
      }
      const k = Math.min(1, frame.clientWidth / 1180);
      scale.style.transform = `scale(${k})`;
      frame.style.height = `${720 * k}px`;
    };
    new ResizeObserver(fit).observe(frame);
    window.addEventListener("resize", fit);
    draw();
    fit();
  }

  // MARK: The approval prompt

  function mountAlert(stage) {
    const alert = document.createElement("div");
    alert.className = "tw-alert tw-theme";
    alert.setAttribute("role", "group");
    alert.setAttribute("aria-label", "Sample agent approval request");
    alert.innerHTML = `
      <img src="/icon-256.png" alt="">
      <h4>claude-code wants to: Run on 2 servers</h4>
      <p>For: Check server health</p>
      <p><code>uptime &amp;&amp; df -h /</code></p>
      <p>Servers: web-01, web-02</p>
      <div class="tw-alert-buttons">
        <button type="button" class="default" aria-pressed="false" data-answer="Allowed once. In Tamio, this runs and is recorded on both servers.">Allow</button>
        <button type="button" aria-pressed="false" data-answer="Allowed for one hour. In Tamio, this agent can continue without asking during that hour.">Allow for 1 Hour</button>
        <button type="button" aria-pressed="false" data-answer="Always allowed. In Tamio, you can revoke this permission in Settings › MCP.">Always Allow</button>
        <button type="button" aria-pressed="false" data-answer="Denied. In Tamio, the agent is told and nothing runs.">Deny</button>
      </div>`;
    const result = document.createElement("p");
    result.className = "tw-alert-result";
    result.setAttribute("role", "status");
    result.setAttribute("aria-live", "polite");
    result.setAttribute("aria-atomic", "true");
    const initial = "Sample request. Choose a response to see what happens.";
    result.textContent = initial;
    const reset = document.createElement("button");
    reset.type = "button";
    reset.className = "tw-alert-reset";
    reset.textContent = "Reset demo";
    reset.hidden = true;
    stage.append(alert, result, reset);
    alert.addEventListener("click", (event) => {
      const button = event.target.closest("button[data-answer]");
      if (!button) return;
      alert.querySelectorAll("button").forEach((b) => b.setAttribute("aria-pressed", String(b === button)));
      result.textContent = button.dataset.answer;
      reset.hidden = false;
    });
    reset.addEventListener("click", () => {
      alert.querySelectorAll("button").forEach((b) => b.setAttribute("aria-pressed", "false"));
      result.textContent = initial;
      reset.hidden = true;
      alert.querySelector("button").focus();
    });
  }

  // MARK: A server's Activity

  function mountHistory(host) {
    const id = `tamio-history-${++mountID}`;
    const panel = document.createElement("div");
    panel.className = "tw-history tw-theme";
    panel.setAttribute("role", "group");
    panel.setAttribute("aria-label", "Sample web-01 server details");
    panel.innerHTML = `
      <div class="tw-panel-head"><b>WEB-01</b><span class="tw-history-label">Sample server</span></div>
      ${tabsMarkup(id)}<div class="tw-pane" id="${id}-pane" role="tabpanel" tabindex="0"></div>`;
    const pane = panel.querySelector(".tw-pane");
    const openEntries = new Map();
    let tab = "activity";
    const draw = () => {
      syncTabs(panel, id, tab);
      pane.innerHTML = panelContents(fleet[0], tab, openEntries);
    };
    bindTabs(panel, (view) => {
      if (tab === view) return;
      tab = view;
      draw();
    });
    trackEntries(pane, openEntries);
    draw();
    host.appendChild(panel);
  }

  document.querySelectorAll("[data-demo=window]").forEach(mountWindow);
  document.querySelectorAll("[data-demo=alert]").forEach(mountAlert);
  document.querySelectorAll("[data-demo=history]").forEach(mountHistory);
})();
