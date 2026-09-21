const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

const battery = fs.readFileSync(
    path.join(shellDir, "Popovers/BatteryPopover.qml"), "utf8");

test("battery popover keeps the hero, meter, telemetry, profile hierarchy", () => {
    const hero = battery.indexOf("id: hero");
    const rail = battery.indexOf("id: chargeMeter");
    const telemetry = battery.indexOf('text: "BATTERY TELEMETRY"');
    const health = battery.indexOf('text: "BATTERY HEALTH"');
    const profile = battery.indexOf('text: "POWER PROFILE"');

    assert.ok(hero >= 0, "battery hero is missing");
    assert.ok(hero < rail && rail < telemetry && telemetry < health
        && health < profile,
        "battery sections must retain their visual reading order");
    assert.match(battery, /id:\s*heroGlyph[\s\S]{0,180}?name:\s*root\.batteryGlyph/);
    assert.match(battery,
        /batteryGlyph:[\s\S]{0,420}?battery_full[\s\S]{0,360}?battery_1_bar/,
        "the hero glyph must reflect charge level");
    assert.match(battery,
        /statusText:\s*Battery\.full \? "Fully charged"[\s\S]{0,100}?"Charging"[\s\S]{0,80}?"On battery"/);
    assert.match(battery,
        /id:\s*heroNumber[\s\S]{0,260}?font\.pixelSize:\s*Theme\.typography\.displayLarge[\s\S]{0,160}?font\.features:\s*Theme\.tabularNumberFeatures/);
});

test("battery health is a capability-driven accessible UPower control", () => {
    assert.match(battery,
        /id:\s*batteryHealthSection[\s\S]{0,140}?visible:\s*BatteryHealth\.known && BatteryHealth\.supported/);
    assert.match(battery, /text:\s*"Preserve battery health"/);
    assert.match(battery, /BatteryHealth\.enabled \? BatteryHealth\.limitText\s*:\s*"Charge to 100%"/);
    assert.match(battery,
        /id:\s*healthToggle[\s\S]{0,260}?checked:\s*BatteryHealth\.enabled[\s\S]{0,140}?accessibleName:\s*"Preserve battery health"[\s\S]{0,120}?BatteryHealth\.setEnabled\(value\)/);
    assert.match(battery, /BatteryHealth\.acquire\(\)/);
    assert.match(battery, /BatteryHealth\.release\(\)/);
});

test("battery charge matches the animated blocked usage meter with discharge-only warnings", () => {
    assert.doesNotMatch(battery, /id:\s*charge(?:Track|Fill)/);
    assert.match(battery,
        /BlockMeter\s*\{[\s\S]{0,100}?id:\s*chargeMeter[\s\S]{0,160}?height:\s*10[\s\S]{0,100}?value:\s*root\.chargeFraction[\s\S]{0,100}?fillColor:\s*root\.batteryTone/);
    assert.match(battery,
        /Behavior on value\s*\{[\s\S]{0,120}?NumberAnimation[\s\S]{0,100}?duration:\s*Theme\.reducedMotion \? 0 : 320/);
    assert.match(battery,
        /SequentialAnimation on opacity\s*\{[\s\S]{0,100}?running:\s*Battery\.charging && !Theme\.reducedMotion/,
        "reduced-motion mode must stop the charging pulse rather than busy-loop at zero duration");
    assert.match(battery,
        /critical:\s*discharging[\s\S]{0,100}?Settings\.modOpts\.batt\.critAt/);
    assert.match(battery,
        /warning:\s*discharging[\s\S]{0,130}?Settings\.modOpts\.batt\.warnAt/);
    assert.match(battery,
        /batteryTone:\s*critical \? Theme\.red[\s\S]{0,80}?warning \? Theme\.amber[\s\S]{0,60}?Theme\.accent/);
    assert.match(battery,
        /SequentialAnimation on opacity\s*\{[\s\S]{0,100}?running:\s*Battery\.charging[\s\S]{0,80}?loops:\s*Animation\.Infinite/);
});

test("battery telemetry is stable, aggregate, and cycle aware", () => {
    assert.match(battery, /displayDevice:\s*UPower\.displayDevice/);
    assert.match(battery, /displayDevice\.energyCapacity/);
    assert.match(battery, /displayDevice\.changeRate/);
    assert.match(battery, /displayDevice\.timeToFull/);
    assert.match(battery, /displayDevice\.timeToEmpty/);
    for (const label of ["Capacity", "Cycles", "Time to full", "Time remaining",
        "Charge rate", "Discharge rate"]) {
        assert.ok(battery.includes(`"${label}"`), `${label} telemetry is missing`);
    }
    assert.match(battery, /BAT\*\/cycle_count/);
    assert.match(battery, /LC_ALL=C sort/);
    assert.match(battery, /running:\s*true/,
        "cycle counts should be read once with the popover instance");
    assert.match(battery, /BatteryView\.parseCycleCounts\(text\)/);
});

test("power profiles form one accessible keyboard-operated segmented radio", () => {
    assert.match(battery,
        /id:\s*profileTrack[\s\S]*?id:\s*profileRow[\s\S]*?id:\s*profileRepeater/);
    for (const glyph of ["eco", "balance", "speed"])
        assert.match(battery, new RegExp(`glyph: "${glyph}"`));
    assert.match(battery, /available:\s*PowerProfiles\.hasPerformanceProfile/);
    assert.match(battery, /current \? Theme\.chipHover[\s\S]{0,100}?profileMouse\.containsMouse \? Theme\.tile/);
    assert.match(battery, /Accessible\.role:\s*Accessible\.RadioButton/);
    assert.match(battery, /Accessible\.name:/);
    assert.match(battery, /Accessible\.checked:\s*current/);
    assert.match(battery, /Accessible\.onPressAction:/);
    assert.match(battery, /activeFocusOnTab:/);
    assert.match(battery, /Keys\.onPressed:/);
    assert.match(battery, /Qt\.Key_Left/);
    assert.match(battery, /Qt\.Key_Right/);
    assert.match(battery, /Qt\.Key_Return/);
    assert.match(battery, /PowerProfiles\.profile =/);
});

test("battery status copy does not rotate playful phrases", () => {
    assert.doesNotMatch(battery,
        /Pumping power|Injecting electrons|Pouring juice|Slurping power|Spending joules|phrase(?:Index|Timer)|rotatingPhrases/i);
});
