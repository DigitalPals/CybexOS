const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const repo = path.resolve(__dirname, "../..");
const read = relative => fs.readFileSync(path.join(repo, relative), "utf8");

// The text of one top-level task, from its name to the next task.
function task(source, name) {
    const start = source.indexOf(`- name: ${name}`);
    assert.ok(start >= 0, `missing task: ${name}`);
    const end = source.indexOf("\n- name:", start + 1);
    return source.slice(start, end < 0 ? undefined : end);
}

test("Ansible pipelines modules and keeps notified handlers after a failure", () => {
    const config = read("ansible.cfg");
    const section = name => {
        const start = config.indexOf(`[${name}]`);
        const end = config.indexOf("\n[", start + 1);
        return config.slice(start, end < 0 ? undefined : end);
    };
    assert.match(section("defaults"), /^force_handlers = True$/m,
        "a retry after a failure must not lose an initramfs rebuild or restart");
    assert.match(section("connection"), /^pipelining = True$/m);
    assert.match(read("roles/base/tasks/main.yml"),
        /Reconcile firewalld's runtime view with permanent configuration/,
        "an interrupted run still loses handlers, so the firewalld repair stays");
});
