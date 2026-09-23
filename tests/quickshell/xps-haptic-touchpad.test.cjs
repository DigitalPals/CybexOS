const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");

const repoDir = path.resolve(__dirname, "../..");
const daemon = path.join(repoDir, "roles/xps-2026/files/xps-haptic-touchpad");

// The daemon has no .py suffix; load it as a module without running main().
const LOAD = [
    "import importlib.machinery, importlib.util, json, os, sys",
    `loader = importlib.machinery.SourceFileLoader("haptic", ${JSON.stringify(daemon)})`,
    "spec = importlib.util.spec_from_loader('haptic', loader)",
    "haptic = importlib.util.module_from_spec(spec)",
    "loader.exec_module(haptic)",
].join("\n");

test("the touchpad event mask matches linux/input.h", () => {
    const script = `${LOAD}
print(json.dumps({
    "ioctl": haptic.EVIOCSMASK,
    "size": __import__("struct").calcsize(haptic.INPUT_MASK_FORMAT),
    "keys": haptic.code_bitmap(haptic.PHYSICAL_BUTTONS, haptic.KEY_CNT).hex(),
    "types": haptic.code_bitmap((haptic.EV_SYN, haptic.EV_KEY), haptic.EV_CNT).hex(),
    "fallback": haptic.mask_to_physical_buttons(os.pipe()[0]),
}))`;
    const run = spawnSync("python3", ["-B", "-c", script], { encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    const result = JSON.parse(run.stdout);
    // _IOW('E', 0x93, struct input_mask) with the 16-byte {u32, u32, u64}.
    assert.equal(result.ioctl, 0x40104593);
    assert.equal(result.size, 16);
    // KEY_CNT bits as 64-bit longs: BTN_LEFT/RIGHT/MIDDLE are 0x110-0x112,
    // bits 0-2 of byte 34; nothing else is delivered.
    const keys = Buffer.from(result.keys, "hex");
    assert.equal(keys.length, 96);
    assert.deepEqual([...keys].map((byte, index) => byte ? [index, byte] : null)
        .filter(Boolean), [[34, 0x07]]);
    assert.equal(result.types, "0300000000000000");
    // A descriptor that is not evdev refuses the ioctl; the loop then keeps
    // filtering in userspace instead of failing.
    assert.equal(result.fallback, false);
    assert.match(run.stderr, /filtering in userspace/);
});

function inputEvent(type, code, value) {
    const event = Buffer.alloc(24);
    event.writeUInt16LE(type, 16);
    event.writeUInt16LE(code, 18);
    event.writeInt32LE(value, 20);
    return event;
}

test("systemctl reload reaches the daemon's SIGHUP reapply", () => {
    const unit = fs.readFileSync(path.join(repoDir,
        "roles/xps-2026/templates/xps-haptic-touchpad.service.j2"), "utf8");
    assert.match(unit, /^ExecReload=\/bin\/kill -HUP \$MAINPID$/m);
});

test("the unbounded event loop still wakes for SIGHUP and SIGTERM", async () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "haptic-"));
    let child = null;
    try {
        const events = path.join(tmp, "event");
        const hidraw = path.join(tmp, "hidraw");
        spawnSync("mkfifo", [events]);
        fs.writeFileSync(hidraw, "");
        // apply_features is the HID ioctl; record it instead. A held-open
        // writer keeps the FIFO from reading as a vanished device.
        const script = `${LOAD}
keeper = os.open(${JSON.stringify(events)}, os.O_RDWR)
haptic.configured_intensity = lambda: 50
def apply(fd, intensity):
    print(json.dumps({"apply": intensity}), flush=True)
haptic.apply_features = apply
wakeup = haptic.install_signal_handlers()
haptic.monitor_pair(${JSON.stringify(events)}, ${JSON.stringify(hidraw)}, "phys", wakeup)
print(json.dumps({"stopped": True}), flush=True)`;
        child = spawn("python3", ["-B", "-c", script], { stdio: ["ignore", "pipe", "pipe"] });
        const lines = [];
        let stderr = "";
        child.stdout.setEncoding("utf8");
        child.stdout.on("data", chunk => lines.push(...chunk.split("\n").filter(Boolean)));
        child.stderr.on("data", chunk => { stderr += chunk; });
        const exited = new Promise(resolve => child.on("exit", code => resolve(code)));
        const applies = () => lines.filter(line => line === '{"apply": 50}').length;
        const waitFor = async (predicate, what) => {
            const deadline = Date.now() + 3000;
            while (!predicate()) {
                if (Date.now() > deadline)
                    assert.fail(`timed out waiting for ${what}: ${lines.join(" | ")} ${stderr}`);
                await new Promise(resolve => setTimeout(resolve, 20));
            }
        };

        await waitFor(() => applies() === 1, "the initial apply");
        // A touch frame is ignored; a physical click reapplies the features.
        fs.writeFileSync(events, Buffer.concat([inputEvent(3, 0, 812), inputEvent(0, 0, 0)]));
        fs.writeFileSync(events, Buffer.concat([inputEvent(1, 0x110, 1), inputEvent(0, 0, 0)]));
        await waitFor(() => applies() === 2, "the click reapply");

        child.kill("SIGHUP");
        await waitFor(() => lines.some(line => /Reapplied configured haptic intensity=50/.test(line)),
            "the SIGHUP reload");
        assert.equal(applies(), 3);

        child.kill("SIGTERM");
        const code = await Promise.race([exited,
            new Promise(resolve => setTimeout(() => resolve("hung"), 3000))]);
        assert.equal(code, 0, `SIGTERM did not end poll(-1): ${stderr}`);
        assert.ok(lines.includes('{"stopped": true}'));
    } finally {
        if (child && child.exitCode === null)
            child.kill("SIGKILL");
        fs.rmSync(tmp, { recursive: true, force: true });
    }
});
