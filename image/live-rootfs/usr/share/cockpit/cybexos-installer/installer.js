import {Wizard} from "./model.mjs";
const wizard = new Wizard();
const $ = id => document.getElementById(id);
const ids = ["setup", "location", "review", "progress"];
let initializing = true;
let polling;
let installationComplete = false;
let appliedKeyboard = null;
let timezoneChosen = false;

function fail(error) {
    $("error").textContent = error.message || "The installer could not complete this operation.";
    $("error").hidden = false;
}
function render() {
    ids.forEach(id => { $(id).hidden = initializing || wizard.page !== id; });
    document.querySelectorAll("#steps li").forEach((item, index) => {
        item.removeAttribute("aria-current");
        if (index === ids.indexOf(wizard.page)) item.setAttribute("aria-current", "step");
    });
    document.querySelectorAll("button, input, select").forEach(item => { item.disabled = wizard.busy; });
    $("install").disabled = wizard.busy || !$("erase").checked;
    ["password", "confirm", "keyboard-test"].forEach(id => { $(id).disabled = wizard.busy || appliedKeyboard !== $("keyboard").value; });
    $("busy").hidden = !initializing && !wizard.busy;
}
function call(command, data = {}, onProgress = () => {}) {
    return new Promise((resolve, reject) => {
        let buffer = "", result;
        const process = cockpit.spawn(["/usr/libexec/cybexos-installer-backend", command],
            {superuser: "require", err: "message"});
        process.stream(chunk => {
            buffer += chunk;
            let index;
            while ((index = buffer.indexOf("\n")) >= 0) {
                const line = buffer.slice(0, index); buffer = buffer.slice(index + 1);
                try {
                    const event = JSON.parse(line);
                    if (event.event === "result") result = event;
                    if (event.event === "progress") onProgress(event);
                } catch { /* Ignore non-protocol diagnostics without displaying them. */ }
            }
        });
        const finish = () => result?.ok ? resolve(result.data)
            : reject(new Error(result?.error || "The installer connection was interrupted. Refresh its status before continuing."));
        process.then(finish, finish);
        process.input(JSON.stringify(data), false);
    });
}
async function run(message, work) {
    $("error").hidden = true;
    $("busy").textContent = message;
    try {
        const promise = wizard.operation(work);
        render();
        await promise;
    } catch (error) { fail(error); }
    finally { render(); }
}
function options(id, values, selected) {
    $(id).replaceChildren(...values.map(value => {
        const option = document.createElement("option");
        option.value = value.id || value; option.textContent = value.label || value;
        return option;
    }));
    if (selected) $(id).value = selected;
}
function timezoneOptions(zones, selected) {
    const groups = new Map();
    for (const zone of zones) {
        const [region, ...place] = zone.split("/");
        const option = document.createElement("option");
        option.value = zone;
        option.textContent = place.length ? place.join(" / ").replaceAll("_", " ") : zone;
        if (!place.length) { groups.set(zone, option); continue; }
        if (!groups.has(region)) {
            const group = document.createElement("optgroup");
            group.label = region;
            groups.set(region, group);
        }
        groups.get(region).append(option);
    }
    $("timezone").replaceChildren(...groups.values());
    $("timezone").value = selected;
}
function showDetectedTimezone(zone) {
    $("timezone").value = zone;
    $("timezone-status").textContent = "Detected from your network location.";
}
function detectTimezone(zones) {
    // Geolocation waits for the network; never hold setup up for it.
    call("geolocate").then(result => {
        if (!timezoneChosen && zones.includes(result.timezone)) showDetectedTimezone(result.timezone);
    }, () => {});
}
function waitForBackend() {
    return new Promise((resolve, reject) => {
        const ready = cockpit.file("/run/anaconda/backend_ready");
        const timeout = setTimeout(() => {
            ready.close(); reject(new Error("Anaconda is taking longer than expected to start. Try again or open the full installer."));
        }, 120000);
        ready.watch(content => {
            if (content !== null) { clearTimeout(timeout); ready.close(); resolve(); }
        });
    });
}
function account() {
    return Object.fromEntries(["username", "password", "confirm", "keyboard", "locale", "timezone", "hostname"].map(id => [id, $(id).value]));
}
function showProgress(data) {
    wizard.page = "progress";
    $("progress-message").textContent = data.message || "Anaconda is preparing the installation…";
    if (data.total > 0) { $("meter").max = data.total; $("meter").value = data.step || 0; }
    else $("meter").removeAttribute("value");
    if (data.phase === "complete") {
        installationComplete = true;
        clearInterval(polling);
        $("progress-title").textContent = "Your workspace is ready.";
        $("meter").max = 1; $("meter").value = 1; $("restart-help").hidden = false;
        $("reboot").hidden = false;
    } else if (data.phase === "failed-install") {
        clearInterval(polling);
        $("progress-title").textContent = "Installation needs attention.";
    }
    render();
}
function monitor() {
    clearInterval(polling);
    polling = setInterval(() => {
        if (!wizard.busy) call("status").then(showProgress, fail);
    }, 2000);
}
async function initialize() {
    initializing = true; $("startup-retry").hidden = true;
    await run("Starting Anaconda and finding your disks…", async () => {
        const state = await call("status");
        if (["installing", "complete", "failed-install"].includes(state.phase)) {
            initializing = false; showProgress(state);
            if (state.phase === "installing") monitor();
            return;
        }
        await waitForBackend();
        const data = await call("inventory");
        options("keyboard", data.keyboards, data.keyboard);
        options("locale", data.locales, data.locale);
        timezoneOptions(data.timezones, data.timezone);
        if (data.detected_timezone) showDetectedTimezone(data.detected_timezone);
        else detectTimezone(data.timezones);
        options("disk", [{id: "", label: "Select a disk…"}, ...data.disks.map(disk => ({
            id: disk.name, label: `${disk.model} — ${(disk.size / 1024**3).toFixed(1)} GiB — ${disk.path}${disk.removable ? " (removable)" : ""}`
        }))]);
        initializing = false;
        const keyboard = await call("keyboard", {keyboard: $("keyboard").value});
        appliedKeyboard = keyboard.keyboard;
        $("keyboard-status").textContent = `Keyboard applied. Boot unlock layout: ${keyboard.boot_keyboard}.`;
    });
    if (initializing) { $("busy").hidden = true; $("startup-retry").hidden = false; }
}
$("keyboard").addEventListener("change", () => {
    appliedKeyboard = null;
    $("password").value = ""; $("confirm").value = ""; $("keyboard-test").value = "";
    run("Applying your keyboard layout…", async () => {
        const result = await call("keyboard", {keyboard: $("keyboard").value});
        appliedKeyboard = result.keyboard;
        $("keyboard-status").textContent = `Keyboard applied. Boot unlock layout: ${result.boot_keyboard}.`;
    });
});
$("timezone").addEventListener("change", () => {
    timezoneChosen = true;
    $("timezone-status").textContent = "";
});
$("account-form").addEventListener("submit", event => {
    event.preventDefault();
    try {
        if (appliedKeyboard !== $("keyboard").value) throw new Error("Apply your keyboard layout before entering your password.");
        wizard.account(account()); wizard.move("location"); $("error").hidden = true; render();
    }
    catch (error) { fail(error); }
});
$("disk-form").addEventListener("submit", event => {
    event.preventDefault();
    run("Planning your disk layout and checking it with Anaconda…", async () => {
        const data = {...wizard.account(account()), disk: $("disk").value, encrypted: $("encrypted").checked};
        wizard.plan = null;
        const plan = await call("plan", data);
        wizard.plan = plan; wizard.page = "review";
        $("erase").checked = false;
        const fields = {Disk: `${plan.disk.model} · ${plan.disk.path}`, Account: plan.account.username,
            Storage: plan.account.encrypted ? "Encrypted Btrfs · LUKS2" : "Btrfs · unencrypted",
            "At startup": plan.account.encrypted ? "Unlock your disk → automatic login" : "Sign in to your account",
            "Boot keyboard": plan.boot_keyboard, Language: plan.account.locale, Timezone: plan.account.timezone};
        $("summary").replaceChildren(...Object.entries(fields).flatMap(([key, value]) => {
            const term = document.createElement("dt"), detail = document.createElement("dd");
            term.textContent = key; detail.textContent = value; return [term, detail];
        }));
        $("actions").replaceChildren(...plan.actions.map(action => {
            const item = document.createElement("li");
            item.textContent = [action["action-description"], action["object-description"], action["device-name"]].filter(Boolean).join(" · ");
            return item;
        }));
        $("warnings").textContent = plan.warnings.join("\n");
    });
});
document.querySelectorAll(".back").forEach(button => button.addEventListener("click", () => {
    try { wizard.move(button.dataset.page); render(); } catch (error) { fail(error); }
}));
$("erase").addEventListener("change", render);
$("install").addEventListener("click", () => {
    let confirmation;
    try { confirmation = wizard.confirmation($("erase").checked); } catch (error) { fail(error); return; }
    run("Installing CybexOS…", async () => {
        // Drop browser copies before the destructive transaction starts.
        const entered = [$("password").value, $("confirm").value];
        $("password").value = ""; $("confirm").value = "";
        showProgress({phase: "installing"});
        try { showProgress(await call("install", confirmation, showProgress)); monitor(); }
        catch (error) {
            const state = await call("status").catch(() => null);
            if (state && !["installing", "complete", "failed-install"].includes(state.phase)) {
                // Rejected before Anaconda started: this review is no longer valid.
                // Nothing was written, so keep the entered passwords for a new review.
                [$("password").value, $("confirm").value] = entered;
                wizard.plan = null; wizard.page = "location";
            } else if (state) {
                showProgress(state);
                if (state.phase === "installing") monitor();
            }
            throw error;
        }
    });
});
$("advanced").addEventListener("click", () => run("Opening the full installer…", async () => {
    await call("advanced");
    $("password").value = ""; $("confirm").value = "";
    window.location.href = "../anaconda-webui/index.html";
}));
$("refresh-status").addEventListener("click", () => run("Checking installation status…", async () => showProgress(await call("status"))));
$("retry").addEventListener("click", initialize);
$("reboot").addEventListener("click", () => run("Restarting…", () => call("reboot")));
window.addEventListener("beforeunload", event => {
    if ((wizard.page === "progress" && !installationComplete) || wizard.busy) { event.preventDefault(); event.returnValue = ""; }
});
initialize();
