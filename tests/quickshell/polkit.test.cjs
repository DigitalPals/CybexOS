const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");
const { identityLabel, identityOptions, authenticationCue, cueText } = load("PolkitHelpers.js");

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

test("fingerprint and security-key steps are recognised from PAM's own words", () => {
    for (const message of ["Place your finger on the fingerprint reader",
        "Swipe your right index finger across the fingerprint reader",
        "Place your left thumb on Goodix MOC Fingerprint Sensor",
        "Failed to match fingerprint",
        "Your finger was not centered, try touching the sensor again"])
        assert.equal(authenticationCue(message), "fingerprint", message);
    for (const message of ["Touch your security key", "Please touch the FIDO authenticator.",
        "Please touch the device."])
        assert.equal(authenticationCue(message), "securityKey", message);
    for (const message of ["", null, "Password: ", "Authentication failure",
        "You are required to change your password immediately"])
        assert.equal(authenticationCue(message), "", String(message));
});

test("a sequential PAM step is described honestly", () => {
    // pam_fprintd and pam_u2f block until they give up; the password field
    // follows, so the dialog cannot offer both at once.
    assert.equal(cueText("fingerprint", false), "Touch the fingerprint reader, or wait to enter your password.");
    assert.equal(cueText("fingerprint", true),
        "Not recognised. Touch the fingerprint reader, or wait to enter your password.");
    assert.equal(cueText("securityKey", false), "Touch your security key, or wait to enter your password.");
    assert.equal(cueText("", false), "");
});
