#!/usr/bin/env node
// Source-only browser test. The Cockpit transport is a fixture: no installer,
// disk, VM, ISO, or system service is contacted. See README for dependencies.
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require("playwright-core");
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
      fixtureRequests.push({ command, hasPassword: !!data.password });
      let result;
      if (command === "status") result = { phase: fixturePhase, message: "Fixture progress" };
      else if (command === "inventory") result = {
        disks: [{ name: "vda", path: "/dev/vda", size: 107374182400, model: "Fixture NVMe" }],
        keyboards: [{ id: "us", label: "English (US)" }, { id: "nl", label: "Dutch" }],
        locales: ["en_US.UTF-8", "nl_NL.UTF-8"], locale: "en_US.UTF-8",
        keyboard: "us", timezone: "Europe/Amsterdam"
      };
      else if (command === "keyboard") result = { keyboard: data.keyboard, boot_keyboard: data.keyboard };
      else if (command === "plan") result = {
        phase: "review", token: "fixture-token",
        disk: { name: "vda", path: "/dev/vda", model: "Fixture NVMe" },
        account: { username: data.username, encrypted: data.encrypted,
                   locale: data.locale, timezone: data.timezone },
        boot_keyboard: data.keyboard,
        actions: [{ "action-description": "Create", "object-description": "encrypted Btrfs", "device-name": "vda" }],
        warnings: []
      };
      else if (command === "install") {
        fixturePhase = "installing";
        sessionStorage.setItem("fixturePhase", fixturePhase);
        result = { phase: "installing" };
        setTimeout(() => {
          fixturePhase = "complete";
          sessionStorage.setItem("fixturePhase", fixturePhase);
        }, 100);
      } else result = { phase: "setup" };
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
      if (!["index.html", "installer.css", "installer.js", "model.mjs"].includes(file)) {
        response.writeHead(404).end();
        return;
      }
      response.setHeader("Content-Type", file.endsWith(".html") ? "text/html"
        : file.endsWith(".css") ? "text/css" : "text/javascript");
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
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    await page.emulateMedia({ reducedMotion: "reduce" });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/cockpit/@localhost/cybexos-installer/index.html`);
    await page.locator("#setup").waitFor({ state: "visible" });
    await page.waitForFunction(() => !document.querySelector("#password").disabled);
    await screenshot(page, "installer-setup");
    await page.fill("#username", "alice");
    await page.fill("#password", "fixture secret 123");
    await page.fill("#confirm", "fixture secret 123");
    await page.selectOption("#keyboard", "nl");
    await page.waitForFunction(() => !document.querySelector("#password").disabled);
    assert.equal(await page.inputValue("#password"), "");
    assert.equal(await page.inputValue("#confirm"), "");
    await page.fill("#keyboard-test", "ordinary test characters");
    await page.fill("#password", "fixture secret 123");
    await page.fill("#confirm", "fixture secret 123");
    await page.getByRole("button", { name: "Choose install location" }).click();
    await page.locator("#location").waitFor({ state: "visible" });
    assert.equal(await page.isChecked("#encrypted"), true);
    await page.selectOption("#disk", "vda");
    await page.getByRole("button", { name: "Review installation" }).click();
    await page.locator("#review").waitFor({ state: "visible" });
    assert.equal(await page.isDisabled("#install"), true);
    await screenshot(page, "installer-review");
    await page.check("#erase");
    await page.click("#install");
    await page.getByRole("heading", { name: "Your workspace is ready." }).waitFor({ timeout: 10000 });
    assert.equal(await page.inputValue("#password"), "");
    assert.equal(await page.inputValue("#confirm"), "");
    assert.equal(await page.evaluate(() => fixtureRequests.filter(request => request.command === "install").length), 1);
    await page.reload();
    await page.getByRole("heading", { name: "Your workspace is ready." }).waitFor();
    await page.setViewportSize({ width: 390, height: 844 });
    await screenshot(page, "installer-narrow");
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);
    assert.deepEqual(errors, []);
    console.log("PASS: three-screen flow, keyboard change, encryption default, erase confirmation, password clearing, progress/reload recovery, narrow layout");
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
