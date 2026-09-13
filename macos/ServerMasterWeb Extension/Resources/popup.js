//
//  popup.js
//  ServerMaster
//
//  The panel behind the toolbar button. Everything it knows comes from the
//  native handler over sendNativeMessage — the extension itself has no access to
//  the file system, and no permission to read any page.
//

const list = document.getElementById("profiles");
const state = document.getElementById("state");
const summary = document.getElementById("summary");
const footer = document.getElementById("footer");
const admin = document.getElementById("admin");

let adminAddress = null;

async function ask(message) {
    // sendNativeMessage never settles if the native half does not answer — a
    // stale copy of the app, a handler that failed to launch. Without a deadline
    // the panel sits on “Reading…” for ever, which says nothing at all.
    const deadline = new Promise((_, reject) =>
        setTimeout(() => reject(new Error("ServerMaster did not answer. Is it installed and open?")), 4000));

    let reply;
    try {
        reply = await Promise.race([
            browser.runtime.sendNativeMessage("application.id", message),
            deadline
        ]);
    } catch (error) {
        throw new Error(error.message || "ServerMaster did not answer.");
    }
    if (!reply) throw new Error("ServerMaster answered with nothing.");
    if (reply.error) throw new Error(reply.error);
    return reply;
}

function say(text, bad = false) {
    state.textContent = text;
    state.hidden = !text;
    state.classList.toggle("bad", bad);
}

function row(profile) {
    const item = document.createElement("li");

    const dot = document.createElement("span");
    dot.className = profile.state === "running" ? "dot on" : "dot";
    item.append(dot);

    const name = document.createElement("span");
    name.className = "name";
    name.textContent = profile.name;
    if (profile.detail) {
        const detail = document.createElement("span");
        detail.className = "detail";
        detail.textContent = profile.detail;
        name.append(detail);
    }
    item.append(name);

    const actions = document.createElement("span");
    actions.className = "actions";

    if (profile.state === "running" && profile.address) {
        actions.append(button("Open", () => {
            browser.tabs.create({ url: profile.address });
            window.close();
        }));
    }
    actions.append(button(profile.state === "running" ? "Stop" : "Start", async (element) => {
        element.disabled = true;
        try {
            await ask({ action: profile.state === "running" ? "stop" : "start", profile: profile.id });
            await load();
        } catch (error) {
            say(error.message, true);
            element.disabled = false;
        }
    }));

    item.append(actions);
    return item;
}

function button(label, action) {
    const element = document.createElement("button");
    element.type = "button";
    element.textContent = label;
    element.addEventListener("click", () => action(element));
    return element;
}

async function load() {
    try {
        const status = await ask({ action: "status" });
        const profiles = status.profiles || [];

        list.replaceChildren(...profiles.map(row));
        list.hidden = profiles.length === 0;

        const running = profiles.filter((p) => p.state === "running").length;
        summary.textContent = running === 0 ? "nothing running" : `${running} running`;

        adminAddress = status.adminPanelAddress || null;
        admin.hidden = !adminAddress;

        footer.hidden = false;
        if (profiles.length === 0) {
            say("No profiles yet. Create one in ServerMaster.");
        } else {
            say(status.stale ? "ServerMaster is not running — this is its last known state." : "");
        }
    } catch (error) {
        list.hidden = true;
        footer.hidden = false;
        say(error.message, true);
    }
}

admin.addEventListener("click", () => {
    if (adminAddress) {
        browser.tabs.create({ url: adminAddress });
        window.close();
    }
});

document.getElementById("refresh").addEventListener("click", load);

// Kept up to date on its own while the panel is open. Starting a server is not
// instant — Joomla takes its time — and a panel that says “stopped” until you
// press Refresh is worse than one that says nothing, because it looks certain.
//
// Every second and a half: the answer comes from a file the app has already
// written, so this costs nothing worth counting, and the panel closes the
// moment it loses focus.
const timer = setInterval(load, 1500);
window.addEventListener("unload", () => clearInterval(timer));

load();
