# Boots the Cybex OS desktop into a real Hyprland session with the Mac-like
# desktop style (Settings → Appearance → Desktop style) and checks every place
# the style reaches: the shell's tokens, the compositor's corners and shadows,
# the title bars, GTK's window buttons and font, the menubar menus, the dock,
# Spotlight, Mission Control and the minimize animation. It then switches
# back to the Cybex style and checks that each of those returns.
#
# Screenshots of each view are kept in the test's output directory for
# review. The pointer is QEMU's USB tablet through QMP, as in
# hyprland-pointer.nix, so hover states are Hyprland's own.
#
# Test-only settings: SDDM signs the user in directly, the display is fixed
# at 1280×800 and the style is seeded in shell.json before the first sign-in.
# This is VM qualification of the session, not of physical hardware.
{ pkgs, module }:
let
  hypr = expression: pkgs.writeShellScript "cybexos-mac-style-eval" ''
    exec hyprctl -i 0 eval ${pkgs.lib.escapeShellArg expression}
  '';
  floating = hypr ''require("workspaces").set_default_layout("floating")'';
  terminal = name: args: pkgs.writeShellScript "cybexos-mac-style-${name}" ''
    exec hyprctl -i 0 dispatch 'hl.dsp.exec_cmd("${pkgs.kitty}/bin/kitty ${args} ${pkgs.coreutils}/bin/sleep 1999")'
  '';
  # Kitty's own class, so the dock shows its real icon; and a second one of a
  # class of its own to minimize.
  terminalA = terminal "kitty" "--title \\\"john@cybex: ~\\\"";
  terminalB = terminal "cxo-b" "--class cxo-b --title notes";
  files = pkgs.writeShellScript "cybexos-mac-style-files" ''
    exec hyprctl -i 0 dispatch 'hl.dsp.exec_cmd("nautilus --new-window")'
  '';
  # Switches the stored style while the shell is stopped: it reads shell.json
  # as it starts. Every other preference is left alone.
  style = pkgs.writeText "cybexos-mac-style-set.py" ''
    import json, os, sys
    path = os.path.expanduser("~/.config/cybexos/shell.json")
    with open(path) as source:
        data = json.load(source)
    data["desktopStyle"] = sys.argv[1]
    with open(path + ".mac-test", "w") as target:
        json.dump(data, target, indent=2)
    os.replace(path + ".mac-test", path)
  '';
in pkgs.testers.runNixOSTest {
  name = "cybexos-mac-style";
  nodes.machine = { lib, ... }: {
    imports = [ module ];
    cybexos = { enable = true; primaryUser = "tester"; features = { proprietary = false; steam = false; docker = false; }; };
    networking.hostName = "machine";
    users.users.tester.initialPassword = "qualification-only";
    services.displayManager.autoLogin = { enable = true; user = "tester"; };
    systemd.tmpfiles.rules = [
      "d /home/tester/.config 0700 tester users -"
      "d /home/tester/.config/cybexos 0700 tester users -"
      ''f /home/tester/.config/cybexos/shell.json 0600 tester users - {"v":30,"desktopStyle":"mac","assistantShown":false}''
    ];
    virtualisation = {
      memorySize = 8192;
      cores = 8;
      graphics = true;
      diskSize = 4096;
      qemu.options = [ "-no-user-config" "-device virtio-vga,xres=1280,yres=800" ];
    };
    system.stateVersion = "26.05";
    boot.loader.systemd-boot.enable = lib.mkForce false;
  };
  testScript = ''
    import json
    import re
    import time
    from typing import Any

    QML_ERRORS = re.compile(r"TypeError|ReferenceError|Binding loop|is not a type|Type \w+ unavailable"
                            r"|Cannot assign|Unable to assign|Illegal method name|Failed to load configuration"
                            r"|is not defined|Cannot read property")
    MAC_FILES = re.compile(r"MacDesktop|MacMenuPopover|Minimizer|MinimizeOverlay|DockWindow|Bar\.qml"
                           r"|OverviewView|LauncherView|LauncherWindow|Theme\.qml|Settings\.qml|PopoutHost")
    out = machine.out_dir
    results: dict[str, Any] = {}

    machine.start()
    machine.wait_for_unit("display-manager.service")
    uid = machine.succeed("id -u tester").strip()
    session = f"XDG_RUNTIME_DIR=/run/user/{uid} HOME=/home/tester DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus"

    def user(command):
        return machine.succeed(f"runuser -u tester -- env {session} {command}")

    def hypr(*query):
        return json.loads(user("hyprctl -i 0 -j " + " ".join(query)))

    def option(name):
        return hypr("getoption", name)

    def gsetting(schema, key):
        # The user manager's environment carries the schemas, as the shell's
        # theme target sees them.
        return user(f"systemd-run --user --quiet --wait --pipe gsettings get {schema} {key}").strip()

    def layer_names():
        return {layer.get("namespace") for monitor in hypr("layers").values()
                for level in monitor.get("levels", {}).values() for layer in level}

    def wait(predicate, timeout=10):
        deadline = time.monotonic() + timeout
        while True:
            value = predicate()
            if value or time.monotonic() >= deadline:
                return value
            time.sleep(0.25)

    def client(cls):
        return next((c for c in hypr("clients") if c["class"] == cls), None)

    def send(*events):
        assert machine.qmp_client is not None
        arguments: Any = {"events": list(events)}
        machine.qmp_client.send("input-send-event", arguments)

    def axis(name, value, extent):
        return {"type": "abs", "data": {"axis": name, "value": max(0, min(32767, round(value * 32767 / (extent - 1))))}}

    def move(x, y, pause=0.3):
        send(axis("x", x, width), axis("y", y, height))
        time.sleep(pause)

    def tokens():
        # The shell writes the file a moment after it starts.
        status, text = machine.execute(f"runuser -u tester -- env {session} cat /home/tester/.local/state/cybexos/theme/tokens.json")
        try:
            return json.loads(text) if status == 0 else {}
        except ValueError:
            return {}

    def shell_ready():
        machine.wait_until_succeeds(f"runuser -u tester -- env {session} systemctl --user is-active quickshell.service", timeout=600)
        machine.wait_until_succeeds(f"runuser -u tester -- env {session} cybexos-runtime ipc settings status", timeout=300)

    def journal():
        return machine.succeed("journalctl _SYSTEMD_USER_UNIT=quickshell.service -b --no-pager -o short-monotonic")

    # ---- the session ------------------------------------------------------
    shell_ready()
    monitor = hypr("monitors")[0]
    width, height = round(monitor["width"] / monitor["scale"]), round(monitor["height"] / monitor["scale"])
    assert (width, height) == (1280, 800), monitor
    def welcome():
        return json.loads(user("cybexos-runtime ipc welcome status"))
    if wait(lambda: welcome()["open"], 60):
        user("cybexos-runtime ipc welcome close")
        assert wait(lambda: not layer_names() & {"qs-welcome", "qs-welcome-resume"}, 30), layer_names()

    # ---- what the style reaches -------------------------------------------
    assert wait(lambda: tokens().get("style") == "mac", 60), tokens()
    mac_tokens = tokens()
    results["tokens"] = {"style": mac_tokens["style"], "mode": mac_tokens["mode"], "font": mac_tokens["font"],
                         "accent": mac_tokens["colors"]["accent"], "glass": mac_tokens["glass"]}
    assert mac_tokens["font"]["ui"] == "Inter", mac_tokens["font"]
    assert mac_tokens["glass"] is True, mac_tokens
    results["interFamilies"] = user("fc-list : family").count("Inter")
    assert results["interFamilies"] > 0, "Inter is not installed"

    results["compositor"] = {name: option(name) for name in (
        "decoration:rounding_power", "decoration:shadow:range", "decoration:shadow:render_power",
        "decoration:shadow:offset", "decoration:shadow:color", "decoration:shadow:color_inactive")}
    results["themeError"] = machine.execute(f"runuser -u tester -- env {session} hyprctl -i 0 repl 'return __cybexos_system_theme.error'")[1].strip()
    gtk = {"buttonLayout": gsetting("org.gnome.desktop.wm.preferences", "button-layout"),
           "font": gsetting("org.gnome.desktop.interface", "font-name"),
           "accent": gsetting("org.gnome.desktop.interface", "accent-color"),
           "gtk4css": user("cat /home/tester/.local/state/cybexos/theme/gtk-4.0.css"),
           "gtk4import": user("cat /home/tester/.config/gtk-4.0/gtk.css")}
    results["gtk"] = gtk
    assert gtk["buttonLayout"] == "'close,minimize,maximize:'", gtk
    assert gtk["font"] == "'Inter 11'", gtk
    assert "windowcontrols" in gtk["gtk4css"] and "gtk-4.0.css" in gtk["gtk4import"], gtk

    # A floating workspace with two terminals and Files: title bars, the
    # Mac menubar and the dock.
    user(str("${floating}"))
    user(str("${terminalA}"))
    assert wait(lambda: client("kitty"), 60), hypr("clients")
    user(str("${terminalB}"))
    assert wait(lambda: client("cxo-b"), 60), hypr("clients")
    user(str("${files}"))
    files_open = wait(lambda: client("org.gnome.Nautilus"), 60)
    results["filesOpen"] = bool(files_open)
    time.sleep(3)
    results["titlebars"] = {name: option("plugin:hyprbars:" + name) for name in (
        "enabled", "bar_buttons_alignment", "bar_text_align", "icon_on_hover", "inactive_button_color",
        "col.text_inactive", "bar_height", "bar_text_font")}
    results["layers"] = sorted(n for n in layer_names() if n)
    assert "qs-dock" in layer_names(), layer_names()
    machine.screenshot("mac-desktop")

    # The traffic lights show their symbols under the pointer. The title bar
    # sits above the window's own area; minimize is the second button.
    a = client("kitty")
    results["clientA"] = {"at": a["at"], "size": a["size"]}
    move(a["at"][0] + 12 + 12 + 8 + 6, a["at"][1] - 14)
    machine.screenshot("mac-titlebar-hover")
    move(width - 40, 200)

    for name in ("macapp", "macsystem", "macwindow"):
        user(f"cybexos-runtime ipc popouts toggle {name}")
        time.sleep(1.2)
        machine.screenshot(f"mac-menu-{name}")
    user("cybexos-runtime ipc popouts close")
    time.sleep(0.5)

    user("cybexos-runtime ipc launcher toggle")
    assert wait(lambda: "qs-launcher" in layer_names(), 10), layer_names()
    time.sleep(1)
    machine.screenshot("mac-spotlight")
    user("cybexos-runtime ipc launcher toggle")
    time.sleep(0.8)

    user("cybexos-runtime ipc overview open")
    assert wait(lambda: "qs-overview" in layer_names(), 10), layer_names()
    time.sleep(2)
    machine.screenshot("mac-mission-control")
    user("cybexos-runtime ipc overview close")
    time.sleep(1)

    # The dock grows under the pointer and names what is under it.
    move(width / 2, height - 30, 1.0)
    machine.screenshot("mac-dock-magnified")
    move(width / 2 + 120, height - 30, 1.0)
    machine.screenshot("mac-dock-hover-right")
    move(width / 2 + 124, height - 34, 0.3)
    move(width / 2 + 122, height - 32, 1.0)
    machine.screenshot("mac-dock-hover-moved")
    move(width - 40, 200, 0.8)

    # Minimizing through the title bar's route animates into the dock.
    b = client("cxo-b")
    answer = user(f"cybexos-runtime ipc window minimize {b['address']}").strip()
    results["minimizeAnswer"] = answer
    time.sleep(0.35)
    machine.screenshot("mac-minimize-flight")
    minimized = wait(lambda: (client("cxo-b") or {}).get("workspace", {}).get("name", "").startswith("special:"), 10)
    results["minimized"] = bool(minimized)
    time.sleep(1.5)
    machine.screenshot("mac-minimized-in-dock")
    assert answer == "ok", answer
    assert minimized, client("cxo-b")

    # The light half of the style, through a light theme pack.
    results["lightTheme"] = user("cybex theme apply catppuccin-latte").strip()
    assert wait(lambda: tokens().get("mode") == "light", 60), tokens()
    time.sleep(2)
    results["lightCompositor"] = {name: option(name) for name in (
        "decoration:shadow:color", "decoration:shadow:color_inactive")}
    machine.screenshot("mac-desktop-light")

    mac_log = journal()
    (out / "quickshell-mac.log").write_text(mac_log)
    results["macErrors"] = [line for line in mac_log.splitlines()
                            if QML_ERRORS.search(line) and MAC_FILES.search(line)]

    # ---- back to the Cybex style ------------------------------------------
    user("systemctl --user stop quickshell.service")
    user(f"python3 {str('${style}')} cybex")
    user("systemctl --user start quickshell.service")
    shell_ready()
    assert wait(lambda: tokens().get("style") == "cybex", 60), tokens()
    time.sleep(3)
    results["cybex"] = {
        "compositor": {name: option(name) for name in (
            "decoration:rounding_power", "decoration:shadow:range", "decoration:shadow:offset")},
        "titlebars": {name: option("plugin:hyprbars:" + name) for name in (
            "bar_buttons_alignment", "bar_text_align", "icon_on_hover")},
        "buttonLayout": gsetting("org.gnome.desktop.wm.preferences", "button-layout"),
        "font": gsetting("org.gnome.desktop.interface", "font-name"),
        "gtk4css": user("cat /home/tester/.local/state/cybexos/theme/gtk-4.0.css"),
        "tokens": {key: tokens()[key] for key in ("style", "font")},
    }
    machine.screenshot("cybex-desktop")
    move(width / 2, height - 30, 1.0)
    machine.screenshot("cybex-dock-hover")
    move(width - 40, 200, 0.8)
    user("cybexos-runtime ipc overview open")
    assert wait(lambda: "qs-overview" in layer_names(), 10), layer_names()
    time.sleep(2)
    machine.screenshot("cybex-overview")
    user("cybexos-runtime ipc overview close")
    assert results["cybex"]["buttonLayout"] == "'appmenu:close'", results["cybex"]
    assert "windowcontrols" not in results["cybex"]["gtk4css"], results["cybex"]

    log = journal()
    (out / "quickshell.log").write_text(log)
    results["errors"] = [line for line in log.splitlines() if QML_ERRORS.search(line) and MAC_FILES.search(line)]
    (out / "mac-results.json").write_text(json.dumps(results, indent=2, default=str) + "\n")
    assert not results["errors"], "\n".join(results["errors"])
  '';
}
