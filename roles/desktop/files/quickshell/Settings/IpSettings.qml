pragma ComponentBehavior: Bound
import QtQuick

// One IP version of the selected connection, as its own group: how the
// address is obtained, the address and gateway when they are set by hand,
// and where DNS comes from. Every row edits the page's draft; nothing here
// reaches NetworkManager until the page applies it.
//
// While Automatic DNS is on, NetworkManager uses the servers listed here in
// addition to the ones the network provides; with it off, only these. The
// field is labelled for whichever it is.
//
// The checks below mirror the helper's (scripts/system_settings_network.py)
// closely enough to name a typing mistake on its own row before Apply; the
// helper still validates everything it receives.
SettingsGroup {
    id: root

    property var config: ({method: "auto", addresses: "", gateway: "", dns: "", autoDns: true})
    signal edited(var value)

    readonly property bool v6: title === "IPv6"
    readonly property bool manual: config.method === "manual"
    readonly property bool inUse: config.method !== "disabled"
    readonly property string addressProblem: !manual ? "" : root.check(config.addresses, true, 16)
    readonly property string gatewayProblem: !manual ? "" : root.check(config.gateway, false, 1)
    readonly property string dnsProblem: !inUse ? "" : root.check(config.dns, false, 16)
    // Not a typing mistake, so the empty field is not outlined; the Apply
    // bar still names it.
    readonly property string missingAddress: manual && root.entries(config.addresses).length === 0
        ? "Manual needs at least one address with its prefix" : ""
    // The first problem, for the page's Apply bar.
    readonly property string problem: {
        const first = addressProblem || missingAddress || gatewayProblem || dnsProblem;
        return first === "" ? "" : title + ": " + first.charAt(0).toLowerCase() + first.slice(1);
    }

    function change(key, value) {
        const next = Object.assign({}, config);
        next[key] = value;
        edited(next);
    }

    function entries(text) {
        return String(text || "").split(/[,\s]+/).filter(part => part !== "");
    }

    function validAddress(text) {
        if (!root.v6) {
            const octet = "(25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)";
            return new RegExp("^" + octet + "(\\." + octet + "){3}$").test(text);
        }
        // Loose on purpose: the helper's ipaddress parse is the authority.
        return /^[0-9a-f:.]+$/i.test(text) && (text.match(/:/g) || []).length >= 2;
    }

    // "" or why `text` is not a list of at most `limit` addresses of this
    // IP version, each with a prefix when `prefixed`.
    function check(text, prefixed, limit) {
        const list = root.entries(text);
        if (list.length > limit)
            return limit === 1 ? "Enter one gateway" : "Enter at most " + limit + " addresses";
        for (const entry of list) {
            const slash = entry.indexOf("/");
            if (prefixed && slash < 0)
                return "Add a prefix to " + entry + ", such as " + (root.v6 ? "/64" : "/24");
            const address = prefixed ? entry.slice(0, slash) : entry;
            const prefix = prefixed ? Number(entry.slice(slash + 1)) : 0;
            if (!root.validAddress(address) || (prefixed && !(Number.isInteger(prefix)
                    && prefix >= 0 && prefix <= (root.v6 ? 128 : 32))))
                return entry + " is not an " + root.title + " address";
        }
        return "";
    }

    PickerRow {
        width: parent.width
        label: "Method"
        current: root.config.method
        model: [{value: "auto", label: "Automatic"}, {value: "manual", label: "Manual"},
            {value: "disabled", label: "Disabled"}]
        onPicked: value => root.change("method", value)
    }
    DraftFieldRow {
        width: parent.width
        visible: root.manual
        label: "Address"
        value: root.config.addresses
        placeholder: root.v6 ? "2001:db8::20/64" : "192.168.1.20/24"
        invalid: root.addressProblem !== ""
        hint: root.addressProblem !== "" ? root.addressProblem
            : "With its prefix; separate several with commas"
        onEdited: text => root.change("addresses", text)
    }
    DraftFieldRow {
        width: parent.width
        visible: root.manual
        label: "Gateway"
        value: root.config.gateway
        placeholder: root.v6 ? "2001:db8::1" : "192.168.1.1"
        invalid: root.gatewayProblem !== ""
        hint: root.gatewayProblem !== "" ? root.gatewayProblem : "Optional"
        onEdited: text => root.change("gateway", text)
    }
    SwitchRow {
        width: parent.width
        visible: root.inUse
        label: "Automatic DNS"
        checked: root.config.autoDns
        description: "Use the DNS servers the network provides"
        onToggled: value => root.change("autoDns", value)
    }
    DraftFieldRow {
        width: parent.width
        visible: root.inUse
        label: root.config.autoDns ? "Additional DNS" : "DNS servers"
        value: root.config.dns
        placeholder: root.v6 ? "2606:4700:4700::1111" : "1.1.1.1, 9.9.9.9"
        invalid: root.dnsProblem !== ""
        hint: root.dnsProblem !== "" ? root.dnsProblem
            : root.config.autoDns ? "Used alongside the network's own servers; separate several with commas"
            : "Separate several with commas"
        onEdited: text => root.change("dns", text)
    }
}
