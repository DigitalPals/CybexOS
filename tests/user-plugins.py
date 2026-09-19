#!/usr/bin/env python3
"""Exercise real external widgets through runtime replacement and rollback."""

from __future__ import annotations

import json
from contextlib import ExitStack
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time
import sys


ROOT = Path(__file__).resolve().parents[1]
SHELL = ROOT / "roles/desktop/files/quickshell"
HELPER = SHELL / "scripts/user-plugins.py"


def run(*args, env, check=True):
    return subprocess.run([str(arg) for arg in args], env=env, text=True,
                          capture_output=True, check=check)


def main():
    with tempfile.TemporaryDirectory(prefix="fedora-config-user-widgets.") as temporary, ExitStack() as stack:
        base = Path(temporary)
        env = dict(os.environ, HOME=str(base / "home"),
                   XDG_CONFIG_HOME=str(base / "config"),
                   XDG_DATA_HOME=str(base / "data"), XDG_STATE_HOME=str(base / "state"),
                   XDG_RUNTIME_DIR=str(base / "run"), QT_QPA_PLATFORM="offscreen",
                   QT_QUICK_BACKEND="software")
        for key in ("FEDORA_CONFIG_USER_CONFIG_ROOT", "FEDORA_CONFIG_PLUGIN_ROOT"):
            env.pop(key, None)
        (base / "run").mkdir(mode=0o700)
        packages = base / "data/fedora-config/plugins"
        config = base / "config/fedora-config/plugins.json"
        for plugin_id, api in (("example.good", 1), ("example.broken", 1), ("example.future", 2)):
            directory = packages / plugin_id
            directory.mkdir(parents=True)
            (directory / "manifest.json").write_text(json.dumps({
                "id": plugin_id, "apiVersion": api, "name": plugin_id,
                "version": "1.0.0", "entrypoint": "Widget.qml"}))
            (directory / "Widget.qml").write_text("import QtQuick\nItem {}\n")
        good = packages / "example.good"
        # An external relative import must work too, not just a self-contained root.
        (good / "Label.qml").write_text("import QtQuick\nText {}\n")
        (good / "Widget.qml").write_text('''import QtQuick
Label {
    required property var pluginApi
    text: pluginApi.settings.label + ":" + pluginApi.version + ":" + pluginApi.screenName
    color: pluginApi.theme.foreground
    readonly property bool apiContract: pluginApi.id === "example.good"
        && pluginApi.version === 1 && pluginApi.width === width && pluginApi.height === height
        && pluginApi.dataPath.endsWith("plugin-data/example.good")
        && pluginApi.packagePath.endsWith("plugins/example.good")
        && typeof pluginApi.setSetting === "function"
        && typeof pluginApi.theme.foreground === "string"
        && typeof pluginApi.theme.background === "string"
        && typeof pluginApi.theme.accent === "string"
        && typeof pluginApi.theme.fontFamily === "string"
        && typeof pluginApi.theme.fontSize === "number"
        && typeof pluginApi.theme.reducedMotion === "boolean"
}
''')
        (packages / "example.broken/Widget.qml").write_text("import QtQuick\nBroken {{{\n")

        def cli(*args, check=True):
            return run("python3", HELPER, *args, env=env, check=check)

        assert all(not item["enabled"] for item in json.loads(cli("list").stdout)["plugins"])
        cli("enable", "example.good", "--width", "140", "--order", "2")
        cli("set", "example.good", "label", '"preserved"')
        cli("enable", "example.broken")
        assert cli("enable", "example.future", check=False).returncode == 2
        assert cli("enable", "../escape", check=False).returncode == 2
        saved = json.loads(config.read_text())
        saved["futureField"] = {"keep": True}
        saved["plugins"]["example.good"]["futureField"] = [1, 2]
        saved["plugins"]["example.future"] = {"enabled": True, "settings": {"keep": True}}
        config.write_text(json.dumps(saved))
        cli("disable", "example.good")
        cli("enable", "example.good")
        saved = json.loads(config.read_text())
        assert saved["futureField"] == {"keep": True}
        assert saved["plugins"]["example.good"]["futureField"] == [1, 2]
        assert saved["plugins"]["example.good"]["width"] == 140

        # Simultaneous writers merge under the lock instead of losing preferences.
        writers = [subprocess.Popen(["python3", str(HELPER), "set", "example.good",
                                     f"concurrent{index}", str(index)], env=env)
                   for index in range(8)]
        assert all(writer.wait() == 0 for writer in writers)
        saved = json.loads(config.read_text())
        assert all(saved["plugins"]["example.good"]["settings"][f"concurrent{i}"] == i
                   for i in range(8))

        # Corrupt and newer schemas are neither reset nor downgraded by a write.
        original = config.read_bytes()
        for invalid in (b"{corrupt", b'{"v":2,"plugins":{}}',
                        b'{"v":1,"plugins":{},"extra":NaN}'):
            config.write_bytes(invalid)
            assert cli("disable", "example.good", check=False).returncode == 2
            assert json.loads(cli("list").stdout)["error"]
            assert config.read_bytes() == invalid
        config.write_bytes(original)

        # Reject entrypoint traversal and symlink escapes without changing preferences.
        manifest = good / "manifest.json"
        original_manifest = manifest.read_bytes()
        for entrypoint in ("../example.broken/Widget.qml", str(good / "Widget.qml"), "Escape.qml"):
            candidate = json.loads(original_manifest)
            candidate["entrypoint"] = entrypoint
            manifest.write_text(json.dumps(candidate))
            if entrypoint == "Escape.qml":
                (good / entrypoint).symlink_to(packages / "example.broken/Widget.qml")
            assert cli("enable", "example.good", check=False).returncode == 2
            assert config.read_bytes() == original
        (good / "Escape.qml").unlink()
        manifest.write_bytes(original_manifest)

        # Upstream packages are installed without rewriting QML or manifests.
        fixtures = ROOT / "tests/omarchy-plugins"
        pomodoro = packages / "markbusking.pomodoro"
        shutil.copytree(fixtures / "pomodoro", pomodoro)
        spacer = packages / "Example.Spacer_v1"
        spacer.mkdir()
        shutil.copy2(fixtures / "Spacer.qml", spacer / "Spacer.qml")
        spacer_manifest = {"schemaVersion": 1, "id": spacer.name, "name": "Spacer",
                           "version": "1", "kinds": ["bar-widget"],
                           "entryPoints": {"barWidget": "Spacer.qml"},
                           "barWidget": {"allowMultiple": True, "defaults": {"size": 37, "preserved": True}}}
        (spacer / "manifest.json").write_text(json.dumps(spacer_manifest))
        cli("enable", pomodoro.name, "--width", "90", "--order", "-2", "--section", "right")
        cli("set", pomodoro.name, "sound", "false")
        cli("set", pomodoro.name, "workMinutes", "2")
        cli("enable", spacer.name, "--width", "40", "--order", "-1", "--section", "right")
        descriptors = {item["id"]: item for item in json.loads(cli("list").stdout)["plugins"]}
        assert descriptors[spacer.name]["settings"] == {"size": 37, "preserved": True}
        assert descriptors[pomodoro.name]["format"] == "omarchy"
        original = config.read_bytes()
        for patch in ({"schemaVersion": True}, {"schemaVersion": 2},
                      {"apiVersion": 1}, {"kinds": ["service", "bar-widget"]},
                      {"entryPoints": {"barWidget": "../escape.qml"}},
                      {"entryPoints": {"barWidget": "Spacer.qml", "service": "Spacer.qml"}},
                      {"entryPoints": []}, {"barWidget": {"defaults": []}},
                      {"barWidget": {"allowMultiple": "true"}}):
            (spacer / "manifest.json").write_text(json.dumps({**spacer_manifest, **patch}))
            assert cli("enable", spacer.name, check=False).returncode == 2
            assert config.read_bytes() == original
        (spacer / "manifest.json").write_text(json.dumps(spacer_manifest))

        cli("merge", pomodoro.name, '{"workMinutes":2,"sound":false,"id":"ignored"}')
        assert "id" not in json.loads(config.read_text())["plugins"][pomodoro.name]["settings"]
        before_invalid = config.read_bytes()
        assert cli("bar", pomodoro.name, check=False).returncode == 2
        assert cli("bar-config", '{"position":"diagonal"}', check=False).returncode == 2
        assert cli("merge", pomodoro.name, '[]', check=False).returncode == 2
        assert config.read_bytes() == before_invalid

        # Named instances and replacement layout edits survive roundtrips.
        cli("instance", spacer.name, "one", "--section", "left")
        cli("instance", spacer.name, "two", "--section", "right")
        cli("set", spacer.name, "size", "31", "--instance", "one")
        cli("merge", spacer.name, '{"size":42}', "--instance", "two")
        info = json.loads(cli("list").stdout)
        copies = [w for w in info["widgets"] if w["id"] == spacer.name]
        assert [(w["instanceName"], w["settings"]["size"]) for w in copies] == [("one", 31), ("two", 42)]
        layout = {"left": [{"id": spacer.name, "__cybexInstance": "one", "size": 32}],
                  "center": [], "right": [{"id": spacer.name, "__cybexInstance": "two", "size": 43}]}
        cli("bar-config", json.dumps({"layout": layout, "transparent": True, "id": "ignored"}))
        info = json.loads(cli("list").stdout)
        assert "id" not in info["bar"]
        copies = [w for w in info["widgets"] if w["id"] == spacer.name]
        assert [(w["section"], w["settings"]["size"]) for w in copies] == [("left", 32), ("right", 43)]
        assert not next(w for w in info["widgets"] if w["id"] == pomodoro.name)["enabled"]
        assert next(p for p in info["plugins"] if p["id"] == pomodoro.name)["enabled"]
        before_invalid = config.read_bytes()
        for name in ("one", 42, ["invalid"]):
            layout["right"][0]["__cybexInstance"] = name
            assert cli("bar-config", json.dumps({"layout": layout}), check=False).returncode == 2
            assert config.read_bytes() == before_invalid
        assert cli("instance", pomodoro.name, "second", check=False).returncode == 2
        assert config.read_bytes() == before_invalid
        # Return to the single-instance fixture expected by replacement/rollback.
        cli("instance", spacer.name, "one", "--remove")
        cli("instance", spacer.name, "two", "--remove")
        cli("enable", pomodoro.name)

        if not shutil.which("qs"):
            raise RuntimeError("qs is required for user widget runtime tests")
        if any(path.read_text().strip() == "qs" for path in Path("/proc").glob("[0-9]*/comm")
               if path.exists()):
            print("User plugin storage tests passed; real-engine checks deferred to isolated CI (qs active)")
            return

        # PopupWindow/PanelWindow need a real backend. Never attach these tests
        # to the user's compositor: own a headless Wayland session and stop it
        # before TemporaryDirectory removes its socket and runtime files.
        if not shutil.which("sway"):
            raise RuntimeError("sway is required for isolated plugin popup tests")
        env.update(QT_QPA_PLATFORM="wayland", WLR_BACKENDS="headless",
                   WLR_RENDERER="pixman", WLR_LIBINPUT_NO_DEVICES="1", WLR_HEADLESS_OUTPUTS="2")
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("DISPLAY", None)
        sway_config = base / "sway.conf"
        sway_config.write_text("output HEADLESS-1 mode 1280x720\n")
        # Fedora's file capabilities can exceed a container's bounding set.
        # A private byte-copy runs unprivileged; headless needs no DRM access.
        sway_binary = base / "sway"
        shutil.copyfile(shutil.which("sway"), sway_binary)
        sway_binary.chmod(0o700)
        compositor_log = stack.enter_context((base / "sway.log").open("w+"))
        compositor = subprocess.Popen([str(sway_binary), "-c", str(sway_config)], env=env,
                                      stdout=compositor_log, stderr=subprocess.STDOUT)

        def stop_compositor():
            if compositor.poll() is None:
                compositor.terminate()
                try:
                    compositor.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    compositor.kill()
                    compositor.wait()

        stack.callback(stop_compositor)
        deadline = time.monotonic() + 10
        sockets = []
        while time.monotonic() < deadline and compositor.poll() is None:
            sockets = [path for path in (base / "run").glob("wayland-*") if path.is_socket()]
            if sockets:
                break
            time.sleep(0.05)
        if not sockets:
            compositor_log.seek(0)
            raise RuntimeError("Headless compositor did not become ready: " + compositor_log.read())
        env["WAYLAND_DISPLAY"] = sockets[0].name

        protected = {path: path.read_bytes() for path in packages.rglob("*") if path.is_file()}
        plugin_data = base / "data/fedora-config/plugin-data/example.good/history.json"
        plugin_data.write_text('{"userData":"preserved"}')
        protected[plugin_data] = plugin_data.read_bytes()
        protected[config] = config.read_bytes()
        runtime = base / "runtime"
        for release in ("N", "N+1", "rollback-N"):
            if runtime.exists():
                shutil.rmtree(runtime)
            shutil.copytree(SHELL, runtime)
            shutil.copy2(ROOT / "tests/user-widgets/shell.qml", runtime / "shell.qml")
            # A changed vendor file makes the replacement observable; packages
            # stay outside every runtime copy and expose only the frozen v1 API.
            (runtime / "release.txt").write_text(release)
            test_env = dict(env, WIDGET_TEST_WRITE="1" if release == "rollback-N" else "0",
                            OMARCHY_PATH=str(runtime / "compat/omarchy"))
            process = subprocess.Popen(["dbus-run-session", "--", "qs", "--no-color",
                                        "-p", str(runtime)], env=test_env,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       text=True, start_new_session=True)
            try:
                output, _ = process.communicate(timeout=14)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                output, _ = process.communicate(timeout=3)
                raise AssertionError(output) from None
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            assert "USER_WIDGET_RESULT pass" in output, output
            assert "USER_WIDGET_RESULT fail" not in output, output
            assert not re.search(r"(?:Type|Reference|Range)Error|Binding loop|Failed to load configuration", output), output
            for path, content in protected.items():
                if path != config or release != "rollback-N":
                    assert path.read_bytes() == content, f"{release} changed {path}"
            print(f"User widgets: {release} loaded external QML and preserved user packages")
        saved = json.loads(config.read_text())
        assert saved["plugins"]["example.good"]["settings"]["savedByWidget"] is True
        assert saved["plugins"][spacer.name]["settings"]["size"] == 51
        assert saved["futureField"] == {"keep": True}

        for plugin_id, folder in (("omarchy.media", "media"), ("omarchy.bar", "bar")):
            shutil.copytree(fixtures / folder, packages / plugin_id)
        for plugin_id, kinds, keep in (("example.bundle", ["service", "panel", "bar-widget"], True),
                                      ("example.overlay", ["overlay"], False),
                                      ("example.menu", ["menu"], False),
                                      ("example.badbar", ["bar"], False)):
            directory = packages / plugin_id
            shutil.copytree(fixtures / "contract", directory)
            entries = {kind: "Entry.qml" for kind in kinds}
            if "service" in kinds:
                entries["service"] = "Service.qml"
            if "bar-widget" in kinds:
                del entries["bar-widget"]
                entries["barWidget"] = "Widget.qml"
            (directory / "manifest.json").write_text(json.dumps({
                "schemaVersion": 1, "id": plugin_id, "name": plugin_id, "version": "1",
                "kinds": kinds, "entryPoints": entries, "keepLoaded": keep,
                "barWidget": {"allowMultiple": "bar-widget" in kinds},
                "__isFirstParty": True, "__hostCapabilities": ["authentication"]}))
            if plugin_id == "example.badbar":
                (directory / "Entry.qml").write_text("Broken {{{")
            cli("enable", plugin_id, "--section", "left")
        cli("enable", "omarchy.media", "--section", "left")
        cli("instance", "example.bundle", "one", "--section", "left", "--width", "60")
        cli("instance", "example.bundle", "two", "--section", "left", "--width", "60")
        cli("set", "example.bundle", "label", '"first"', "--instance", "one")
        cli("set", "example.bundle", "label", '"second"', "--instance", "two")
        info = json.loads(cli("list").stdout)
        bundle = next(item for item in info["plugins"] if item["id"] == "example.bundle")
        assert not bundle["manifest"]["__isFirstParty"]
        assert bundle["manifest"]["__hostCapabilities"] == []
        shutil.copy2(ROOT / "tests/omarchy-plugins/shell.qml", runtime / "shell.qml")
        process = subprocess.Popen(["dbus-run-session", "--", "qs", "--no-color", "-p", str(runtime)],
                                   env=dict(env, OMARCHY_PATH=str(runtime / "compat/omarchy")),
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
        try:
            output, _ = process.communicate(timeout=35)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            output, _ = process.communicate(timeout=3)
            raise AssertionError(output) from None
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        assert "OMARCHY_PARITY pass" in output, output
        assert "OMARCHY_PARITY fail" not in output, output
        assert not re.search(r"(?:Type|Reference|Range)Error|Binding loop|Failed to load configuration", output), output
        print("Omarchy services, panels, overlays, menus and upstream replacement bar passed")


if __name__ == "__main__":
    if os.geteuid() == 0:
        # wlroots refuses a privileged compositor. CI runs inside a root
        # container, so run this entire disposable fixture as nobody.
        raise SystemExit(subprocess.call(["runuser", "-u", "nobody", "--", sys.executable, __file__]))
    main()
