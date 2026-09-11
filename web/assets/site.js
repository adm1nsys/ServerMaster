"use strict";

// Pure content maps also keep screen switching independent from network requests.
const workflows = {
  start: {
    manual: ["Find the project folder", "Remember the runtime and port", "Re-enter the launch command", "Open the local address"],
    managed: ["Choose a saved profile", "Press Start"],
    handled: "Folder · Engine · Port · PHP version · Browser preference",
    manualSummary: "Your settings are spread across commands, folders, and memory.",
    managedSummary: "Configure the profile once. Reuse it whenever you return."
  },
  joomla: {
    manual: ["Find and download Joomla", "Unpack the project files", "Configure the server and PHP", "Create a database", "Start the site"],
    managed: ["Choose a Joomla 5 or 6 template", "Follow the setup wizard", "Start the new profile"],
    handled: "Release download · Checksum verification · Extraction · Profile defaults · Optional database",
    manualSummary: "Bring the download, runtime, configuration, and database together yourself.",
    managedSummary: "Guided setup brings the pieces together. Finish Joomla's own installer in your browser."
  },
  backup: {
    manual: ["Archive the project folder", "Export the database", "Name and organize the copies", "Remember to repeat"],
    managed: ["Choose a snapshot schedule", "Keep ServerMaster running"],
    handled: "Selected profiles · Backup interval · Snapshot destination · Retention",
    manualSummary: "A useful backup routine depends on remembering every part.",
    managedSummary: "Scheduled snapshots follow your settings. Database snapshots require the managed database to be running."
  }
};

const screens = {
  control: { file: "control.webp", title: "One view. Every project.", description: "Start and stop profiles independently, open their addresses, and inspect their status.", alt: "Control screen showing separate server profiles and their running state." },
  database: { file: "database.webp", title: "Your data, right beside your code.", description: "Manage the local database and inspect tables without leaving your workspace.", alt: "ServerMaster's native database workspace." },
  files: { file: "files.webp", title: "Find it. Open it. Keep building.", description: "Browse your project files from the same place you run your server.", alt: "Project file browser inside ServerMaster." },
  terminal: { file: "terminal.webp", title: "Go deeper without going elsewhere.", description: "Use an integrated terminal when your workflow calls for a command.", alt: "ServerMaster's integrated terminal with multiple tabs." },
  diagnostics: { file: "diagnostics.webp", title: "Get the context behind the problem.", description: "Inspect your environment with the app's system diagnostics tools.", alt: "System diagnostics screen inside ServerMaster." },
  backups: { file: "backups.webp", title: "A little confidence before a big change.", description: "Manage project snapshots, database backups, schedules, and restore points together.", alt: "Backups screen with scheduling, snapshot history, and restore controls." }
};

const controlThemes = {
  red: "control-red.webp",
  blue: "control-blue.webp",
  green: "control-green.webp",
  purple: "control-purple.webp"
};

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function markSelection(buttons, selected) {
  buttons.forEach(button => button.setAttribute("aria-pressed", String(button === selected)));
}

function pulse(node) {
  if (!node || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  node.classList.remove("switching");
  void node.offsetWidth;
  node.classList.add("switching");
  window.setTimeout(() => node.classList.remove("switching"), 420);
}

const themeButtons = [...document.querySelectorAll("[data-theme]")];
const heroStack = document.querySelector(".color-stack");
const heroImage = document.querySelector("#hero-control-image");
themeButtons.forEach(button => button.addEventListener("click", () => {
  const theme = button.dataset.theme;
  if (!controlThemes[theme] || !heroStack || !heroImage) return;
  markSelection(themeButtons, button);
  heroStack.classList.remove("theme-red", "theme-blue", "theme-green", "theme-purple");
  heroStack.classList.add("theme-" + theme);
  heroImage.src = "assets/" + controlThemes[theme];
  pulse(heroStack);
}));

const workflowButtons = [...document.querySelectorAll("[data-workflow]")];
workflowButtons.forEach(button => button.addEventListener("click", () => {
  const workflow = workflows[button.dataset.workflow];
  markSelection(workflowButtons, button);
  document.querySelector("#manual-steps").replaceChildren(...workflow.manual.map(step => element("li", "", step)));
  document.querySelector("#managed-steps").replaceChildren(...workflow.managed.map(step => element("li", "", step)));
  document.querySelector("#handled-tasks").textContent = workflow.handled;
  document.querySelector("#manual-summary").textContent = workflow.manualSummary;
  document.querySelector("#managed-summary").textContent = workflow.managedSummary;
  pulse(document.querySelector("#comparison"));
}));

const screenButtons = [...document.querySelectorAll("[data-screen]")];
screenButtons.forEach(button => button.addEventListener("click", () => {
  const screen = screens[button.dataset.screen];
  markSelection(screenButtons, button);
  const image = document.querySelector("#gallery-image");
  const figure = document.querySelector(".gallery-figure");
  figure?.classList.add("is-loading");
  image.src = "assets/" + screen.file;
  image.alt = screen.alt;
  document.querySelector("#screen-full").href = image.src;
  document.querySelector("#screen-title").textContent = screen.title;
  document.querySelector("#screen-description").textContent = screen.description;
  image.addEventListener("load", () => figure?.classList.remove("is-loading"), { once: true });
  pulse(figure);
}));

function safeLink(label, url, className = "") {
  const parsed = new URL(url);
  if (parsed.protocol !== "https:" || parsed.hostname !== "github.com") {
    throw new Error("Release links must use HTTPS on github.com");
  }
  const link = element("a", className, label);
  link.href = parsed.href;
  return link;
}

function validateCatalog(data) {
  if (data.schemaVersion !== 1 || !Array.isArray(data.platforms) || data.platforms.length === 0) throw new Error("Invalid release catalog");
  const ids = new Set();
  for (const platform of data.platforms) {
    if (!platform.id || ids.has(platform.id) || !platform.label || !platform.name || !Array.isArray(platform.releases) || !Array.isArray(platform.plannedTargets)) throw new Error("Invalid platform");
    ids.add(platform.id);
    if (!["available", "planned"].includes(platform.status)) throw new Error("Invalid platform status");
    if (platform.status === "available" && !platform.releases.some(release => release.id === platform.currentRelease)) throw new Error("Current release is missing");
    const releaseIds = new Set();
    for (const release of platform.releases) {
      if (!release.id || releaseIds.has(release.id) || !release.version || !Array.isArray(release.assets) || !release.assets.some(asset => asset.kind === "application")) throw new Error("Invalid release");
      releaseIds.add(release.id);
      safeLink("", release.notesUrl);
      release.assets.forEach(asset => safeLink(asset.label, asset.url));
    }
  }
  return data;
}

function renderPlatform(platform) {
  const panel = document.querySelector("#download-panel");
  panel.replaceChildren();
  document.querySelector("#release-archive").replaceChildren();

  const window = element("article", "finder-window");
  const toolbar = element("div", "finder-toolbar");
  const lights = element("span", "window-lights");
  lights.setAttribute("aria-hidden", "true");
  lights.append(element("i"), element("i"), element("i"));
  toolbar.append(lights, element("strong", "", platform.name), element("span", "finder-status", platform.statusLabel));
  const description = element("p", "finder-description", platform.description);

  const table = element("div", "finder-table");
  table.setAttribute("role", "table");
  table.setAttribute("aria-label", platform.name + " releases");
  const header = element("div", "finder-row finder-header");
  header.setAttribute("role", "row");
  ["Name", "Version", "Build", "Released", "Action"].forEach(label => {
    const cell = element("span", "", label);
    cell.setAttribute("role", "columnheader");
    header.append(cell);
  });
  table.append(header);

  if (platform.releases.length) {
    [...platform.releases]
      .sort((left, right) => right.date.localeCompare(left.date))
      .forEach(release => {
      const row = element("div", "finder-row");
      row.setAttribute("role", "row");
      const name = element("span", "finder-name");
      const icon = element("img");
      icon.src = "assets/icon.png";
      icon.width = 32;
      icon.height = 32;
      icon.alt = "";
      name.append(icon, element("strong", "", platform.name));
      const version = element("span", "", release.version);
      const build = element("span", "finder-mono", release.build || "—");
      const date = element("span", "finder-date", new Intl.DateTimeFormat("en", { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" }).format(new Date(release.date + "T00:00:00Z")));
      const action = element("span", "finder-action");
      const application = release.assets.find(asset => asset.kind === "application");
      action.append(safeLink("Download", application.url, "finder-button"));
      [name, version, build, date, action].forEach(cell => { cell.setAttribute("role", "cell"); row.append(cell); });
      table.append(row);

      const extras = element("div", "finder-extras");
      const facts = element("span", "", release.requirements + " · " + release.architecture + " · " + release.format);
      const links = element("span", "finder-extra-links");
      release.assets.filter(asset => asset.kind !== "application").forEach(asset => links.append(safeLink(asset.label, asset.url)));
      links.append(safeLink("Release notes", release.notesUrl));
      extras.append(facts, links);
      table.append(extras);
      if (release.signed === false) table.append(element("p", "finder-warning", "Unsigned & not notarized. See the release notes for macOS first-launch instructions."));
      });
  } else {
    const row = element("div", "finder-row finder-planned");
    row.setAttribute("role", "row");
    const targetText = platform.plannedTargets.length ? platform.plannedTargets.join(" · ") : platform.name;
    [targetText, "—", "—", "When ready", "Planned"].forEach((value, index) => {
      const cell = element("span", index === 0 ? "finder-name" : index === 2 ? "finder-mono" : "", value);
      cell.setAttribute("role", "cell");
      row.append(cell);
    });
    table.append(row);
  }
  window.append(toolbar, description, table);
  panel.append(window);
}

async function loadReleases() {
  const container = document.querySelector("#download-catalog");
  const status = document.querySelector("#catalog-status");
  try {
    // Relative to this script: works at /ServerMaster/, /web/, and a local preview.
    const scriptUrl = document.querySelector('script[src*="site.js"]').src;
    const url = new URL("../data/releases.json", scriptUrl);
    const response = await fetch(url, { cache: "no-cache", signal: AbortSignal.timeout(10000) });
    if (!response.ok) throw new Error("Release catalog request failed");
    const data = validateCatalog(await response.json());
    const buttons = data.platforms.map(platform => {
      const button = element("button", "", platform.label);
      button.type = "button";
      button.setAttribute("aria-pressed", "false");
      button.addEventListener("click", () => {
        const panel = document.querySelector("#download-panel");
        panel.classList.add("is-switching");
        markSelection(buttons, button);
        renderPlatform(platform);
        status.textContent = platform.name + " · " + platform.statusLabel;
        window.setTimeout(() => panel.classList.remove("is-switching"), 180);
        pulse(panel.querySelector(".finder-window"));
      });
      return button;
    });
    document.querySelector("#platform-buttons").replaceChildren(...buttons);
    status.className = "sr-only";
    buttons[0].click();
  } catch (error) {
    status.textContent = "The download list is temporarily unavailable. All published builds are available in the GitHub release archive below.";
    status.className = "catalog-error";
    console.error("Unable to load ServerMaster release catalog:", error.message);
  } finally {
    container.setAttribute("aria-busy", "false");
  }
}

loadReleases();

// Motion is added after JavaScript starts, keeping the page fully visible without it.
const revealItems = [...document.querySelectorAll(".section-heading, .automation-grid, .feature-panel, .comparison, .comparison-table-wrap, .gallery-shell, .detail-grid, #download-catalog, .questions")];
if ("IntersectionObserver" in window && !window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
  revealItems.forEach(item => item.classList.add("reveal"));
  const observer = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("is-visible");
      observer.unobserve(entry.target);
    });
  }, { rootMargin: "0px 0px -9%", threshold: 0.08 });
  revealItems.forEach(item => observer.observe(item));
}

const stack = document.querySelector("[data-tilt]");
if (stack && window.matchMedia("(pointer: fine)").matches && !window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
  stack.addEventListener("pointermove", event => {
    const bounds = stack.getBoundingClientRect();
    const x = ((event.clientX - bounds.left) / bounds.width - 0.5) * 24;
    const y = ((event.clientY - bounds.top) / bounds.height - 0.5) * 16;
    stack.style.setProperty("--tilt-x", x.toFixed(2) + "px");
    stack.style.setProperty("--tilt-y", y.toFixed(2) + "px");
  });
  stack.addEventListener("pointerleave", () => {
    stack.style.setProperty("--tilt-x", "0px");
    stack.style.setProperty("--tilt-y", "0px");
  });
}
