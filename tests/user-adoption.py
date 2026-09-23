#!/usr/bin/env python3
"""Exercise first-adoption backup and uninstall restoration in isolation."""

from __future__ import annotations

from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

import yaml


ROOT = Path(__file__).resolve().parents[1]


def task_script(path: Path, name: str) -> str:
    tasks = yaml.safe_load(path.read_text())
    task = next(item for item in tasks if item.get("name") == name)
    return task["ansible.builtin.shell"]


def render_core_backup(script: str, home: Path) -> str:
    return (
        script.replace(
            "{{ (primary_home + '/.local/state/cybexos/backups/initial') | quote }}",
            shlex.quote(str(home / ".local/state/cybexos/backups/initial")),
        )
        .replace(
            "{{ (primary_home + '/.local/state/cybexos/backups/initial-core.complete') | quote }}",
            shlex.quote(
                str(home / ".local/state/cybexos/backups/initial-core.complete")
            ),
        )
        .replace("{{ primary_home | quote }}", shlex.quote(str(home)))
    )


def render_personal_backup(script: str, home: Path) -> str:
    return (
        script.replace(
            "{{ (primary_home + '/.local/state/cybexos/backups/initial') | quote }}",
            shlex.quote(str(home / ".local/state/cybexos/backups/initial")),
        )
        .replace(
            "{{ (primary_home + '/.local/state/cybexos/backups/initial-personal.complete') | quote }}",
            shlex.quote(
                str(home / ".local/state/cybexos/backups/initial-personal.complete")
            ),
        )
        .replace("{{ primary_home | quote }}", shlex.quote(str(home)))
    )


def render_restore(script: str, home: Path) -> str:
    return script.replace(
        "{{ (primary_home + '/.local/state/cybexos/backups/initial') | quote }}",
        shlex.quote(str(home / ".local/state/cybexos/backups/initial")),
    ).replace("{{ primary_home | quote }}", shlex.quote(str(home)))


def render_bootstrap_snapshot(script: str, source: Path, home: Path) -> str:
    return script.replace(
        "{{ config_repo | quote }}", shlex.quote(str(source))
    ).replace(
        "{{ (primary_home + '/.local/share/cybexos/releases') | quote }}",
        shlex.quote(str(home / ".local/share/cybexos/releases")),
    )


def run_bash(script: str) -> str:
    result = subprocess.run(
        ["bash", "-c", script], text=True, capture_output=True, check=False
    )
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


def run(*command: str, cwd: Path) -> None:
    subprocess.run(command, cwd=cwd, check=True, capture_output=True, text=True)


def main() -> None:
    core_backup = task_script(
        ROOT / "roles/base/tasks/main.yml",
        "Preserve core user paths before any role can adopt them",
    )
    personal_backup = task_script(
        ROOT / "roles/dotfiles/tasks/main.yml",
        "Preserve pre-existing personal configuration before adoption",
    )
    restore = task_script(
        ROOT / "roles/uninstall/tasks/main.yml",
        "Restore user configuration preserved before first adoption",
    )
    snapshot = task_script(
        ROOT / "roles/dotfiles/tasks/main.yml",
        "Snapshot the initial checkout into the managed release store",
    )

    with tempfile.TemporaryDirectory(prefix="cybexos-adoption.") as temporary:
        home = Path(temporary)
        quickshell = home / ".config/quickshell"
        hyprland = home / ".config/hypr"
        wants = home / ".config/systemd/user/hyprland-session.target.wants"
        local_bin = home / ".local/bin"
        quickshell.mkdir(parents=True)
        hyprland.mkdir(parents=True)
        wants.mkdir(parents=True)
        local_bin.mkdir(parents=True)
        (quickshell / "shell.qml").write_text("original shell\n")
        (hyprland / "hyprland.conf").write_text("original compositor\n")
        (local_bin / "spotify").write_text("original command\n")
        (wants / "existing.service").symlink_to("../existing.service")
        (home / ".gitconfig").write_text("[user]\n\tname = Existing User\n")

        run_bash(render_core_backup(core_backup, home))
        saved = home / ".local/state/cybexos/backups/initial"
        assert not (saved / ".config/quickshell").exists()
        assert not (saved / ".config/hypr").exists()
        assert (saved / ".local/bin/spotify").read_text() == "original command\n"
        saved_link = (
            saved
            / ".config/systemd/user/hyprland-session.target.wants/existing.service"
        )
        assert saved_link.is_symlink()
        assert not (saved / ".gitconfig").exists()

        shutil.rmtree(wants)
        (local_bin / "spotify").unlink()
        (quickshell / "shell.qml").write_text("user changed shell\n")
        (hyprland / "hyprland.conf").write_text("user changed compositor\n")
        (hyprland / "user-added.conf").write_text("keep me\n")
        run_bash(render_restore(restore, home))

        assert (quickshell / "shell.qml").read_text() == "user changed shell\n"
        assert (hyprland / "hyprland.conf").read_text() == "user changed compositor\n"
        assert (hyprland / "user-added.conf").read_text() == "keep me\n"
        assert (local_bin / "spotify").read_text() == "original command\n"
        assert (wants / "existing.service").readlink() == Path("../existing.service")

    with tempfile.TemporaryDirectory(prefix="cybexos-personal.") as temporary:
        home = Path(temporary)
        # Core adoption happens with personal dotfiles disabled. Enabling that
        # option later must still preserve the then-current personal files.
        run_bash(render_core_backup(core_backup, home))
        (home / ".config/kitty").mkdir(parents=True)
        (home / ".config/kitty/kitty.conf").write_text("font_size 13\n")
        (home / ".config/mimeapps.list").write_text("[Default Applications]\n")
        (home / ".gitconfig").write_text("[user]\n\tname = Existing User\n")
        run_bash(render_personal_backup(personal_backup, home))
        saved = home / ".local/state/cybexos/backups/initial"
        assert (saved / ".config/kitty/kitty.conf").read_text() == "font_size 13\n"
        assert (saved / ".config/mimeapps.list").read_text().startswith("[Default")
        assert (saved / ".gitconfig").read_text().startswith("[user]")
        assert (home / ".local/state/cybexos/backups/initial-core.complete").exists()
        assert (home / ".local/state/cybexos/backups/initial-personal.complete").exists()

    with tempfile.TemporaryDirectory(prefix="cybexos-bootstrap.") as temporary:
        root = Path(temporary)
        home = root / "home"
        source = root / "checkout"
        (home / ".local/share/cybexos/releases").mkdir(parents=True)
        (source / "scripts").mkdir(parents=True)
        (source / "scripts/update").write_text("version one\n")
        (source / "local-secret").write_text("do not install\n")
        run("git", "init", "--quiet", cwd=source)
        run("git", "config", "user.name", "Test User", cwd=source)
        run("git", "config", "user.email", "test@example.invalid", cwd=source)
        run("git", "add", "scripts/update", cwd=source)
        run("git", "commit", "--quiet", "-m", "version one", cwd=source)
        first_snapshot = run_bash(render_bootstrap_snapshot(snapshot, source, home))
        assert first_snapshot.startswith("CHANGED:")
        installed = home / ".local/share/cybexos/releases/bootstrap"
        assert (installed / "scripts/update").read_text() == "version one\n"
        assert not (installed / ".git").exists()
        assert not (installed / "local-secret").exists()

        identical_snapshot = run_bash(
            render_bootstrap_snapshot(snapshot, source, home)
        )
        assert identical_snapshot == ""

        (source / "scripts/update").write_text("version two\n")
        run("git", "add", "scripts/update", cwd=source)
        run("git", "commit", "--quiet", "-m", "version two", cwd=source)
        changed_snapshot = run_bash(render_bootstrap_snapshot(snapshot, source, home))
        assert changed_snapshot.startswith("CHANGED:")
        shutil.rmtree(source)
        assert (installed / "scripts/update").read_text() == "version two\n"

    print("First-adoption backup and uninstall restoration preserve user configuration")


if __name__ == "__main__":
    main()
