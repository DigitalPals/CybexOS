#!/usr/bin/env python3
"""Release gate for strict vendor/user ownership and legacy preservation."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
MIGRATOR = ROOT / "assets/scripts/cybexos-migrate-layering"
RUNTIME = ROOT / "assets/scripts/cybexos-runtime"


def run(
    *command: str | Path,
    env: dict[str, str] | None = None,
    cwd: Path | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(item) for item in command],
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        check=check,
    )


def snapshot(paths: list[Path]) -> dict[str, bytes]:
    return {str(path): path.read_bytes() for path in paths}


def migration_contract() -> None:
    with tempfile.TemporaryDirectory(prefix="cybexos-layering.") as temporary:
        root = Path(temporary)
        home = root / "home"
        previous = root / "previous"
        runtime = home / ".local/share/cybexos/runtime"
        legacy_qs = home / ".config/quickshell"
        legacy_hypr = home / ".config/hypr"
        state = home / ".local/state/cybexos"
        user_config = home / ".config/cybexos"
        themes = home / ".local/share/cybexos/themes"
        plugins = home / ".local/share/cybexos/plugins"
        plugin_data = home / ".local/share/cybexos/plugin-data/personal"

        for directory in (
            previous / "roles/desktop/files/quickshell",
            previous / "roles/desktop/files",
            runtime / "hypr",
            legacy_qs,
            legacy_hypr,
            state,
            home / ".local/state/quickshell/reminders",
            user_config,
            themes,
            plugins,
            plugin_data,
        ):
            directory.mkdir(parents=True, exist_ok=True)

        (previous / "roles/desktop/files/quickshell/shell.qml").write_text(
            "vendor n\n", encoding="utf-8"
        )
        (previous / "roles/desktop/files/quickshell/Changed.qml").write_text(
            "vendor original\n", encoding="utf-8"
        )
        (previous / "roles/desktop/files/bindings.lua").write_text(
            "vendor bindings\n", encoding="utf-8"
        )
        (previous / "roles/desktop/files/hyprland.lua").write_text(
            "vendor hyprland\n", encoding="utf-8"
        )
        (runtime / "hypr/hyprland.lua").write_text("vendor n+1\n", encoding="utf-8")

        (legacy_qs / "shell.qml").write_text("vendor n\n", encoding="utf-8")
        (legacy_qs / "Changed.qml").write_text("user qml\n", encoding="utf-8")
        (legacy_qs / "User.qml").write_text("user addition\n", encoding="utf-8")
        (legacy_hypr / "bindings.lua").write_text(
            "vendor bindings\n", encoding="utf-8"
        )
        (legacy_hypr / "hyprland.lua").write_text("user lua\n", encoding="utf-8")
        (state / "quickshell-manifest.txt").write_text(
            "Changed.qml\nshell.qml\n", encoding="utf-8"
        )

        old_shell_state = home / ".local/state/quickshell/shell-settings.json"
        old_shell_state.write_text('{"themeMode":"light"}\n', encoding="utf-8")
        old_notes = home / ".local/state/quickshell/notes.json"
        old_notes.write_text('{"notes":[]}\n', encoding="utf-8")
        (home / ".local/state/quickshell/reminders/one.json").write_text(
            "{}\n", encoding="utf-8"
        )

        theme = themes / "personal.theme"
        plugin = plugins / "personal.qml"
        plugin_settings = user_config / "plugins.json"
        plugin_state = plugin_data / "data.json"
        shell = user_config / "shell.local.json"
        theme.write_text("theme bytes\n", encoding="utf-8")
        plugin.write_text("plugin bytes\n", encoding="utf-8")
        plugin_settings.write_text('{"v":1,"plugins":{}}\n', encoding="utf-8")
        plugin_state.write_text('{"count":42}\n', encoding="utf-8")
        shell.write_text("shell bytes\n", encoding="utf-8")
        user_paths = [legacy_qs / "Changed.qml", legacy_qs / "User.qml",
                      legacy_hypr / "hyprland.lua", theme, plugin, shell,
                      plugin_settings, plugin_state]
        before = snapshot(user_paths)

        result = run(
            MIGRATOR,
            "--home",
            home,
            "--previous-source",
            previous,
            "--runtime-root",
            runtime,
        )
        assert result.stdout.startswith("CHANGED:"), result.stdout
        assert snapshot(user_paths) == before
        assert (user_config / "shell.json").read_bytes() == old_shell_state.read_bytes()
        assert (state / "shell/notes.json").read_bytes() == old_notes.read_bytes()
        assert (state / "shell/reminders/one.json").read_text() == "{}\n"

        marker = state / "migrations/ownership-v1.complete"
        report_path = Path(marker.read_text(encoding="utf-8").strip())
        report = json.loads(report_path.read_text(encoding="utf-8"))
        classes = {entry["path"]: entry["classification"] for entry in report["entries"]}
        assert classes[".config/quickshell/shell.qml"] == "vendor-unchanged"
        assert classes[".config/quickshell/Changed.qml"] == "user-modified"
        assert classes[".config/quickshell/User.qml"] == "user-added"
        assert classes[".config/hypr/bindings.lua"] == "vendor-unchanged"
        assert classes[".config/hypr/hyprland.lua"] == "user-modified"
        preserved = Path(report["preservedRoot"])
        assert (preserved / ".config/quickshell/Changed.qml").read_text() == "user qml\n"
        assert (preserved / ".config/hypr/hyprland.lua").read_text() == "user lua\n"

        second = run(
            MIGRATOR,
            "--home",
            home,
            "--previous-source",
            previous,
            "--runtime-root",
            runtime,
        )
        assert second.stdout == "Layering migration already completed.\n"
        assert snapshot(user_paths) == before

        # Model release N+1 replacing only its owned runtime. User sentinels
        # must remain byte-identical while the vendor default advances.
        shutil.rmtree(runtime)
        (runtime / "quickshell").mkdir(parents=True)
        (runtime / "quickshell/shell.qml").write_text("vendor n+2\n", encoding="utf-8")
        assert snapshot(user_paths) == before
        assert (runtime / "quickshell/shell.qml").read_text() == "vendor n+2\n"


def dev_source_contract() -> None:
    with tempfile.TemporaryDirectory(prefix="cybexos-dev-source.") as temporary:
        root = Path(temporary)
        home = root / "home"
        checkout = root / "checkout"
        shell_dir = checkout / "roles/desktop/files/quickshell"
        files_dir = checkout / "roles/desktop/files"
        shell_dir.mkdir(parents=True)
        home.mkdir()
        for path, content in (
            (shell_dir / "shell.qml", "ShellRoot {}\n"),
            (files_dir / "hyprland.lua", "return true\n"),
            (files_dir / "bindings.lua", "return true\n"),
            (files_dir / "autostart.lua", "return true\n"),
        ):
            path.write_text(content, encoding="utf-8")
        run("git", "init", "--quiet", checkout)
        run("git", "config", "user.name", "Layer Test", cwd=checkout)
        run("git", "config", "user.email", "layer@example.invalid", cwd=checkout)
        run("git", "add", ".", cwd=checkout)
        run("git", "commit", "--quiet", "-m", "fixture", cwd=checkout)
        before = run("git", "status", "--porcelain=v1", cwd=checkout).stdout

        # A stand-in qs records the IPC client's argv, so no call can reach the
        # desktop running this suite.
        bin_dir = root / "bin"
        bin_dir.mkdir()
        qs = bin_dir / "qs"
        qs.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\"\n", encoding="utf-8")
        qs.chmod(0o755)

        env = os.environ.copy()
        env.update({
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_DATA_HOME": str(home / ".local/share"),
            "CYBEXOS_RUNTIME_TESTING": "1",
            "PATH": f"{bin_dir}:{env['PATH']}",
        })

        def ipc_argv(*call: str) -> list[str]:
            return run(RUNTIME, "ipc", *call, env=env).stdout.splitlines()

        # The shell runs by path, so IPC must name the same path the service
        # was started with; a bare `qs ipc call` finds no configuration.
        vendor_shell = home / ".local/share/cybexos/runtime/quickshell"
        assert ipc_argv("settings", "toggle") == [
            "ipc", "--any-display", "-p", str(vendor_shell),
            "call", "--", "settings", "toggle",
        ]
        assert run(RUNTIME, "ipc", "settings", env=env, check=False).returncode == 2

        enabled = run(RUNTIME, "dev", "enable", checkout, env=env)
        assert str(checkout.resolve()) in enabled.stdout
        status = run(RUNTIME, "dev", "status", env=env).stdout
        assert status == f"enabled\t{checkout.resolve()}\n"
        selected = run(RUNTIME, "path", "quickshell", env=env).stdout.strip()
        assert Path(selected) == shell_dir.resolve()
        assert ipc_argv("popouts", "toggle", "control")[3] == selected
        assert run("git", "status", "--porcelain=v1", cwd=checkout).stdout == before
        disabled = run(RUNTIME, "dev", "disable", env=env)
        assert "disabled" in disabled.stdout.lower()
        assert run(RUNTIME, "dev", "status", env=env).stdout.startswith("disabled\t")
        assert ipc_argv("session", "keys")[3] == str(vendor_shell)
        assert run("git", "status", "--porcelain=v1", cwd=checkout).stdout == before

        # A user-created object cannot turn the atomic switch write into a
        # move through a directory or symlink.
        switch = home / ".config/cybexos/dev-source"
        switch.mkdir()
        refused = run(RUNTIME, "dev", "enable", checkout, env=env, check=False)
        assert refused.returncode == 2
        assert switch.is_dir() and not any(switch.iterdir())
        assert run("git", "status", "--porcelain=v1", cwd=checkout).stdout == before


def repository_contract() -> None:
    tasks = (ROOT / "roles/desktop/tasks/main.yml").read_text(encoding="utf-8")
    uninstall = (ROOT / "roles/uninstall/tasks/main.yml").read_text(encoding="utf-8")
    quickshell_unit = (
        ROOT / "roles/desktop/templates/quickshell.service.j2"
    ).read_text(encoding="utf-8")
    launcher = (
        ROOT / "roles/desktop/templates/hyprland-quickshell.j2"
    ).read_text(encoding="utf-8")
    hypr = (ROOT / "roles/desktop/files/hyprland.lua").read_text(encoding="utf-8")

    assert 'dest: "{{ cybexos_runtime_root }}/quickshell/{{ item }}"' in tasks
    assert 'dest: "{{ cybexos_runtime_root }}/hypr/{{ item }}"' in tasks
    assert 'path: "{{ primary_home }}/.config/quickshell"' not in tasks
    assert 'dest: "{{ primary_home }}/.config/hypr/' not in tasks
    directory_creation = tasks[
        tasks.index("Create desktop configuration directories"):
        tasks.index("Create private CybexOS shell state directories")
    ]
    assert "mode:" not in directory_creation
    assert ".config/quickshell" not in uninstall
    assert ".config/hypr" not in uninstall
    assert "cybexos-runtime exec quickshell" in quickshell_unit
    assert 'start-hyprland -- --config "$hypr_config"' in launcher
    assert 'dofile(user_dir .. "/user.lua")' in hypr
    assert (ROOT / "docs/architecture/ownership.md").is_file()


if __name__ == "__main__":
    migration_contract()
    dev_source_contract()
    repository_contract()
    print("Vendor runtime updates preserve every user-owned layer byte-for-byte")
