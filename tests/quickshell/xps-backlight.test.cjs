const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repo = path.resolve(__dirname, "../..");
const read = relative => fs.readFileSync(path.join(repo, relative), "utf8");

test("the affected XPS OLED selects the working Xe VESA backlight path", () => {
    const defaults = read("roles/xps-2026/defaults/main.yml");
    const main = read("roles/xps-2026/tasks/main.yml") + read("roles/xps-2026/tasks/detect.yml");
    const backlight = read("roles/xps-2026/tasks/backlight.yml");
    const verifier = read("tests/verify-system");
    const docs = read("docs/xps-2026-hardware.md");

    assert.match(defaults,
        /xps_2026_vesa_backlight_edid_products:[\s\S]{0,80}?- "30e4"/,
        "the quirk must remain limited to the measured OLED panel");
    assert.match(main,
        /Read the internal-panel EDID product identifier[\s\S]{0,700}?-j8[\s\S]{0,100}?-N2/);
    assert.match(main,
        /import_tasks: backlight[.]yml[\s\S]{0,180}?xps_2026_needs_vesa_backlight \| bool/);

    assert.match(backlight, /argv: \[grubby, --info=ALL\]/,
        "convergence must inspect every installed boot entry");
    assert.match(backlight,
        /--update-kernel=ALL[\s\S]{0,100}?--remove-args=i915[.]enable_dpcd_backlight[\s\S]{0,100}?--args=xe[.]enable_dpcd_backlight=1/);
    const verification = backlight.slice(backlight.indexOf(
        "Refuse an incomplete XPS OLED boot-entry update"));
    assert.ok(verification.includes("i915[.]enable_dpcd_backlight"),
        "the role must verify both the desired argument and removal of the misleading one");
    assert.doesNotMatch(backlight, /i915[.]enable_dpcd_backlight=3/);

    assert.match(verifier, /XPS OLED VESA backlight path is active in this boot/);
    assert.match(verifier, /awaits reboot/,
        "verification must distinguish a staged argument from the currently loaded driver");
    assert.doesNotMatch(verifier, /xe\[\.\]\(enable\|force_probe\)/,
        "the required xe.enable_dpcd_backlight argument must not be called obsolete");
    assert.match(docs, /xe[.]enable_dpcd_backlight=1/);
});
