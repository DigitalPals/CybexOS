import test from "node:test";
import assert from "node:assert/strict";
import {Wizard, GiB, systemsLabel, clampSpace, shrinkFor, countdownText, reviewFields, confirmationCopy}
    from "../live-rootfs/usr/share/cockpit/cybexos-installer/model.mjs";

test("account validation handles mismatch, username and a long non-ASCII phrase", () => {
    const wizard = new Wizard();
    assert.throws(() => wizard.account({username: "Alice", password: "long fixture password", confirm: "long fixture password"}));
    assert.throws(() => wizard.account({username: "alice", password: "long fixture password", confirm: "other"}));
    assert.equal(wizard.account({username: "alice", password: "lang wachtwoord café", confirm: "lang wachtwoord café"}).username, "alice");
    for (const username of ["root", "liveuser", "sddm", "chrony"]) {
        assert.throws(() => wizard.account({username, password: "long fixture password", confirm: "long fixture password"}), /reserved/);
    }
    for (const password of ["long\nfixture password", "x".repeat(513)]) {
        assert.throws(() => wizard.account({username: "alice", password, confirm: password}));
    }
});
test("review and installation require a plan and explicit erase confirmation", () => {
    const wizard = new Wizard();
    assert.throws(() => wizard.move("review"));
    wizard.plan = {token: "fixture", disk: {name: "vda"}};
    wizard.move("review");
    assert.throws(() => wizard.confirmation(false));
    assert.deepEqual(wizard.confirmation(true), {token: "fixture", confirmed_disk: "vda", erase_confirmed: true});
    wizard.move("location");
    assert.equal(wizard.plan, null);
});
test("failed operations release busy state and permit correction/retry", async () => {
    const wizard = new Wizard();
    await assert.rejects(wizard.operation(async () => {throw new Error("fixture failure");}));
    assert.equal(wizard.busy, false);
    assert.equal(await wizard.operation(async () => "retried"), "retried");
});
test("navigation is locked during an operation or installation", async () => {
    const wizard = new Wizard();
    await wizard.operation(async () => assert.throws(() => wizard.move("location")));
    wizard.page = "progress";
    assert.throws(() => wizard.move("setup"));
});
test("a new-owner installation needs no account, only the temporary disk passphrase", () => {
    const wizard = new Wizard();
    assert.equal(wizard.account({oem: true, username: "", password: "handover phrase 1", confirm: "handover phrase 1"}).oem, true);
    assert.throws(() => wizard.account({oem: true, password: "short", confirm: "short"}), /passphrase of 12/);
    assert.throws(() => wizard.account({oem: true, password: "handover phrase 1", confirm: "other phrase 12"}), /passphrases do not match/);
    // Without new-owner mode the account is still required.
    assert.throws(() => wizard.account({username: "", password: "handover phrase 1", confirm: "handover phrase 1"}), /username/);
});
test("installing alongside confirms the resize, not an erase", () => {
    const wizard = new Wizard();
    wizard.plan = {token: "fixture", disk: {name: "vdb"}, layout: {mode: "alongside", resize: {path: "/dev/vdb3"}}};
    wizard.move("review");
    assert.deepEqual(wizard.confirmation(true), {token: "fixture", confirmed_disk: "vdb", alongside_confirmed: true});
    assert.match(confirmationCopy(wizard.plan).check, /\/dev\/vdb3 will be resized/);
    assert.equal(confirmationCopy(wizard.plan).button, "Resize and install");
    assert.equal(confirmationCopy({layout: {mode: "alongside"}}).button, "Install alongside");
    assert.equal(confirmationCopy({layout: {mode: "erase"}}).button, "Erase disk and install");
    assert.equal(confirmationCopy(null).button, "Erase disk and install");
});
test("the size slider shrinks only the offered partition and keeps its floor", () => {
    const options = {mode: "shrink", free: 10 * GiB, min_space: 64 * GiB, max_space: 305 * GiB, floor: 105 * GiB,
        partition: {id: "vdb3", size: 400 * GiB}};
    assert.equal(clampSpace(options, 1), 64 * GiB);
    assert.equal(clampSpace(options, 999 * GiB), 305 * GiB);
    assert.equal(clampSpace(options, 100.4 * GiB), 100 * GiB);
    assert.deepEqual(shrinkFor(options, 100 * GiB), {device: "vdb3", size: 310 * GiB});
    assert.deepEqual(shrinkFor(options, 305 * GiB), {device: "vdb3", size: 105 * GiB});
    assert.equal(shrinkFor({mode: "free", free: 200 * GiB}, 100 * GiB), null);
    assert.equal(shrinkFor(null, 1), null);
});
test("labels, countdown and review copy are plain and exact", () => {
    assert.equal(systemsLabel(["Windows"]), "Windows");
    assert.equal(systemsLabel(["Windows", "Linux", "macOS"]), "Windows, Linux and macOS");
    assert.equal(systemsLabel([]), "");
    assert.equal(countdownText(30), "Installing in 0:30");
    assert.equal(countdownText(61.2), "Installing in 1:02");
    assert.equal(countdownText(-4), "Installing in 0:00");
    const identity = disk => disk.path;
    const alongside = Object.fromEntries(reviewFields({
        disk: {path: "/dev/vdb"}, boot_keyboard: "us",
        account: {username: "alice", encrypted: true, locale: "en_US.UTF-8", timezone: "UTC"},
        layout: {mode: "alongside", systems: ["Windows"], space: 90 * GiB, kept: ["/dev/vdb1"],
            resize: {path: "/dev/vdb3", filesystem: "ntfs", from: 400 * GiB, to: 310 * GiB}}}, identity));
    assert.equal(alongside["Resized"], "/dev/vdb3 (ntfs) from 400.0 GiB to 310.0 GiB");
    assert.equal(alongside["New for CybexOS"], "90.0 GiB of freed space");
    assert.match(alongside["Unchanged"], /\/dev\/vdb1; the EFI system partition is shared/);
    assert.match(alongside["Install location"], /Alongside Windows/);
    const owner = Object.fromEntries(reviewFields({
        disk: {path: "/dev/vda"}, boot_keyboard: "us",
        account: {oem: true, username: "", encrypted: true, locale: "en_US.UTF-8", timezone: "UTC"}}, identity));
    assert.equal(owner["Account"], "Created by the new owner at first start");
    assert.equal(owner["At startup"], "Temporary passphrase → new-owner setup");
    assert.equal(owner["Install location"], "Erase the entire disk");
    assert.match(owner["Sudo"], /new owner's password/);
});
test("a countdown page cannot be left through normal navigation", () => {
    const wizard = new Wizard();
    wizard.page = "unattended";
    assert.throws(() => wizard.move("setup"));
});
