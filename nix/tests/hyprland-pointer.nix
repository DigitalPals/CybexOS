# Boots the Cybex OS desktop into a real Hyprland session and drives it with
# real pointer input: QEMU's USB tablet through QMP input-send-event, as the
# installation qualification does, so Hyprland's own pointer-focus rules
# decide where every event goes. Headless Sway with a virtual pointer cannot
# show those rules (tests/assistant-overlay.py).
#
# The Assistant character is dragged with and without the hover that opens
# its box, on an empty workspace and with a focused window, and in a few
# steps longer than its own radius; each drag must land where the pointer let
# go. A click on it must still open the box, and the desktop must still
# receive clicks once it is put away.
#
# Test-only settings: SDDM signs the user in directly (Cybex OS's own
# automatic login requires verified LUKS), the display is fixed at 1280×800
# and the character starts at a known place. This is VM qualification of the
# session's input handling, not of physical pointer hardware.
{ pkgs, module }:
let
  python = pkgs.python3.interpreter;
  # Moves the character while the shell is stopped: it reads shell.json as it
  # starts. Every other preference is left alone.
  place = pkgs.writeText "cybexos-assistant-place.py" ''
    import json, os, sys
    path = os.path.expanduser("~/.config/cybexos/shell.json")
    with open(path) as source:
        data = json.load(source)
    data.update(assistantShown=True, assistantX=int(sys.argv[1]), assistantY=int(sys.argv[2]))
    with open(path + ".pointer-test", "w") as target:
        json.dump(data, target, indent=2)
    os.replace(path + ".pointer-test", path)
  '';
  # A terminal program that reports every mouse button it receives, so a
  # click is known to have reached the window rather than a shell surface.
  probe = pkgs.writeText "cybexos-pointer-probe.py" ''
    import os, sys, tty
    log = open(sys.argv[1], "a", buffering=1)
    tty.setraw(0)
    # Button presses and releases, in SGR coordinates.
    sys.stdout.write("\x1b[?1000h\x1b[?1006h")
    sys.stdout.flush()
    log.write("ready\n")
    while True:
        data = os.read(0, 1024)
        if not data:
            break
        log.write(repr(data) + "\n")
  '';
  launchProbe = pkgs.writeShellScript "cybexos-pointer-probe-launch" ''
    exec hyprctl -i 0 dispatch 'hl.dsp.exec_cmd("${pkgs.kitty}/bin/kitty --class cxo-probe ${python} ${probe} /home/tester/probe.log", { float = true, size = { 420, 300 }, move = "40 120" })'
  '';
  # The probe's place, should the exec rule not apply.
  arrangeProbe = pkgs.writeShellScript "cybexos-pointer-probe-arrange" ''
    hyprctl -i 0 dispatch 'hl.dsp.window.float({ action = "set", window = "class:cxo-probe" })'
    hyprctl -i 0 dispatch 'hl.dsp.window.resize({ x = 420, y = 300, window = "class:cxo-probe" })'
    hyprctl -i 0 dispatch 'hl.dsp.window.move({ x = 40, y = 120, window = "class:cxo-probe" })'
  '';
  workspace = number: pkgs.writeShellScript "cybexos-pointer-workspace-${number}" ''
    exec hyprctl -i 0 dispatch 'hl.dsp.focus({ workspace = "${number}" })'
  '';
in pkgs.testers.runNixOSTest {
  name = "cybexos-hyprland-pointer";
  nodes.machine = { lib, ... }: {
    imports = [ module ];
    cybexos = { enable = true; primaryUser = "tester"; features = { proprietary = false; steam = false; docker = false; }; };
    networking.hostName = "machine";
    users.users.tester.initialPassword = "qualification-only";
    services.displayManager.autoLogin = { enable = true; user = "tester"; };
    # The character's place before the first sign-in, right of the probe
    # window and below the bar, as tests/assistant-overlay.py seeds it.
    systemd.tmpfiles.rules = [
      "d /home/tester/.config 0700 tester users -"
      "d /home/tester/.config/cybexos 0700 tester users -"
      ''f /home/tester/.config/cybexos/shell.json 0600 tester users - {"v":30,"assistantShown":true,"assistantX":880,"assistantY":240}''
    ];
    virtualisation = {
      memorySize = 8192;
      cores = 8;
      graphics = true;
      diskSize = 4096;
      # The installation harness's display; the default usb-tablet is the pointer.
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
                            r"|Cannot assign|Unable to assign|Illegal method name|Failed to load configuration")
    TOLERANCE = 3
    out = machine.out_dir

    machine.start()
    machine.wait_for_unit("display-manager.service")
    uid = machine.succeed("id -u tester").strip()
    session = f"XDG_RUNTIME_DIR=/run/user/{uid} HOME=/home/tester DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus"

    def user(command):
        return machine.succeed(f"runuser -u tester -- env {session} {command}")

    def hypr(*query):
        return json.loads(user("hyprctl -i 0 -j " + " ".join(query)))

    def assistant():
        return json.loads(user("cybexos-runtime ipc assistant status"))

    def journal_cursor():
        return machine.succeed("journalctl -n 0 --show-cursor -q").strip().split("cursor: ", 1)[-1]

    def shell_journal(cursor=None):
        after = f" --after-cursor='{cursor}'" if cursor else ""
        # Not --user-unit: for root that also matches _UID=0.
        return machine.succeed(f"journalctl _SYSTEMD_USER_UNIT=quickshell.service -b --no-pager -o short-monotonic{after}")

    def wait(predicate, timeout=10):
        deadline = time.monotonic() + timeout
        while True:
            value = predicate()
            if value or time.monotonic() >= deadline:
                return value
            time.sleep(0.25)

    # ---- real pointer input -------------------------------------------------
    # The USB tablet's absolute axes span the whole output, 0..32767. USB polls
    # its reports: events in one polling interval can merge, so every motion
    # and button change is given time to be read on its own.
    def send(*events):
        assert machine.qmp_client is not None
        arguments: Any = {"events": list(events)}
        machine.qmp_client.send("input-send-event", arguments)

    def axis(name, value, extent):
        return {"type": "abs", "data": {"axis": name, "value": max(0, min(32767, round(value * 32767 / (extent - 1))))}}

    def move(x, y, pause=0.05):
        send(axis("x", x, width), axis("y", y, height))
        time.sleep(pause)

    def button(down, pause=0.1):
        send({"type": "btn", "data": {"down": down, "button": "left"}})
        time.sleep(pause)

    def click(x, y):
        move(x, y, 0.2)
        button(True)
        button(False, 0.3)

    def cursor():
        return hypr("cursorpos")

    def layer_names():
        return {layer.get("namespace") for monitor in hypr("layers").values()
                for level in monitor.get("levels", {}).values() for layer in level}

    def assistant_layers():
        return [layer for monitor in hypr("layers").values() for level in monitor.get("levels", {}).values()
                for layer in level if layer.get("namespace") == "qs-assistant"]

    # ---- the session ------------------------------------------------------
    machine.wait_until_succeeds(f"runuser -u tester -- env {session} systemctl --user is-active quickshell.service", timeout=600)
    machine.wait_until_succeeds(f"runuser -u tester -- env {session} cybexos-runtime ipc assistant status | grep -q available", timeout=300)
    monitor = hypr("monitors")[0]
    width, height = round(monitor["width"] / monitor["scale"]), round(monitor["height"] / monitor["scale"])
    assert (width, height) == (1280, 800), monitor
    machine.screenshot("session")

    # The first sign-in shows the welcome guide over everything.
    assert wait(lambda: json.loads(user("cybexos-runtime ipc welcome status"))["open"], 60)
    user("cybexos-runtime ipc welcome close")
    assert wait(lambda: not layer_names() & {"qs-welcome", "qs-welcome-resume"}, 30), layer_names()
    user("cybexos-runtime ipc assistant show")
    assert wait(lambda: (lambda s: s["shown"] and (s["x"], s["y"]) == (880, 240))(assistant()), 15), assistant()
    # The guide's notification leaves first.
    time.sleep(8)
    park = (width - 40, round(height * 0.55))
    move(*park, 0.5)
    machine.screenshot("placed")

    def place(x, y):
        """Start the shell again with the character at (x, y)."""
        user("systemctl --user stop quickshell.service")
        user(f"${python} ${place} {x} {y}")
        user("systemctl --user start quickshell.service")
        def starting():
            status, output = machine.execute(f"runuser -u tester -- env {session} cybexos-runtime ipc assistant status")
            try:
                return json.loads(output) if status == 0 else {}
            except ValueError:
                return {}
        assert wait(lambda: (lambda s: (s.get("x"), s.get("y")) == (x, y))(starting()), 60), starting()
        assert wait(lambda: "qs-assistant" in layer_names() and not layer_names() & {"qs-welcome", "qs-welcome-resume"}, 30), layer_names()
        time.sleep(2)

    results = []

    def drag(name, start, end, dwell, window, steps=20):
        """Drag the character's centre from its place at `start` to `end` in `steps` pointer motions.

        A scenario starts where the previous one should have left the
        character; after a failed drag the shell is started again with it there.
        """
        journal_start = journal_cursor()
        before = assistant()
        replaced = (before["x"], before["y"]) != tuple(start)
        if replaced:
            place(*start)
            journal_start = journal_cursor()
            before = assistant()
        dx, dy = end[0] - start[0], end[1] - start[1]
        size = before["size"]
        x, y = before["x"] + size / 2, before["y"] + size / 2
        record = {"scenario": name, "window": window, "hoverDwell": dwell, "steps": steps, "offset": [dx, dy], "shellRestarted": replaced,
                  "before": before, "activeWindow": hypr("activewindow"), "layersBefore": assistant_layers()}
        # Come in from beside the character, so its surface sees the pointer arrive.
        move(x - size, y)
        move(x, y)
        # Without the dwell the button goes down well inside its 260 ms.
        if dwell:
            time.sleep(0.6)
            record["boxOpenAtPress"] = assistant()["composing"]
            record["cursorAtPress"] = cursor()
            machine.screenshot(f"{name}-hover")
        button(True)
        for step in range(1, steps + 1):
            move(x + dx * step / steps, y + dy * step / steps)
            if step == steps // 2:
                machine.screenshot(f"{name}-held")
        record["cursorAtRelease"] = cursor()
        button(False)
        target = (before["x"] + dx, before["y"] + dy)
        landed = lambda s: abs(s["x"] - target[0]) <= TOLERANCE and abs(s["y"] - target[1]) <= TOLERANCE
        after = wait(lambda: (lambda s: s if landed(s) else None)(assistant()), 3) or assistant()
        machine.screenshot(f"{name}-dropped")
        record.update(after=after, target=list(target), moved=[after["x"] - before["x"], after["y"] - before["y"]],
                      boxOpenAtDrop=after["composing"], passed=landed(after) and after["screen"] == before["screen"],
                      layersAfter=assistant_layers(), activeWindowAfter=hypr("activewindow"))
        # Put the pointer away; a box the hover opened closes after it leaves.
        move(*park, 0.2)
        record["boxClosedAfter"] = bool(wait(lambda: not assistant()["composing"]))
        record["journal"] = shell_journal(journal_start).splitlines()
        results.append(record)
        machine.log(f"{name}: {before['x']},{before['y']} -> {after['x']},{after['y']} (wanted {target[0]},{target[1]}): "
                    + ("passed" if record["passed"] else "FAILED"))

    # An empty workspace: no surface has the keyboard.
    drag("a-empty-hover", (880, 240), (580, 460), dwell=True, window=False)
    drag("c-empty-press", (580, 460), (840, 280), dwell=False, window=False)

    # A focused normal window, away from the character's path.
    user("${launchProbe}")
    machine.wait_until_succeeds(f"runuser -u tester -- env {session} hyprctl -i 0 -j clients | grep -q cxo-probe", timeout=60)
    machine.wait_until_succeeds("grep -q ready /home/tester/probe.log", timeout=60)
    probe = next(c for c in hypr("clients") if c["class"] == "cxo-probe")
    if not probe["floating"] or probe["at"][0] + probe["size"][0] > 560:
        user("${arrangeProbe}")
        time.sleep(1)
        probe = next(c for c in hypr("clients") if c["class"] == "cxo-probe")
    assert probe["floating"] and probe["at"][0] + probe["size"][0] <= 560, probe
    assert hypr("activewindow").get("class") == "cxo-probe", hypr("activewindow")
    drag("b-window-hover", (840, 280), (620, 480), dwell=True, window=True)
    drag("c-window-press", (620, 480), (900, 280), dwell=False, window=True)

    # A quick drag on an empty workspace: every step leaves the character's
    # disc before it can follow, and no surface has the keyboard.
    user("${workspace "2"}")
    assert wait(lambda: not hypr("activewindow").get("class")), hypr("activewindow")
    drag("e-empty-flick", (900, 280), (700, 480), dwell=False, window=False, steps=4)
    user("${workspace "1"}")
    assert wait(lambda: hypr("activewindow").get("class") == "cxo-probe"), hypr("activewindow")

    # ---- after the drags ------------------------------------------------------
    journal_start = journal_cursor()
    # A click on the empty desktop, left of the box's column, puts away a box
    # a failed drag may have left open.
    desktop = (round(width * 0.3), round(height * 0.85))
    clicks = {"boxOpenBefore": assistant()["composing"]}
    if clicks["boxOpenBefore"]:
        click(*desktop)
        assert wait(lambda: not assistant()["composing"]), assistant()
    clicks["before"] = assistant()
    size = clicks["before"]["size"]
    centre = (clicks["before"]["x"] + size / 2, clicks["before"]["y"] + size / 2)
    move(centre[0] - size, centre[1])
    # A click, quicker than the hover dwell. Only a click keeps the box open
    # once the pointer leaves it.
    move(*centre)
    button(True)
    button(False, 0.3)
    move(*park)
    time.sleep(1.5)
    clicks["afterClick"] = assistant()
    clicks["clickOpensBox"] = clicks["afterClick"]["composing"]
    machine.screenshot("d-clicked")
    click(*desktop)
    clicks["boxClosedByDesktopClick"] = bool(wait(lambda: not assistant()["composing"]))
    presses = lambda: machine.succeed("{ grep -o '<[0-9]*;[0-9]*;[0-9]*M' /home/tester/probe.log || true; } | wc -l").strip()
    clicks["probePressesBefore"] = presses()
    click(probe["at"][0] + probe["size"][0] // 2, probe["at"][1] + probe["size"][1] // 2)
    clicks["probePressesAfter"] = wait(lambda: (lambda n: n if n != clicks["probePressesBefore"] else None)(presses()), 5) or presses()
    clicks["windowReceivesClick"] = clicks["probePressesAfter"] != clicks["probePressesBefore"]
    clicks["activeWindow"] = hypr("activewindow")
    clicks["windowFocused"] = clicks["activeWindow"].get("class") == "cxo-probe"
    clicks["layers"] = assistant_layers()
    clicks["cursor"] = cursor()
    clicks["journal"] = shell_journal(journal_start).splitlines()
    clicks["passed"] = clicks["clickOpensBox"] and clicks["boxClosedByDesktopClick"] and clicks["windowReceivesClick"] and clicks["windowFocused"]
    machine.screenshot("d-window-clicked")
    machine.log("d-clicks: " + ("passed" if clicks["passed"] else "FAILED") + " " + json.dumps(
        {key: clicks[key] for key in ("clickOpensBox", "boxClosedByDesktopClick", "windowReceivesClick", "windowFocused")}))

    log = shell_journal()
    # The whole log is kept; the Assistant's own files must be clean.
    warnings = [line for line in log.splitlines() if QML_ERRORS.search(line) or "warn" in line.lower()]
    errors = [line for line in warnings if QML_ERRORS.search(line) and "Assistant" in line]
    (out / "quickshell.log").write_text(log)
    (out / "pointer-results.json").write_text(json.dumps({"output": monitor, "drags": results, "clicks": clicks,
                                                          "warnings": warnings, "assistantQmlErrors": errors}, indent=2) + "\n")
    failed = [r["scenario"] for r in results if not r["passed"]] + ([] if clicks["passed"] else ["d-clicks"])
    assert not failed, "Pointer scenarios failed: " + ", ".join(failed) + "\n" + json.dumps(
        [{key: r[key] for key in ("scenario", "target", "moved", "after")} for r in results], indent=1)
    assert not errors, "\n".join(errors)
  '';
}
