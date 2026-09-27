const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");
const { identityLabel, identityOptions } = load("PolkitHelpers.js");

test("Polkit shows the full account name without leaking the other GECOS fields", () => {
    assert.equal(identityLabel({ string: "john", displayName: "John Example,Room 4,555-0100" }),
        "John Example (john)");
    assert.equal(identityLabel({ string: "alice", displayName: "alice" }), "alice");
    assert.equal(identityLabel({ string: "wheel", displayName: "", isGroup: true }), "Group: wheel");
    assert.equal(identityLabel({ id: 0 }), "0");
    assert.equal(identityLabel(null), "");
});

test("identity choices preserve order and distinguish accounts with identical names", () => {
    assert.deepEqual(identityOptions([
        { string: "alice", displayName: "Alice" },
        { string: "admin", displayName: "Alice" }
    ]), [
        { value: 0, label: "Alice (alice)" },
        { value: 1, label: "Alice (admin)" }
    ]);
    assert.deepEqual(identityOptions(null), []);
});
