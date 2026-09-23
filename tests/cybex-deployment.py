#!/usr/bin/env python3
"""Exercise Cybex's disjoint upstream-plus-override deployment contract."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

import yaml


REPO = Path(__file__).resolve().parents[1]
TASKS = REPO / "roles/boot/tasks/main.yml"
DEFAULTS = REPO / "roles/boot/defaults/main.yml"

PLAY = r"""
---
- name: Reconcile a fixture Cybex deployment
  hosts: localhost
  connection: local
  gather_facts: false
  become: false
  tasks:
    - name: Create the fixture theme directory
      ansible.builtin.file:
        path: "{{ destination }}"
        state: directory
        mode: "0755"

    - name: Install fixture upstream files that have no local override
      ansible.builtin.copy:
        remote_src: true
        src: "{{ source }}/{{ item }}"
        dest: "{{ destination }}/{{ item }}"
        mode: preserve
        force: true
      loop: "{{ source_files | difference(override_files) | sort }}"
      notify: Count fixture initramfs rebuild

    - name: Install fixture local overrides
      ansible.builtin.copy:
        src: "{{ overrides }}/{{ item }}"
        dest: "{{ destination }}/{{ item }}"
        mode: "0644"
      loop: "{{ override_files }}"
      notify: Count fixture initramfs rebuild

  handlers:
    - name: Count fixture initramfs rebuild
      ansible.builtin.copy:
        dest: "{{ markers }}/{{ run_id }}"
        content: "rebuild requested\n"
        mode: "0644"
"""

RECAP = re.compile(r"localhost\s*:\s*ok=\d+\s+changed=(\d+)")
HANDLER_HEADING = "RUNNING HANDLER [Count fixture initramfs rebuild]"


def role_contract() -> list[str]:
    """Bind the behavioral fixture to the production task's file sets."""
    tasks = yaml.safe_load(TASKS.read_text())
    defaults = yaml.safe_load(DEFAULTS.read_text())
    overrides = defaults["boot_cybex_override_files"]

    assert overrides and len(overrides) == len(set(overrides)), overrides
    upstream = next(
        task for task in tasks
        if task.get("name") == "Install non-overridden Cybex Plymouth theme files"
    )
    custom = next(
        task for task in tasks
        if task.get("name") == "Install custom Cybex theme files"
    )

    upstream_copy = upstream["ansible.builtin.copy"]
    assert "{{ item }}" in upstream_copy["src"], upstream_copy
    assert "difference(boot_cybex_override_files)" in upstream["loop"], upstream
    assert custom["loop"] == "{{ boot_cybex_override_files }}", custom
    return overrides


def run_play(
    playbook: Path,
    config: Path,
    variables: dict[str, object],
    *,
    check: bool = False,
) -> tuple[int, str]:
    command = [
        "ansible-playbook",
        "-i",
        "localhost,",
        "-c",
        "local",
    ]
    if check:
        command.append("--check")
    command.extend((str(playbook), "-e", json.dumps(variables)))

    environment = os.environ.copy()
    environment.update(
        {
            "ANSIBLE_CONFIG": str(config),
            "ANSIBLE_FORCE_COLOR": "0",
            "NO_COLOR": "1",
        }
    )
    result = subprocess.run(
        command,
        cwd=REPO,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    recap = RECAP.search(output)
    assert recap is not None, output
    return int(recap.group(1)), output


assert shutil.which("ansible-playbook"), "ansible-playbook is required"
override_files = role_contract()

with tempfile.TemporaryDirectory(prefix="cybexos-cybex-deploy.") as temporary:
    root = Path(temporary)
    source = root / "source"
    overrides = root / "overrides"
    destination = root / "installed"
    markers = root / "rebuilds"
    for directory in (source, overrides, markers):
        directory.mkdir()

    exclusive = "upstream-only.txt"
    source_files = [exclusive, *override_files]
    for name in source_files:
        path = source / name
        path.write_text(f"upstream {name}\n")
        path.chmod(0o644)
    for name in override_files:
        path = overrides / name
        path.write_text(f"custom {name}\n")
        path.chmod(0o644)

    playbook = root / "playbook.yml"
    playbook.write_text(PLAY)
    config = root / "ansible.cfg"
    config.write_text(
        "[defaults]\n"
        "stdout_callback = default\n"
        "retry_files_enabled = False\n"
        "interpreter_python = auto_silent\n"
    )
    variables: dict[str, object] = {
        "source": str(source),
        "overrides": str(overrides),
        "destination": str(destination),
        "markers": str(markers),
        "source_files": source_files,
        "override_files": override_files,
        "ansible_python_interpreter": sys.executable,
    }

    first_changed, first_output = run_play(
        playbook, config, {**variables, "run_id": "first"}
    )
    assert first_changed > 0, first_output
    assert HANDLER_HEADING in first_output, first_output
    assert {path.name for path in markers.iterdir()} == {"first"}
    assert (destination / exclusive).read_text() == f"upstream {exclusive}\n"
    for name in override_files:
        assert (destination / name).read_text() == f"custom {name}\n"

    check_changed, check_output = run_play(
        playbook, config, {**variables, "run_id": "steady-check"}, check=True
    )
    assert check_changed == 0, check_output
    assert HANDLER_HEADING not in check_output, check_output
    assert {path.name for path in markers.iterdir()} == {"first"}

    steady_changed, steady_output = run_play(
        playbook, config, {**variables, "run_id": "steady-actual"}
    )
    assert steady_changed == 0, steady_output
    assert HANDLER_HEADING not in steady_output, steady_output
    assert {path.name for path in markers.iterdir()} == {"first"}

    drifted = destination / exclusive
    drifted.write_text("drifted downstream bytes\n")
    drift_check_changed, drift_check_output = run_play(
        playbook, config, {**variables, "run_id": "drift-check"}, check=True
    )
    assert drift_check_changed > 0, drift_check_output
    assert drifted.read_text() == "drifted downstream bytes\n"
    assert not (markers / "drift-check").exists()

    repair_changed, repair_output = run_play(
        playbook, config, {**variables, "run_id": "repair"}
    )
    assert repair_changed > 0, repair_output
    assert HANDLER_HEADING in repair_output, repair_output
    assert drifted.read_text() == f"upstream {exclusive}\n"
    assert {path.name for path in markers.iterdir()} == {"first", "repair"}

print("Cybex overlay converges without repeated copies or rebuild notifications")
