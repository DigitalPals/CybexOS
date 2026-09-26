#!/usr/bin/env node
// Drives the guest's real Cockpit/Anaconda page through an SSH tunnel.
// Fixture credentials arrive on stdin and are never printed or saved.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const {chromium} = require("playwright-core");
let secret = "";

async function main() {
    const input = JSON.parse(fs.readFileSync(0, "utf8"));
    secret = input.password;
    const url = new URL(input.url);
    assert.equal(url.hostname, "127.0.0.1");
    assert.equal(url.pathname, "/cockpit/@localhost/cybexos-installer/index.html");
    assert.match(input.target_disk, /^[A-Za-z0-9_-]+$/);
    assert.match(input.target_serial, /^CYBEXOS-QUALIFY$/);
    assert.match(input.unused_disk, /^[A-Za-z0-9_-]+$/);
    assert.notEqual(input.target_disk, input.unused_disk);
    const browser = await chromium.launch({executablePath: input.browser, headless: true,
        args: ["--disable-dev-shm-usage"]});
    try {
        const page = await browser.newPage({viewport: {width: 1280, height: 900}});
        // The guest remains offline; the browser may only talk to its tunnel.
        await page.route("**/*", route => {
            const request = new URL(route.request().url());
            return request.hostname === "127.0.0.1" && request.port === url.port
                ? route.continue() : route.abort();
        });
        await page.goto(input.url, {waitUntil: "domcontentloaded", timeout: 30000});
        await page.locator("#setup").waitFor({state: "visible", timeout: 120000});
        await page.waitForFunction(() => !document.querySelector("#password").disabled);
        await page.selectOption("#keyboard", input.keyboard);
        await page.waitForFunction(expected => document.querySelector("#keyboard").value === expected &&
            !document.querySelector("#password").disabled, input.keyboard);
        await page.fill("#username", "qualification");
        await page.fill("#password", input.password);
        await page.fill("#confirm", input.password);
        await page.locator("#account-form details > summary").click();
        await page.selectOption("#locale", input.locale);
        await page.selectOption("#timezone", input.timezone);
        const sudo = page.locator("#passwordless-wheel");
        if (input.require_policy_controls) {
            assert.equal(await sudo.count(), 1, "Sudo policy choice is missing");
            assert.equal(await sudo.isChecked(), false, "Sudo must require a password by default");
        }
        if (await sudo.count()) assert.equal(await sudo.isChecked(), false);
        await page.locator("#account-form button[type=submit]").click();
        await page.locator("#location").waitFor({state: "visible"});
        const rescan = page.locator("#rescan-disks");
        if (input.require_policy_controls) assert.equal(await rescan.count(), 1, "Disk rescan is missing");
        if (await rescan.count()) {
            await rescan.click();
            await page.waitForFunction(() => !document.querySelector("#rescan-disks").disabled);
            assert.equal(await page.inputValue("#disk"), "");
        }
        const options = await page.locator("#disk option").evaluateAll(items => items.map(item => item.value));
        assert(options.includes(input.target_disk), "Expected target disk is absent from selector");
        assert(options.includes(input.unused_disk), "Unused guard disk is absent from selector");
        await page.selectOption("#disk", input.target_disk);
        const details = page.locator("#disk-details");
        if (input.require_policy_controls) {
            assert.match(await details.textContent(), /CYBEXOS-QUALIFY/);
            assert.match(await details.textContent(), /Existing partitions:/);
        }
        await page.locator("#disk-form details > summary").click();
        const encrypted = page.locator("#encrypted");
        assert.equal(await encrypted.isChecked(), true);
        if (!input.encrypted) await encrypted.uncheck();
        await page.locator("#disk-form button[type=submit]").click();
        await page.locator("#review").waitFor({state: "visible", timeout: 180000});
        const summary = await page.locator("#summary").textContent();
        assert.match(summary, /qualification/);
        if (input.require_policy_controls) {
            assert.match(summary, /CYBEXOS-QUALIFY/);
            assert.match(summary, /ask for your account password/);
        }
        assert.match(summary, input.encrypted ? /Encrypted Btrfs/ : /unencrypted/);
        assert.equal(await page.locator("#install").isDisabled(), true);
        await page.check("#erase");
        await page.click("#install");
        await page.locator("#progress").waitFor({state: "visible"});
        await page.getByRole("heading", {name: "Your workspace is ready."}).waitFor({timeout: input.install_timeout_ms});
        assert.equal(await page.inputValue("#password"), "");
        assert.equal(await page.inputValue("#confirm"), "");
        process.stdout.write(JSON.stringify({check: "graphical-installer", selected_disk: input.target_disk,
            encrypted: input.encrypted, keyboard: input.keyboard, locale: input.locale}) + "\n");
    } finally {
        await browser.close();
    }
}

main().catch(error => {
    const detail = String(error.stack || error);
    const redacted = secret ? detail.replaceAll(secret, "[redacted]") : detail;
    process.stderr.write(`Graphical installer qualification failed: ${redacted}\n`);
    process.exitCode = 1;
});
