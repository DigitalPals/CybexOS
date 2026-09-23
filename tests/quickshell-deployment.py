#!/usr/bin/env python3
"""Exercise Quickshell deployment path-type, symlink, and no-change boundaries.

The two inline scripts are read from the role itself, so these fixtures test
exactly what a converge runs: the source description on the controller and
the read-only classification of the deployed tree that every later write,
lint, snapshot, and verification is derived from.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile

import yaml


ROOT = Path(__file__).resolve().parents[1]
TASKS = yaml.safe_load((ROOT / "roles/desktop/tasks/main.yml").read_text())


def inline_script(task_name: str) -> str:
    task = next(task for task in TASKS if task.get("name") == task_name)
    argv = task["ansible.builtin.command"]["argv"]
    assert argv[:2] == ["python3", "-c"], argv
    return argv[2]


SOURCE_SCRIPT = inline_script("Calculate the content identity of the managed Quickshell tree")
DELTA_SCRIPT = inline_script(
    "Inspect the deployed Quickshell tree before writing through any child path"
)
EXECUTABLE_PREFIX = "compat/omarchy/bin/"
MANIFEST = ["Common/Theme.qml", "compat/omarchy/bin/tool", "shell.qml"]
DIRECTORIES = ["Common", "compat", "compat/omarchy", "compat/omarchy/bin"]
EMPTY_DELTA = {
    "root": "directory",
    "install": [],
    "directories": [],
    "stale_files": [],
    "stale_directories": [],
    "bytecode_caches": [],
}


def make_source(base: Path) -> Path:
    source = base / "source"
    (source / "Common").mkdir(parents=True)
    (source / "compat/omarchy/bin").mkdir(parents=True)
    (source / "Common/Theme.qml").write_text("managed theme\n")
    (source / "shell.qml").write_text("managed shell\n")
    (source / "compat/omarchy/bin/tool").write_text("#!/bin/sh\n")
    return source


def describe_source(source: Path) -> str:
    result = subprocess.run(
        ["python3", "-c", SOURCE_SCRIPT, str(source), EXECUTABLE_PREFIX],
        input=json.dumps(sorted(MANIFEST)),
        text=True,
        capture_output=True,
        check=True,
    )
    description = json.loads(result.stdout)
    assert description["directories"] == DIRECTORIES, description
    assert description["files"]["compat/omarchy/bin/tool"]["mode"] == 0o755
    assert description["files"]["shell.qml"]["mode"] == 0o644
    return result.stdout


def delta(root: Path, description: str) -> dict:
    result = subprocess.run(
        ["python3", "-c", DELTA_SCRIPT, str(root)],
        input=description,
        text=True,
        capture_output=True,
        check=True,
    )
    return json.loads(result.stdout)


def deploy_exactly(source: Path, root: Path) -> None:
    root.mkdir(parents=True)
    root.chmod(0o755)
    for directory in DIRECTORIES:
        (root / directory).mkdir(parents=True, exist_ok=True)
        (root / directory).chmod(0o755)
    for relative in MANIFEST:
        target = root / relative
        target.write_bytes((source / relative).read_bytes())
        target.chmod(0o755 if relative.startswith(EXECUTABLE_PREFIX) else 0o644)


def check_classification(base: Path, source: Path, description: str) -> None:
    root = base / "classify/quickshell"
    external = base / "classify-external"
    external.mkdir(parents=True)
    external.joinpath("Theme.qml").write_text("managed theme\n")

    assert delta(root, description) == dict(
        EMPTY_DELTA, root="missing", install=MANIFEST, directories=DIRECTORIES
    )

    # The no-change fast path: nothing to copy, create, or remove.
    deploy_exactly(source, root)
    assert delta(root, description) == EMPTY_DELTA

    # Content, mode, and type drift each recopy exactly one managed file.
    (root / "shell.qml").write_text("drifted shell\n")
    (root / "compat/omarchy/bin/tool").chmod(0o644)
    (root / "Common/Theme.qml").unlink()
    (root / "Common/Theme.qml").symlink_to(external / "Theme.qml")
    (root / "Common").chmod(0o700)
    found = delta(root, description)
    assert found["install"] == MANIFEST, found
    assert found["directories"] == ["Common"], found
    # A link at a managed path is removed even though its target matches.
    assert found["stale_files"] == ["Common/Theme.qml"], found
    assert found["stale_directories"] == [], found

    # Stale entries are reported once, at their highest stale path.
    deploy_root = base / "stale/quickshell"
    deploy_exactly(source, deploy_root)
    (deploy_root / "Old").mkdir()
    (deploy_root / "Old/Nested.qml").write_text("old\n")
    (deploy_root / "Common/Old.qml").write_text("old\n")
    (deploy_root / ".hidden").write_text("old\n")
    (deploy_root / "compat/omarchy/bin/link").symlink_to(external, target_is_directory=True)
    # A runtime bytecode cache is inert; a link or file by that name is not.
    (deploy_root / "Common/__pycache__").mkdir()
    (deploy_root / "Common/__pycache__/Theme.cpython-314.pyc").write_bytes(b"cache")
    (deploy_root / "compat/__pycache__").symlink_to(external, target_is_directory=True)
    (deploy_root / "compat/omarchy/tool.pyc").write_bytes(b"sourceless")
    found = delta(deploy_root, description)
    assert found == dict(
        EMPTY_DELTA,
        stale_files=[
            ".hidden",
            "Common/Old.qml",
            "compat/__pycache__",
            "compat/omarchy/bin/link",
            "compat/omarchy/tool.pyc",
        ],
        stale_directories=["Old"],
        bytecode_caches=["Common/__pycache__"],
    ), found

    # Neither a linked nor a non-directory root is ever looked through.
    for name, make_root in (
        ("linked-root", lambda path: path.symlink_to(root, target_is_directory=True)),
        ("file-root", lambda path: path.write_text("not a directory\n")),
    ):
        unsafe = base / name / "quickshell"
        unsafe.parent.mkdir(parents=True)
        make_root(unsafe)
        assert delta(unsafe, description) == dict(
            EMPTY_DELTA, root="unsafe", install=MANIFEST, directories=DIRECTORIES
        )

    root.chmod(0o700)
    found = delta(root, description)
    assert found["root"] == "mode", found


PLAY = r"""
- hosts: localhost
  connection: local
  become: false
  gather_facts: false
  vars:
    root: __ROOT__
    source_root: __SOURCE__
    managed_files: __MANIFEST__
  tasks:
    - ansible.builtin.command:
        argv: [python3, -c, "{{ source_script }}", "{{ source_root }}", "{{ executable_prefix }}"]
        stdin: "{{ managed_files | sort | to_json }}"
      register: source_digest
      changed_when: false
      check_mode: false
    - ansible.builtin.command:
        argv: [python3, -c, "{{ delta_script }}", "{{ root }}"]
        stdin: "{{ source_digest.stdout }}"
      register: deployed_tree
      changed_when: false
      check_mode: false
    - ansible.builtin.set_fact:
        deploy: "{{ deployed_tree.stdout | from_json }}"
        deploy_required: >-
          {{ (deployed_tree.stdout | from_json).root != 'directory'
             or ((deployed_tree.stdout | from_json).install
                 + (deployed_tree.stdout | from_json).directories
                 + (deployed_tree.stdout | from_json).stale_files
                 + (deployed_tree.stdout | from_json).stale_directories) | length > 0 }}
    - ansible.builtin.stat:
        path: "{{ root }}"
        follow: false
      register: root_stat
    - ansible.builtin.set_fact:
        root_unsafe: >-
          {{ root_stat.stat.exists
             and (root_stat.stat.islnk | default(false)
                  or not (root_stat.stat.isdir | default(false))) }}
    - ansible.builtin.file:
        path: "{{ root }}"
        state: absent
      when: root_unsafe | bool
    - ansible.builtin.file:
        path: "{{ root }}"
        state: directory
        mode: "0755"
        follow: false
      when: not (ansible_check_mode and root_unsafe | bool)
    - ansible.builtin.file:
        path: "{{ root }}/{{ item }}"
        state: absent
      loop: "{{ deploy.stale_files }}"
      register: removed_files
    - ansible.builtin.file:
        path: "{{ root }}/{{ item }}"
        state: absent
      loop: >-
        {{ deploy.stale_directories
           + (deploy_required | bool | ternary(deploy.bytecode_caches, [])) }}
      register: removed_directories
    - ansible.builtin.set_fact:
        normalization_pending: >-
          {{ ansible_check_mode
             and (root_unsafe | bool
                  or removed_files.changed | default(false)
                  or removed_directories.changed | default(false)) }}
    - ansible.builtin.file:
        path: "{{ root }}/{{ item }}"
        state: directory
        mode: "0755"
        follow: false
      loop: "{{ deploy.directories }}"
      when: not normalization_pending | bool
    - ansible.builtin.copy:
        src: "{{ source_root }}/{{ item }}"
        dest: "{{ root }}/{{ item }}"
        mode: "{{ '0755' if item.startswith(executable_prefix) else '0644' }}"
        follow: false
        local_follow: false
      loop: "{{ deploy.install }}"
      when: not normalization_pending | bool
"""


def scenario(base: Path, name: str, source: Path) -> tuple[Path, list[Path], str]:
    home = base / name / "home"
    root = home / ".local/share/cybexos/runtime/quickshell"
    external = base / name / "external"
    external.mkdir(parents=True)
    sentinels: list[Path] = []

    if name == "root-link":
        external.joinpath("sentinel").write_text("external-root\n")
        sentinels.append(external / "sentinel")
        root.parent.mkdir(parents=True)
        root.symlink_to(external, target_is_directory=True)
    elif name == "unchanged":
        deploy_exactly(source, root)
    else:
        root.mkdir(parents=True)

    if name == "directory-link":
        external.joinpath("sentinel").write_text("external-directory\n")
        sentinels.append(external / "sentinel")
        (root / "Common").symlink_to(external, target_is_directory=True)
    elif name == "file-is-directory":
        stale = root / "Common/Theme.qml"
        stale.mkdir(parents=True)
        stale.joinpath("old").write_text("stale\n")
    elif name == "directory-is-file":
        root.joinpath("Common").write_text("stale\n")
    elif name == "file-link":
        (root / "Common").mkdir()
        target = external / "Theme.qml"
        target.write_text("external-file\n")
        sentinels.append(target)
        (root / "Common/Theme.qml").symlink_to(target)

    play = (
        PLAY.replace("__ROOT__", str(root))
        .replace("__SOURCE__", str(source))
        .replace("__MANIFEST__", json.dumps(MANIFEST))
    )
    return root, sentinels, play


def run_plays(plays: list[str], *, check_mode: bool = False) -> str:
    command = ["ansible-playbook", "-i", "localhost,"]
    if check_mode:
        command.append("--check")
    command += [
        "-e",
        json.dumps(
            {
                "source_script": SOURCE_SCRIPT,
                "delta_script": DELTA_SCRIPT,
                "executable_prefix": EXECUTABLE_PREFIX,
            }
        ),
        "/dev/stdin",
    ]
    environment = dict(os.environ, ANSIBLE_STDOUT_CALLBACK="default", ANSIBLE_NOCOLOR="1")
    result = subprocess.run(
        command,
        input="\n".join(plays),
        text=True,
        capture_output=True,
        check=False,
        env=environment,
    )
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


def tree_identity(root: Path) -> dict[str, tuple[int, int]]:
    return {
        str(path.relative_to(root)): (path.lstat().st_ino, path.lstat().st_mode)
        for path in sorted(root.rglob("*"))
    }


SCENARIOS = (
    "root-link",
    "directory-link",
    "file-is-directory",
    "directory-is-file",
    "file-link",
)


with tempfile.TemporaryDirectory(prefix="cybexos-quickshell-deploy.") as temporary:
    base = Path(temporary)
    source = make_source(base)
    description = describe_source(source)
    check_classification(base, source, description)

    actual_roots: list[tuple[Path, list[tuple[Path, str]]]] = []
    actual_plays: list[str] = []
    for name in SCENARIOS:
        root, sentinels, play = scenario(base / "actual", name, source)
        actual_roots.append((root, [(path, path.read_text()) for path in sentinels]))
        actual_plays.append(play)
    run_plays(actual_plays)

    for root, sentinels in actual_roots:
        assert not root.is_symlink(), f"managed root remained linked: {root}"
        for relative in MANIFEST:
            deployed = root / relative
            assert deployed.is_file() and not deployed.is_symlink(), deployed
            assert deployed.read_bytes() == (source / relative).read_bytes()
        assert (root / "compat/omarchy/bin/tool").stat().st_mode & 0o777 == 0o755
        assert (root / "Common/Theme.qml").stat().st_mode & 0o777 == 0o644
        assert delta(root, description) == EMPTY_DELTA, f"{root} did not converge"
        for path, expected in sentinels:
            assert path.read_text() == expected, f"deployment escaped through {path}"

    check_sentinels: list[tuple[Path, str]] = []
    check_plays: list[str] = []
    for name in SCENARIOS:
        _, sentinels, play = scenario(base / "check", name, source)
        check_sentinels.extend((path, path.read_text()) for path in sentinels)
        check_plays.append(play)
    run_plays(check_plays, check_mode=True)
    for path, expected in check_sentinels:
        assert path.read_text() == expected, f"check mode wrote through {path}"

    # An unchanged tree runs no write module at all, and a one-file change
    # rewrites only that file.
    root, _, play = scenario(base / "fast-path", "unchanged", source)
    cache = root / "Common/__pycache__"
    cache.mkdir()
    before = tree_identity(root)
    output = run_plays([play])
    assert "changed=0" in output, output
    assert tree_identity(root) == before, "an unchanged deployment rewrote files"
    (root / "shell.qml").write_text("drifted shell\n")
    before = tree_identity(root)
    output = run_plays([play])
    assert "changed=2" in output, output
    after = tree_identity(root)
    assert (root / "shell.qml").read_text() == "managed shell\n"
    assert not cache.exists(), "a deployment must also clear runtime bytecode caches"
    changed = {path for path in before if before[path] != after.get(path)}
    assert changed == {"shell.qml", "Common/__pycache__"}, changed

print("Quickshell deployment normalizes path types, skips unchanged trees, and copies only drift")
