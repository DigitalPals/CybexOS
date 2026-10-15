#!/usr/bin/env node
// Source-only browser test. The Cockpit transport is a fixture: no installer,
// disk, VM, ISO, or system service is contacted. See README for dependencies.
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require("playwright-core");
const { waitForInitialSetup } = require("./real_browser_qualification.cjs");
const root = path.join(__dirname, "live-rootfs/usr/share/cockpit/cybexos-installer");

const transport = `
window.fixtureRequests = [];
window.fixturePhase = sessionStorage.getItem("fixturePhase") || "setup";
window.cockpit = {
  file() { return { watch(callback) { setTimeout(() => callback(""), 0); }, close() {} }; },
  spawn(args) {
  let stream, done;
  return {
    stream(callback) { stream = callback; return this; },
    then(callback) { done = callback; return this; },
    input(raw) {
      const data = JSON.parse(raw || "{}"), command = args[1];
      fixtureRequests.push({ command, hasPassword: !!data.password,
        locale: data.locale, timezone: data.timezone, encrypted: data.encrypted,
        layout: data.layout, shrink: data.shrink, oem: data.oem, seed: data.seed,
        username: data.username, alongsideConfirmed: data.alongside_confirmed,
        eraseConfirmed: data.erase_confirmed, source: data.source });
      const busyRemaining = Number(sessionStorage.getItem("fixtureBusyRemaining") || "0");
      if (command === "inventory" && busyRemaining > 0) {
        sessionStorage.setItem("fixtureBusyRemaining", String(busyRemaining - 1));
        setTimeout(() => {
          stream(JSON.stringify({ event: "result", ok: false,
            error: "Another installer operation is still running." }) + "\\n");
          done();
        }, 5);
        return this;
      }
      const initialError = command === "inventory" && sessionStorage.getItem("fixtureInitialError");
      if (initialError && initialError !== "done") {
        sessionStorage.setItem("fixtureInitialError", "done");
        setTimeout(() => {
          stream(JSON.stringify({ event: "result", ok: false,
            error: "Anaconda inventory failed." }) + "\\n");
          done();
        }, 5);
        return this;
      }
      let result;
      if (command === "status") result = fixturePhase === "failed-install"
        ? { phase: fixturePhase, message: "Installation stopped during “Running post-installation scripts”.",
            failed_step: "Running post-installation scripts", log_source: "post" }
        : { phase: fixturePhase, message: "Fixture progress" };
      else if (command === "log") result = { source: data.source, available: true,
        text: Array.from({ length: 200 }, (_, line) => \`fixture \${data.source} log line \${line}\`).join("\\n") };
      else if (command === "log-destinations") result = { destinations: [
        { name: "sdb1", path: "/dev/sdb1", label: "STICK", fstype: "exfat", size: 32 * 1024 ** 3, mountpoint: "" }] };
      else if (command === "export-logs") result = { file: "cybexos-install-logs-fixture.tar.gz",
        device: "/dev/" + data.device, label: "STICK" };
      else if (command === "inventory" || command === "rescan") result = {
        disks: [{ name: "vda", path: "/dev/vda", size: 107374182400, model: "Fixture NVMe",
                  serial: "FIXTURE-SERIAL", wwn: "FIXTURE-WWN",
                  partitions: [{ path: "/dev/vda1", size: 2147483648, filesystem: "vfat" }] },
                { name: "vdb", path: "/dev/vdb", size: 536870912000, model: "Fixture Windows SSD",
                  serial: "FIXTURE-WINDOWS", wwn: "", systems: ["Windows"],
                  partitions: [{ path: "/dev/vdb1", size: 104857600, filesystem: "vfat" },
                               { path: "/dev/vdb3", size: 429496729600, filesystem: "ntfs" }] }],
        keyboards: [{ id: "us", label: "English (US)" }, { id: "nl", label: "Dutch" }],
        locales: ["en_US.UTF-8", "nl_NL.UTF-8"], locale: "en_US.UTF-8",
        keyboard: "us", timezones: ["America/Argentina/Buenos_Aires", "Europe/Amsterdam", "UTC"],
        timezone: "UTC", detected_timezone: ""
      };
      else if (command === "geolocate") result = { timezone: "Europe/Amsterdam" };
      else if (command === "seed") {
        const mode = sessionStorage.getItem("fixtureSeed");
        const seed = { digest: "fixture-digest", oem: false, encrypted: true, username: "lab",
          full_name: "Lab Machine", hostname: "lab-1", keyboard: "us", locale: "en_US.UTF-8",
          timezone: "UTC", ssh_keys: 1, ssh_server: false, tailscale: true, countdown: 10,
          disk: { name: "vda", path: "/dev/vda", size: 107374182400, model: "Fixture NVMe",
                  serial: "FIXTURE-SERIAL", wwn: "FIXTURE-WWN", partitions: [] } };
        result = mode === "valid" ? { found: true, valid: true, errors: [], seed }
          : mode === "invalid" ? { found: true, valid: false, errors: ['Set "disk.erase: true" to confirm that the matched disk is erased.'] }
          : { found: false };
      }
      else if (command === "alongside") result = {
        mode: "shrink", free: 10737418240, required: 68719476736, systems: ["Windows"],
        partition: { id: "vdb3", path: "/dev/vdb3", size: 429496729600, min_size: 107374182400, filesystem: "ntfs" },
        floor: 112742891520, min_space: 68719476736, max_space: 327491256320, default_space: 198105366528
      };
      else if (command === "keyboard") result = { keyboard: data.keyboard, boot_keyboard: data.keyboard };
      else if (command === "plan" && data.seed) result = {
        phase: "review", token: "seed-token", countdown: 10,
        disk: { name: "vda", path: "/dev/vda", size: 107374182400, model: "Fixture NVMe",
                serial: "FIXTURE-SERIAL", wwn: "FIXTURE-WWN", partitions: [] },
        account: { username: "lab", encrypted: true, locale: "en_US.UTF-8", timezone: "UTC", unattended: true },
        layout: { mode: "erase" }, boot_keyboard: "us",
        actions: [{ "action-description": "Create", "object-description": "encrypted Btrfs", "device-name": "vda" }],
        warnings: []
      };
      else if (command === "plan" && data.layout === "alongside") result = {
        phase: "review", token: "alongside-token",
        disk: { name: "vdb", path: "/dev/vdb", size: 536870912000, model: "Fixture Windows SSD",
                serial: "FIXTURE-WINDOWS", wwn: "", partitions: [] },
        account: { username: data.username, encrypted: data.encrypted, locale: data.locale,
                   timezone: data.timezone, passwordless_wheel: data.passwordless_wheel, oem: !!data.oem },
        layout: { mode: "alongside", systems: ["Windows"], space: 10737418240 + 429496729600 - data.shrink.size,
                  kept: ["/dev/vdb1"],
                  resize: { path: "/dev/vdb3", filesystem: "ntfs", from: 429496729600, to: data.shrink.size } },
        boot_keyboard: data.keyboard,
        actions: [{ "action-description": "Resize device", "object-description": "partition", "device-name": "vdb3" }],
        warnings: []
      };
      else if (command === "plan") result = {
        phase: "review", token: "fixture-token",
        disk: { name: "vda", path: "/dev/vda", size: 107374182400, model: "Fixture NVMe",
                serial: "FIXTURE-SERIAL", wwn: "FIXTURE-WWN",
                partitions: [{ path: "/dev/vda1", size: 2147483648, filesystem: "vfat" }] },
        account: { username: data.username, encrypted: data.encrypted,
                   locale: data.locale, timezone: data.timezone,
                   passwordless_wheel: data.passwordless_wheel, oem: !!data.oem },
        layout: { mode: "erase" },
        boot_keyboard: data.keyboard,
        actions: [{ "action-description": "Create", "object-description": "encrypted Btrfs", "device-name": "vda" }],
        warnings: []
      };
      else if (command === "install" && !sessionStorage.getItem("fixtureRejected")) {
        // Anaconda's plan check rejects the first confirmation; nothing starts.
        sessionStorage.setItem("fixtureRejected", "1");
        setTimeout(() => {
          stream(JSON.stringify({ event: "result", ok: false,
            error: "The planned disk changes changed. Review the installation again." }) + "\\n");
          done();
        }, 5);
        return this;
      }
      else if (command === "install") {
        fixturePhase = "installing";
        sessionStorage.setItem("fixturePhase", fixturePhase);
        result = { phase: "installing" };
        setTimeout(() => {
          fixturePhase = "complete";
          sessionStorage.setItem("fixturePhase", fixturePhase);
        }, 100);
      } else if (command === "diagnostics") result = {
        schema: 1, installer: { phase: fixturePhase, message: "Installation did not finish." },
        worker: { ActiveState: "failed", Result: "exit-code" }, backend_ready: true
      };
      else result = { phase: "setup" };
      setTimeout(() => {
        stream(JSON.stringify({ event: "result", ok: true, data: result }) + "\\n");
        done();
      }, 5);
      return this;
    }
  };
}};
`;

async function screenshot(page, name) {
  if (!process.env.CYBEXOS_UI_SCREENSHOTS) return;
  const directory = path.resolve(process.env.CYBEXOS_UI_SCREENSHOTS);
  await fs.mkdir(directory, { recursive: true });
  await page.screenshot({ path: path.join(directory, `${name}.png`), animations: "disabled" });
}

async function main() {
  const server = http.createServer(async (request, response) => {
    try {
      const pathname = new URL(request.url, "http://localhost").pathname;
      if (pathname.endsWith("/base1/cockpit.js")) {
        response.setHeader("Content-Type", "text/javascript");
        response.end(transport);
        return;
      }
      const file = path.basename(pathname) || "index.html";
      if (!["index.html", "installer.css", "installer.js", "model.mjs", "cybex-wordmark.svg"].includes(file)) {
        response.writeHead(404).end();
        return;
      }
      response.setHeader("Content-Type", file.endsWith(".html") ? "text/html"
        : file.endsWith(".css") ? "text/css" : file.endsWith(".svg") ? "image/svg+xml" : "text/javascript");
      response.end(await fs.readFile(path.join(root, file)));
    } catch {
      response.writeHead(500).end("Fixture server error");
    }
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  let browser;
  try {
    browser = await chromium.launch({
      executablePath: process.env.CYBEXOS_BROWSER || "/usr/bin/brave-origin",
      headless: true,
      args: ["--disable-dev-shm-usage"],
    });
    const busyPage = await browser.newPage();
    await busyPage.addInitScript(() => sessionStorage.setItem("fixtureBusyRemaining", "4"));
    await busyPage.goto(`http://127.0.0.1:${server.address().port}/cockpit/@localhost/cybexos-installer/index.html`);
    await waitForInitialSetup(busyPage, 5000, [10, 20, 40, 80, 160, 320, 320]);
    assert.equal(await busyPage.locator("#setup").isVisible(), true);
    assert.equal(await busyPage.evaluate(() => fixtureRequests.filter(request => request.command === "inventory").length), 5);
    await busyPage.close();

    const otherErrorPage = await browser.newPage();
    await otherErrorPage.addInitScript(() => sessionStorage.setItem("fixtureInitialError", "other"));
    await otherErrorPage.goto(`http://127.0.0.1:${server.address().port}/cockpit/@localhost/cybexos-installer/index.html`);
    await assert.rejects(waitForInitialSetup(otherErrorPage, 250));
    assert.equal(await otherErrorPage.locator("#setup").isVisible(), false);
    assert.equal(await otherErrorPage.evaluate(() => fixtureRequests.filter(request => request.command === "inventory").length), 1);
    await otherErrorPage.close();

    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    await page.emulateMedia({ reducedMotion: "reduce" });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/cockpit/@localhost/cybexos-installer/index.html`);
    await page.locator("#setup").waitFor({ state: "visible" });
    await page.waitForFunction(() => !document.querySelector("#password").disabled);
    await screenshot(page, "installer-setup");
    // Capitals become the lowercase account name as they are typed.
    await page.locator("#username").pressSequentially("Alice");
    assert.equal(await page.inputValue("#username"), "alice");
    assert.equal(await page.inputValue("#disk"), "");
    assert.equal(await page.isChecked("#passwordless-wheel"), false);
    await page.fill("#username", "root");
    await page.fill("#password", "fixture secret 123");
    await page.fill("#confirm", "fixture secret 123");
    await page.getByRole("button", { name: "Choose install location" }).click();
    assert.match(await page.textContent("#error"), /System names are reserved/);
    await page.fill("#username", "alice");
    await page.fill("#password", "fixture secret 123");
    await page.fill("#confirm", "fixture secret 123");
    await page.check("#passwordless-wheel");
    await page.selectOption("#keyboard", "nl");
    await page.waitForFunction(() => !document.querySelector("#password").disabled);
    assert.equal(await page.inputValue("#password"), "");
    assert.equal(await page.inputValue("#confirm"), "");
    // Geolocation fills the dropdown in the background unless a timezone was chosen.
    await page.waitForFunction(() => document.querySelector("#timezone").value === "Europe/Amsterdam");
    assert.equal(await page.textContent("#timezone-status"), "Detected from your network location.");
    assert.equal(await page.locator("#timezone option[value='America/Argentina/Buenos_Aires']").textContent(),
      "Argentina / Buenos Aires");
    await page.fill("#keyboard-test", "ordinary test characters");
    await page.fill("#password", "fixture secret 123");
    await page.fill("#confirm", "fixture secret 123");
    await page.locator("#account-form details > summary").click();
    await page.selectOption("#locale", "nl_NL.UTF-8");
    await page.selectOption("#timezone", "Europe/Amsterdam");
    await page.getByRole("button", { name: "Choose install location" }).click();
    await page.locator("#location").waitFor({ state: "visible" });
    assert.equal(await page.isChecked("#encrypted"), true);
    await page.click("#rescan-disks");
    await page.waitForFunction(() => !document.querySelector("#rescan-disks").disabled);
    assert.equal(await page.inputValue("#disk"), "");
    await screenshot(page, "installer-location");
    await page.selectOption("#disk", "vda");
    assert.match(await page.textContent("#disk-details"), /FIXTURE-SERIAL/);
    assert.match(await page.textContent("#disk-details"), /\/dev\/vda1.*2\.0 GiB/);
    await page.getByRole("button", { name: "Review installation" }).click();
    await page.locator("#review").waitFor({ state: "visible" });
    assert.match(await page.textContent("#summary"), /Administrator commands do not ask for a password/);
    assert.match(await page.textContent("#summary"), /FIXTURE-WWN/);
    assert.equal(await page.isDisabled("#install"), true);
    await screenshot(page, "installer-review");
    await page.check("#erase");
    await page.click("#install");
    // A rejected confirmation returns to disk selection instead of waiting on progress.
    await page.locator("#location").waitFor({ state: "visible" });
    assert.match(await page.textContent("#error"), /planned disk changes changed/);
    await page.getByRole("button", { name: "Review installation" }).click();
    await page.locator("#review").waitFor({ state: "visible" });
    assert.equal(await page.isChecked("#erase"), false);
    await page.check("#erase");
    await page.click("#install");
    await page.getByRole("heading", { name: "Your workspace is ready." }).waitFor({ timeout: 10000 });
    assert.equal(await page.inputValue("#password"), "");
    assert.equal(await page.inputValue("#confirm"), "");
    assert.equal(await page.evaluate(() => fixtureRequests.filter(request => request.command === "install").length), 2);
    assert.equal(await page.evaluate(() => fixtureRequests.find(request => request.command === "plan").timezone), "Europe/Amsterdam");
    assert.equal(await page.evaluate(() => fixtureRequests.find(request => request.command === "plan").locale), "nl_NL.UTF-8");
    await page.reload();
    await page.getByRole("heading", { name: "Your workspace is ready." }).waitFor();
    await page.evaluate(() => sessionStorage.setItem("fixturePhase", "failed-install"));
    await page.reload();
    await page.getByRole("heading", { name: "Installation needs attention." }).waitFor();
    assert.equal(await page.isVisible("#failure-help"), true);
    const downloadPromise = page.waitForEvent("download");
    await page.click("#save-diagnostics");
    const download = await downloadPromise;
    assert.equal(download.suggestedFilename(), "cybexos-installer-diagnostics.json");
    assert.equal(await page.evaluate(() => fixtureRequests.some(request => request.command === "diagnostics")), true);
    await page.setViewportSize({ width: 390, height: 844 });
    await screenshot(page, "installer-narrow");
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);
    await page.setViewportSize({ width: 1280, height: 900 });
    // The details panel follows a chosen log at any stage.
    await page.locator("#log-panel summary").click();
    await page.waitForFunction(() => document.querySelector("#log").textContent.includes("fixture steps log line 199"));
    await page.selectOption("#log-source", "storage");
    await page.waitForFunction(() => document.querySelector("#log").textContent.includes("fixture storage log line"));
    // A failed installation names its step and opens the explaining log.
    await page.evaluate(() => sessionStorage.setItem("fixturePhase", "failed-install"));
    await page.reload();
    await page.getByRole("heading", { name: "Installation needs attention." }).waitFor();
    assert.match(await page.textContent("#progress-message"), /Running post-installation scripts/);
    await page.waitForFunction(() => document.querySelector("#log-panel").open
      && document.querySelector("#log").textContent.includes("fixture post log line 199"));
    assert.equal(await page.inputValue("#log-source"), "post");
    await page.click("#find-destinations");
    await page.waitForFunction(() => document.querySelector("#log-destination").value === "sdb1");
    await page.click("#export-logs");
    await page.waitForFunction(() => document.querySelector("#export-status").textContent.startsWith("Saved"));
    assert.equal(await page.textContent("#export-status"),
      "Saved cybexos-install-logs-fixture.tar.gz to STICK. You can remove the drive.");
    await screenshot(page, "installer-failed-details");
    const plain = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    plain.on("pageerror", error => errors.push(error.message));
    await plain.goto(`http://127.0.0.1:${server.address().port}/cockpit/@localhost/cybexos-installer/index.html`);
    await plain.locator("#setup").waitFor({ state: "visible" });
    await plain.waitForFunction(() => !document.querySelector("#password").disabled);
    await plain.fill("#username", "qualification");
    await plain.fill("#password", "fixture secret 123");
    await plain.fill("#confirm", "fixture secret 123");
    await plain.locator("#account-form details > summary").click();
    await plain.selectOption("#locale", "en_US.UTF-8");
    await plain.selectOption("#timezone", "UTC");
    await plain.getByRole("button", { name: "Choose install location" }).click();
    await plain.locator("#location").waitFor({ state: "visible" });
    await plain.selectOption("#disk", "vda");
    await plain.locator("#disk-form details > summary").click();
    await plain.uncheck("#encrypted");
    await plain.getByRole("button", { name: "Review installation" }).click();
    await plain.locator("#review").waitFor({ state: "visible" });
    assert.match(await plain.textContent("#summary"), /unencrypted/);
    assert.equal(await plain.evaluate(() => fixtureRequests.find(request => request.command === "plan").encrypted), false);
    await plain.close();
    const alongside = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    alongside.on("pageerror", error => errors.push(error.message));
    await alongside.addInitScript(() => sessionStorage.setItem("fixtureRejected", "1"));
    await alongside.goto(`http://127.0.0.1:${server.address().port}/cockpit/@localhost/cybexos-installer/index.html`);
    await alongside.locator("#setup").waitFor({ state: "visible" });
    await alongside.waitForFunction(() => !document.querySelector("#password").disabled);
    await alongside.fill("#username", "alice");
    await alongside.fill("#password", "fixture secret 123");
    await alongside.fill("#confirm", "fixture secret 123");
    await alongside.getByRole("button", { name: "Choose install location" }).click();
    await alongside.locator("#location").waitFor({ state: "visible" });
    await alongside.selectOption("#disk", "vdb");
    await alongside.locator("#space-field").waitFor({ state: "visible" });
    assert.equal(await alongside.isChecked("#layout-alongside"), true);
    assert.match(await alongside.textContent("#layout-legend"), /already has Windows/);
    assert.match(await alongside.textContent("#alongside-details"), /\/dev\/vdb3 is shrunk from 400\.0 GiB/);
    await alongside.evaluate(() => {
      const range = document.querySelector("#space");
      range.value = String(100 * 1024 ** 3);
      range.dispatchEvent(new Event("input"));
    });
    assert.match(await alongside.textContent("#space-label"), /100\.0 GiB/);
    await screenshot(alongside, "installer-alongside");
    await alongside.getByRole("button", { name: "Review installation" }).click();
    await alongside.locator("#review").waitFor({ state: "visible" });
    const alongsidePlan = await alongside.evaluate(() => fixtureRequests.find(request => request.command === "plan"));
    assert.equal(alongsidePlan.layout, "alongside");
    assert.deepEqual(alongsidePlan.shrink, { device: "vdb3", size: 429496729600 - (100 * 1024 ** 3 - 10737418240) });
    assert.match(await alongside.textContent("#summary"), /Resized\/dev\/vdb3 \(ntfs\) from 400\.0 GiB to 310\.0 GiB/);
    assert.match(await alongside.textContent("#erase-label"), /\/dev\/vdb3 will be resized/);
    assert.equal(await alongside.textContent("#install"), "Resize and install");
    await alongside.check("#erase");
    await alongside.click("#install");
    await alongside.locator("#progress").waitFor({ state: "visible" });
    const commit = await alongside.evaluate(() => fixtureRequests.find(request => request.command === "install"));
    assert.equal(commit.alongsideConfirmed, true);
    assert.equal(commit.eraseConfirmed, undefined);
    await alongside.close();

    const owner = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    owner.on("pageerror", error => errors.push(error.message));
    await owner.goto(`http://127.0.0.1:${server.address().port}/cockpit/@localhost/cybexos-installer/index.html`);
    await owner.locator("#setup").waitFor({ state: "visible" });
    await owner.waitForFunction(() => !document.querySelector("#password").disabled);
    await owner.locator("#account-form details > summary").click();
    await owner.check("#oem");
    assert.equal(await owner.isVisible("#username"), false);
    assert.equal(await owner.textContent("#password-label"), "Temporary disk passphrase");
    await owner.fill("#password", "handover phrase 123");
    await owner.fill("#confirm", "handover phrase 123");
    await owner.getByRole("button", { name: "Choose install location" }).click();
    await owner.locator("#location").waitFor({ state: "visible" });
    await owner.selectOption("#disk", "vda");
    await owner.getByRole("button", { name: "Review installation" }).click();
    await owner.locator("#review").waitFor({ state: "visible" });
    assert.match(await owner.textContent("#summary"), /Created by the new owner at first start/);
    assert.match(await owner.textContent("#summary"), /Temporary passphrase → new-owner setup/);
    assert.equal(await owner.evaluate(() => fixtureRequests.find(request => request.command === "plan").oem), true);
    await owner.close();

    const invalidSeed = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    invalidSeed.on("pageerror", error => errors.push(error.message));
    await invalidSeed.addInitScript(() => sessionStorage.setItem("fixtureSeed", "invalid"));
    await invalidSeed.goto(`http://127.0.0.1:${server.address().port}/cockpit/@localhost/cybexos-installer/index.html`);
    await invalidSeed.locator("#unattended").waitFor({ state: "visible" });
    assert.match(await invalidSeed.textContent("#seed-errors"), /disk\.erase: true/);
    assert.equal(await invalidSeed.evaluate(() => fixtureRequests.some(request => request.command === "plan")), false);
    await screenshot(invalidSeed, "installer-seed-invalid");
    await invalidSeed.click("#seed-guided");
    await invalidSeed.locator("#setup").waitFor({ state: "visible" });
    await invalidSeed.close();

    const seed = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    seed.on("pageerror", error => errors.push(error.message));
    await seed.addInitScript(() => sessionStorage.setItem("fixtureSeed", "valid"));
    await seed.goto(`http://127.0.0.1:${server.address().port}/cockpit/@localhost/cybexos-installer/index.html`);
    await seed.locator("#unattended").waitFor({ state: "visible" });
    await seed.waitForFunction(() => /Installing in 0:\d\d/.test(document.querySelector("#countdown").textContent));
    assert.match(await seed.textContent("#seed-summary"), /lab \(Lab Machine\)/);
    assert.match(await seed.textContent("#seed-summary"), /joins Tailscale at first start/);
    assert.equal(await seed.evaluate(() => fixtureRequests.find(request => request.command === "plan").seed), "fixture-digest");
    await screenshot(seed, "installer-seed-countdown");
    await seed.click("#seed-cancel");
    await seed.waitForFunction(() => document.querySelector("#unattended-title").textContent === "Unattended installation cancelled.");
    assert.equal(await seed.evaluate(() => fixtureRequests.find(request => request.command === "cancel-seed").seed), "fixture-digest");
    await seed.waitForTimeout(11000);
    assert.equal(await seed.evaluate(() => fixtureRequests.some(request => request.command === "install")), false);
    await seed.close();

    assert.deepEqual(errors, []);
    console.log("PASS: three-screen flow, lowercase username, log panel and export, keyboard/locale/timezone choices, encrypted and plain disk paths, rejected-install recovery, erase confirmation, password clearing, progress/reload recovery, narrow layout, install alongside with a resize, new-owner mode, seed countdown, cancel and seed errors");
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
