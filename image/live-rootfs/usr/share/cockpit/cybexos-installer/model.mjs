// Pure state and validation shared by the real UI and fixture tests.
const reserved = new Set(["root", "liveuser", "bin", "daemon", "adm", "mail", "ftp", "nobody",
    "dbus", "systemd", "gdm", "sddm", "sshd", "polkitd", "chrony"]);
export class Wizard {
    constructor() { this.page = "setup"; this.busy = false; this.plan = null; }
    move(page) {
        if (this.busy || this.page === "progress") throw new Error("An installation operation is still running.");
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
        if (typeof data.username !== "string" || !/^[a-z_][a-z0-9_-]{0,30}$/.test(data.username) || reserved.has(data.username))
            throw new Error("Choose a username of 1–31 lowercase letters, numbers, underscores or dashes, starting with a letter. System names are reserved.");
        if (typeof data.password !== "string" || Array.from(data.password).length < 12 || Array.from(data.password).length > 512)
            throw new Error("Use a password of 12–512 characters.");
        if (/[\x00-\x1f\x7f]/.test(data.password)) throw new Error("The password cannot contain control characters.");
        if (data.password !== data.confirm) throw new Error("The passwords do not match.");
        return data;
    }
    confirmation(checked) {
        if (this.page !== "review" || !this.plan || !checked) throw new Error("Confirm the selected disk before installing.");
        return {token: this.plan.token, confirmed_disk: this.plan.disk.name, erase_confirmed: true};
    }
}
