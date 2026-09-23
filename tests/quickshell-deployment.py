#!/usr/bin/env python3
"""Exercise Quickshell deployment path-type and symlink boundaries."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile


PLAY = r"""
- hosts: localhost
  connection: local
  become: false
  gather_facts: false
  vars:
    root: __ROOT__
    source_file: __SOURCE__
    managed_files: [Common/Theme.qml]
    managed_directories: [Common]
  tasks:
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
    - ansible.builtin.find:
        paths: "{{ root }}"
        recurse: true
        hidden: true
        file_type: any
        follow: false
      register: deployed_tree
    - ansible.builtin.file:
        path: "{{ item.path }}"
        state: absent
      loop: "{{ deployed_tree.files | rejectattr('isdir') | list }}"
      vars:
        relative_path: "{{ item.path | regex_replace('^' + (root + '/') | regex_escape, '') }}"
      when: relative_path not in managed_files or item.islnk | default(false)
      register: removed_files
    - ansible.builtin.file:
        path: "{{ item.path }}"
        state: absent
      loop: "{{ deployed_tree.files | selectattr('isdir') | list }}"
      vars:
        relative_directory: "{{ item.path | regex_replace('^' + (root + '/') | regex_escape, '') }}"
      when: relative_directory not in managed_directories
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
      loop: "{{ managed_directories }}"
      when: not normalization_pending | bool
    - ansible.builtin.copy:
        src: "{{ source_file }}"
        dest: "{{ root }}/Common/Theme.qml"
        mode: "0644"
        follow: false
        local_follow: false
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

    play = PLAY.replace("__ROOT__", str(root)).replace("__SOURCE__", str(source))
    return root, sentinels, play


def run_plays(plays: list[str], *, check_mode: bool = False) -> None:
    command = ["ansible-playbook", "-i", "localhost,"]
    if check_mode:
        command.append("--check")
    command.append("/dev/stdin")
    result = subprocess.run(
        command,
        input="\n".join(plays),
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, (result.stdout, result.stderr)


SCENARIOS = (
    "root-link",
    "directory-link",
    "file-is-directory",
    "directory-is-file",
    "file-link",
)


with tempfile.TemporaryDirectory(prefix="cybexos-quickshell-deploy.") as temporary:
    base = Path(temporary)
    source = base / "managed-Theme.qml"
    source.write_text("managed\n")

    actual_roots: list[tuple[Path, list[tuple[Path, str]]]] = []
    actual_plays: list[str] = []
    for name in SCENARIOS:
        root, sentinels, play = scenario(base / "actual", name, source)
        actual_roots.append((root, [(path, path.read_text()) for path in sentinels]))
        actual_plays.append(play)
    run_plays(actual_plays)

    for root, sentinels in actual_roots:
        deployed = root / "Common/Theme.qml"
        assert not root.is_symlink(), f"managed root remained linked: {root}"
        assert deployed.is_file() and not deployed.is_symlink(), deployed
        assert deployed.read_text() == "managed\n"
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

print("Quickshell deployment normalizes symlinks and path-type transitions before copy")
