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
    module.exports = { identityLabel, identityOptions };

function identityOptions(identities) {
    return (identities || []).map((identity, index) => ({
        value: index, label: identityLabel(identity)
    }));
}
