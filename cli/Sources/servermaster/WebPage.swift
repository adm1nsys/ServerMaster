//
//  WebPage.swift
//  servermaster
//
//  The page the built-in web interface serves.
//
//  One file, no build step, no assets to ship: the HTML, the styling and the
//  handful of lines of script are here as a string. A control panel for a
//  handful of local servers does not need a front-end toolchain, and anything
//  that needs one stops compiling into a single binary.
//
//  It follows the application's own look — the same dark ground, the same
//  restrained type — without pretending to be it. There is no attempt at Liquid
//  Glass in a browser; that belongs to the platform that has it.
//

import Foundation

nonisolated enum WebPage {

    static let html = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>ServerMaster</title>
    <style>
      :root {
        color-scheme: dark light;
        --ground: #10141c; --panel: #182030; --line: #26304a;
        --ink: #eef2ff; --quiet: #93a0bd; --accent: #5b8cff;
        --on: #3ddc84; --off: #6b7692; --bad: #ff6b6b;
      }
      @media (prefers-color-scheme: light) {
        :root { --ground:#f4f6fb; --panel:#fff; --line:#dfe4f0;
                --ink:#101828; --quiet:#5b667f; }
      }
      * { box-sizing: border-box; }
      body {
        margin: 0; padding: 40px 24px; background: var(--ground); color: var(--ink);
        font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      }
      main { max-width: 860px; margin: 0 auto; }
      h1 { font-size: 30px; margin: 0 0 4px; letter-spacing: -0.4px; }
      .sub { color: var(--quiet); margin: 0 0 26px; }
      .card {
        background: var(--panel); border: 1px solid var(--line);
        border-radius: 14px; overflow: hidden;
      }
      .row {
        display: flex; align-items: center; gap: 14px;
        padding: 14px 18px; border-top: 1px solid var(--line);
      }
      .row:first-child { border-top: none; }
      .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--off); flex: none; }
      .dot.on { background: var(--on); box-shadow: 0 0 0 4px rgba(61,220,132,.14); }
      .name { font-weight: 550; }
      .meta { color: var(--quiet); font-size: 13px; }
      .grow { flex: 1; min-width: 0; }
      a.addr { color: var(--accent); text-decoration: none; font-family: ui-monospace, monospace; font-size: 13px; }
      a.addr:hover { text-decoration: underline; }
      button {
        font: inherit; font-size: 13px; font-weight: 550;
        color: var(--ink); background: transparent;
        border: 1px solid var(--line); border-radius: 999px;
        padding: 6px 16px; cursor: pointer;
      }
      button:hover { border-color: var(--accent); }
      button.go { background: var(--accent); border-color: var(--accent); color: #fff; }
      button:disabled { opacity: .45; cursor: default; }
      footer { color: var(--quiet); font-size: 13px; margin-top: 22px; }
      .empty { padding: 26px 18px; color: var(--quiet); }
    </style>
    </head>
    <body>
    <main>
      <h1>ServerMaster</h1>
      <p class="sub" id="sub">Loading…</p>
      <div class="card" id="list"></div>
      <footer>
        Served by the command line tool on this machine, over plain HTTP on the
        loopback. To reach it from elsewhere, put a web server in front of it.
      </footer>
    </main>

    <script>
    const list = document.getElementById("list");
    const sub  = document.getElementById("sub");
    let busy = null;

    async function load() {
      let data;
      try {
        data = await (await fetch("/api/status")).json();
      } catch (e) {
        sub.textContent = "The tool is no longer answering.";
        return;
      }
      const profiles = data.profiles || [];
      const running = profiles.filter(p => p.running).length;
      sub.textContent = profiles.length === 0
        ? "No profiles yet."
        : (running === 0 ? "Nothing running." : running + " running.");

      if (profiles.length === 0) {
        list.innerHTML = '<div class="empty">Create one with: servermaster new static --root ~/Sites/mine</div>';
        return;
      }

      list.replaceChildren(...profiles.map(row));
    }

    function row(p) {
      const el = document.createElement("div");
      el.className = "row";

      const dot = document.createElement("span");
      dot.className = p.running ? "dot on" : "dot";
      el.append(dot);

      const box = document.createElement("div");
      box.className = "grow";
      const name = document.createElement("div");
      name.className = "name";
      name.textContent = p.name;
      const meta = document.createElement("div");
      meta.className = "meta";
      meta.textContent = p.engine + (p.pid ? "  ·  pid " + p.pid : "");
      box.append(name, meta);
      el.append(box);

      if (p.running) {
        const link = document.createElement("a");
        link.className = "addr"; link.href = p.address; link.target = "_blank";
        link.textContent = p.address;
        el.append(link);
      }

      const button = document.createElement("button");
      button.className = p.running ? "" : "go";
      button.textContent = p.running ? "Stop" : "Start";
      button.disabled = busy === p.id;
      button.onclick = () => act(p.running ? "stop" : "start", p.id);
      el.append(button);
      return el;
    }

    async function act(what, id) {
      busy = id;
      load();
      try {
        await fetch("/api/" + what + "/" + id, { method: "POST" });
      } finally {
        busy = null;
        // Starting is not instant — Apache and PHP-FPM take a moment to claim
        // the port, and asking again too soon shows the old answer.
        setTimeout(load, 600);
      }
    }

    load();
    setInterval(() => { if (!busy) load(); }, 2000);
    </script>
    </body>
    </html>
    """
}
