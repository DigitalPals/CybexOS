// Identity names come from NSS; GECOS may also contain phone/office fields.
function identityLabel(identity) {
    if (!identity)
        return "";
    const login = String(identity.string || identity.name || (identity.id ?? ""));
    const display = String(identity.displayName || login).split(",")[0].trim() || login;
    const label = display === login ? login : display + " (" + login + ")";
    return identity.isGroup ? "Group: " + label : label;
}

if (typeof module !== "undefined" && module.exports)
    module.exports = { identityLabel, identityOptions, authenticationCue, cueText };

function identityOptions(identities) {
    return (identities || []).map((identity, index) => ({
        value: index, label: identityLabel(identity)
    }));
}

// PAM announces a fingerprint or security-key step with a message and no
// input request: pam_fprintd's "Place your finger on the fingerprint reader"
// (or "Swipe…", "Failed to match fingerprint"), and pam_u2f's cue, "Touch your
// security key" in the NerdOS stacks or its stock "Please touch the FIDO
// authenticator.". Returns "fingerprint", "securityKey" or "".
function authenticationCue(message) {
    const text = String(message || "").toLowerCase();
    if (/\bfinger|fingerprint|\bswipe\b/.test(text))
        return "fingerprint";
    if (/security key|\bfido\b|\bu2f\b|authenticator|touch the device|touch your key/.test(text))
        return "securityKey";
    return "";
}

// The dialog's words for that step. The stacks are sequential (pam_fprintd
// and pam_u2f wait for a touch, then hand over), so the password field
// follows rather than sits beside them: say so instead of showing a field
// that cannot take input yet. `retry` follows a scan that did not match.
function cueText(cue, retry) {
    if (cue === "fingerprint")
        return (retry ? "Not recognised. " : "")
            + "Touch the fingerprint reader, or wait to enter your password.";
    if (cue === "securityKey")
        return "Touch your security key, or wait to enter your password.";
    return "";
}
