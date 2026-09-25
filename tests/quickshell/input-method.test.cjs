const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repo = path.resolve(__dirname, "../..");
const read = relative => fs.readFileSync(path.join(repo, relative), "utf8");

test("IBus runs as a session unit on Hyprland's input-method v2 protocol", () => {
    const unit = read("roles/desktop/files/cybexos-input-method.service");
    // What `ibus start --type wayland` spawns in IBus 1.5.34, in the foreground.
    assert.match(unit, /^ExecStart=\/usr\/libexec\/ibus-ui-gtk3 --enable-wayland-im --exec-daemon --daemon-args "--xim --panel disable"$/m);
    assert.match(unit, /^PartOf=hyprland-session\.target$/m);
    assert.match(unit, /^WantedBy=hyprland-session\.target$/m);
    assert.match(unit, /^Restart=on-failure$/m);
});

test("the workstation and the image start the same IBus unit", () => {
    const desktop = read("roles/desktop/tasks/main.yml");
    assert.match(desktop, /src: cybexos-input-method\.service\s+dest: "\{\{ primary_home \}\}\/\.config\/systemd\/user\/cybexos-input-method\.service"/);
    assert.match(desktop, /\['quickshell', 'hypridle', 'hyprpolkitagent', 'cybexos-input-method'\]/);
    const target = read("image/rootfs/usr/lib/systemd/user/hyprland-session.target");
    assert.match(target, /^Wants=.*\bcybexos-input-method\.service\b/m);
    assert.match(read("image/package"),
        /copy\("roles\/desktop\/files\/cybexos-input-method\.service", "usr\/lib\/systemd\/user\/cybexos-input-method\.service"\)/);
    for (const relative of ["roles/base/tasks/main.yml", "roles/uninstall/tasks/main.yml"])
        assert.match(read(relative), /\.config\/systemd\/user\/cybexos-input-method\.service/, relative);
});

test("IBus switches with Super+Shift+Space because Super+Space opens the launcher", () => {
    assert.match(read("roles/desktop/files/bindings.lua"), /mainMod \.\. " \+ SPACE", hl\.dsp\.global\("quickshell:launcherToggle"\)/);
    const override = read("roles/desktop/files/90-cybexos-ibus.gschema.override");
    assert.match(override, /^\[org\.freedesktop\.ibus\.general\.hotkey\]\ntriggers=\['<Super><Shift>space'\]$/m);
    const desktop = read("roles/desktop/tasks/main.yml");
    assert.match(desktop, /dest: \/usr\/share\/glib-2\.0\/schemas\/90-cybexos-ibus\.gschema\.override/);
    assert.match(desktop, /glib-compile-schemas \/usr\/share\/glib-2\.0\/schemas\s+changed_when: true\s+when: desktop_ibus_schema_override is changed/);
    // The image relies on glib2's file trigger to compile the installed override.
    assert.match(read("image/cybexos-desktop.spec"), /^\/usr\/share\/glib-2\.0\/schemas\/90-cybexos-ibus\.gschema\.override$/m);
    const uninstall = read("roles/uninstall/tasks/main.yml");
    assert.match(uninstall, /- \/usr\/share\/glib-2\.0\/schemas\/90-cybexos-ibus\.gschema\.override/);
    assert.match(uninstall, /register: uninstall_system_files\s+- name: Recompile GSettings schemas without the IBus shortcut override/);
});

test("XWayland and Chromium applications can reach IBus", () => {
    for (const relative of ["roles/desktop/templates/hyprland-quickshell.j2", "image/rootfs/usr/bin/hyprland-quickshell"]) {
        const launcher = read(relative);
        assert.match(launcher, /^export XMODIFIERS=@im=ibus$/m, relative);
        const imports = launcher.replace(/\\\n/g, " ").match(/(import-environment|dbus-update-activation-environment)[^\n]*/g);
        assert.equal(imports.length, 2, relative);
        for (const command of imports)
            assert.match(command, /\bXMODIFIERS\b/, `${relative}: ${command.split(" ")[0]}`);
    }
    assert.match(read("roles/desktop/files/bindings.lua"), /browser = "brave-origin-stable [^"]*--enable-wayland-ime/);
    for (const file of ["brave-origin.desktop", "com.onepassword.OnePassword.desktop"])
        assert.match(read(`roles/dotfiles/files/${file}`), /^Exec=[^\n]*--enable-wayland-ime/m, file);
});

test("the image installs IBus with its Wayland panel and the language engines", () => {
    const packages = read("roles/base/defaults/main.yml");
    for (const name of ["ibus", "ibus-gtk3", "ibus-gtk4", "ibus-anthy", "ibus-libpinyin", "ibus-hangul"])
        assert.match(packages, new RegExp(`^- ${name}$`, "m"), name);
});
