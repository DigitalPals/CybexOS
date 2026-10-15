// Pure state and validation shared by the real UI and fixture tests.
const reserved = new Set(["root", "liveuser", "bin", "daemon", "adm", "mail", "ftp", "nobody",
    "dbus", "systemd", "gdm", "sddm", "sshd", "polkitd", "chrony"]);
export const GiB = 1024 ** 3;
const MiB = 1024 ** 2;

export class Wizard {
    constructor() { this.page = "setup"; this.busy = false; this.plan = null; }
    move(page) {
        if (this.busy || this.page === "progress" || this.page === "unattended") throw new Error("An installation operation is still running.");
        if (!["setup", "location", "review"].includes(page)) throw new Error("Unknown setup page.");
        if (page === "review" && !this.plan) throw new Error("Review the disk before installing.");
        if (page !== "review") this.plan = null;
        this.page = page;
    }
    async operation(work) {
        if (this.busy) throw new Error("An installation operation is still running.");
        this.busy = true;
        try { return await work(); } finally { this.busy = false; }
    }
    account(data) {
        // A new-owner installation has no account yet; its passphrase is the
        // temporary disk passphrase the new owner replaces at first start.
        const what = data.oem ? "passphrase" : "password";
        if (!data.oem && (typeof data.username !== "string" || !/^[a-z_][a-z0-9_-]{0,30}$/.test(data.username) || reserved.has(data.username)))
            throw new Error("Choose a username of 1–31 lowercase letters, numbers, underscores or dashes, starting with a letter. System names are reserved.");
        if (typeof data.password !== "string" || Array.from(data.password).length < 12 || Array.from(data.password).length > 512)
            throw new Error(`Use a ${what} of 12–512 characters.`);
        if (/[\x00-\x1f\x7f]/.test(data.password)) throw new Error(`The ${what} cannot contain control characters.`);
        if (data.password !== data.confirm) throw new Error(`The ${what}s do not match.`);
        return data;
    }
    confirmation(checked) {
        if (this.page !== "review" || !this.plan || !checked) throw new Error("Confirm the selected disk before installing.");
        const confirmed = this.plan.layout?.mode === "alongside" ? {alongside_confirmed: true} : {erase_confirmed: true};
        return {token: this.plan.token, confirmed_disk: this.plan.disk.name, ...confirmed};
    }
}

export function size(bytes) {
    return Number.isFinite(Number(bytes)) ? `${(Number(bytes) / GiB).toFixed(1)} GiB` : "Unknown size";
}

// "Windows", "Windows and Linux", "Windows, Linux and macOS".
export function systemsLabel(systems) {
    const names = (systems || []).filter(name => typeof name === "string" && name);
    if (names.length < 2) return names[0] || "";
    return `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
}

// The CybexOS space the slider may choose, rounded to whole GiB inside the
// range the backend offered.
export function clampSpace(options, value) {
    const low = options.min_space, high = options.max_space;
    const chosen = Math.round(Number(value) / GiB) * GiB;
    return Math.min(high, Math.max(low, Number.isFinite(chosen) ? chosen : low));
}

// The single shrink request for a chosen CybexOS size, or null when free
// space suffices. The partition keeps everything CybexOS does not take.
export function shrinkFor(options, space) {
    if (!options || options.mode !== "shrink") return null;
    const taken = clampSpace(options, space) - options.free;
    const target = Math.floor((options.partition.size - taken) / MiB) * MiB;
    return {device: options.partition.id, size: Math.max(options.floor, target)};
}

export function countdownText(seconds) {
    const value = Math.max(0, Math.ceil(seconds));
    return `Installing in ${Math.floor(value / 60)}:${String(value % 60).padStart(2, "0")}`;
}

// The review's summary rows; every value is plain text for textContent.
export function reviewFields(plan, diskIdentity) {
    const account = plan.account, layout = plan.layout || {mode: "erase"};
    const fields = [["Disk", diskIdentity(plan.disk)]];
    if (layout.mode === "alongside") {
        const others = systemsLabel(layout.systems) || "the existing systems";
        fields.push(["Install location", `Alongside ${others}. The boot menu lists every system.`]);
        if (layout.resize)
            fields.push(["Resized", `${layout.resize.path}${layout.resize.filesystem ? ` (${layout.resize.filesystem})` : ""} from ${size(layout.resize.from)} to ${size(layout.resize.to)}`]);
        fields.push(["New for CybexOS", `${size(layout.space)} of ${layout.resize ? "freed" : "free"} space`]);
        fields.push(["Unchanged", (layout.kept || []).length ? `${layout.kept.join(", ")}; the EFI system partition is shared` : "Every other partition"]);
    } else {
        fields.push(["Install location", "Erase the entire disk"]);
    }
    fields.push(["Account", account.oem ? "Created by the new owner at first start" : account.username]);
    fields.push(["Storage", account.encrypted ? "Encrypted Btrfs · LUKS2" : "Btrfs · unencrypted"]);
    fields.push(["At startup", account.oem
        ? (account.encrypted ? "Temporary passphrase → new-owner setup" : "New-owner setup")
        : (account.encrypted ? "Unlock your disk → automatic login" : "Sign in to your account")]);
    fields.push(["Sudo", account.passwordless_wheel ? "Administrator commands do not ask for a password"
        : account.oem ? "Administrator commands ask for the new owner's password"
            : "Administrator commands ask for your account password"]);
    fields.push(["Boot keyboard", plan.boot_keyboard], ["Language", account.locale], ["Timezone", account.timezone]);
    return fields;
}

// The review's confirmation copy for each layout.
export function confirmationCopy(plan) {
    const layout = plan?.layout || {mode: "erase"};
    if (layout.mode !== "alongside")
        return {check: "I understand that all data on the selected disk will be erased.", button: "Erase disk and install"};
    if (layout.resize)
        return {check: `I have a backup, and I understand that ${layout.resize.path} will be resized.`, button: "Resize and install"};
    return {check: "I understand that CybexOS will be installed in the free space of this disk.", button: "Install alongside"};
}
