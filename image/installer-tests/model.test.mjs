import test from "node:test";
import assert from "node:assert/strict";
import {Wizard} from "../live-rootfs/usr/share/cockpit/cybexos-installer/model.mjs";

test("account validation handles mismatch, username and a long non-ASCII phrase", () => {
    const wizard = new Wizard();
    assert.throws(() => wizard.account({username: "Alice", password: "long fixture password", confirm: "long fixture password"}));
    assert.throws(() => wizard.account({username: "alice", password: "long fixture password", confirm: "other"}));
    assert.equal(wizard.account({username: "alice", password: "lang wachtwoord café", confirm: "lang wachtwoord café"}).username, "alice");
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
