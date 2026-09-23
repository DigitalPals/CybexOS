#!/usr/bin/env python3
"""Focused contracts for immutable dependencies and tracked large assets."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
SEMVER = re.compile(r"^[0-9]+[.][0-9]+[.][0-9]+(?:[.-][0-9A-Za-z.-]+)?$")


def executable(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/usr/bin/env bash\nset -eu\n" + body)
    path.chmod(0o755)


def render_user_updater(values: dict) -> str:
    updater = (ROOT / "roles/apps/templates/update-user-tools.j2").read_text()
    assert "{#" not in updater, "Bash syntax opened an unterminated Jinja comment"
    rendered = (
        updater.replace(
            "{{ claude_code_version | quote }}", repr(values["claude_code_version"])
        )
        .replace("{{ opencode_version | quote }}", repr(values["opencode_version"]))
        .replace("{{ codex_cli_version | quote }}", repr(values["codex_cli_version"]))
    )
    assert "{{" not in rendered and "{%" not in rendered
    subprocess.run(["bash", "-n"], input=rendered, text=True, check=True)
    return rendered


def inventory() -> dict:
    result = subprocess.run(
        ["ansible-inventory", "-i", "inventory/hosts.yml", "--host", "workstation"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def verify_dependency_policy(values: dict) -> None:
    for template in ROOT.rglob("*.j2"):
        assert "{#" not in template.read_text(), (
            f"{template.relative_to(ROOT)} contains a Jinja comment opener; "
            "use Bash syntax that cannot be parsed as an unterminated comment"
        )

    for group in ("github_release_apps", "nerd_font_apps"):
        for entry in values[group]:
            assert entry.get("version"), f"{entry['name']} has no release pin"
            assert SHA256.fullmatch(entry.get("checksum", "")), (
                f"{entry['name']} has no SHA-256 authorization"
            )

    assert re.fullmatch(r"[0-9a-f]{40}", values["lazyvim_starter_commit"])
    assert re.fullmatch(r"nightly-[0-9]{4}-[0-9]{2}-[0-9]{2}", values["rust_toolchain"])
    assert SEMVER.fullmatch(values["claude_code_version"])
    assert SEMVER.fullmatch(values["opencode_version"])
    assert values["codex_cli_version"] == "latest"
    assert not any(key.startswith("hermes_agent_") for key in values)
    assert "hermes_remote_url" not in values

    hermes_tasks = (ROOT / "roles/desktop/tasks/hermes-menubar.yml").read_text()
    assert "hermes-agent-removed-v1" in hermes_tasks
    assert '"{{ primary_home }}/.local/share/cybexos-user-tools/hermes"' in hermes_tasks
    assert '"{{ primary_home }}/.hermes"' in hermes_tasks
    assert '"{{ primary_home }}/.local/bin/hermes"' in hermes_tasks
    assert "raw.githubusercontent.com/NousResearch/hermes-agent" not in hermes_tasks
    assert not (ROOT / "roles/desktop/tasks/hermes-agent.yml").exists()
    assert not (
        ROOT / "roles/desktop/templates/hermes-backend.service.j2"
    ).exists()
    hermes_bridge_unit = (
        ROOT / "roles/desktop/templates/hermes-menubar-bridge.service.j2"
    ).read_text()
    assert "HERMES_REMOTE_URL" not in hermes_bridge_unit
    assert (
        "--remote-auth-state "
        "{{ primary_home }}/.local/state/hermes-menubar/remote-webui-auth.json"
        in hermes_bridge_unit
    )
    assert "--remote-only" in hermes_bridge_unit
    assert "--upstream" not in hermes_bridge_unit
    assert "hermes-backend.service" not in hermes_bridge_unit
    assert "EnvironmentFile=" not in hermes_bridge_unit
    assert "HERMES_REMOTE_PASSWORD" not in hermes_bridge_unit
    assert "HERMES_REMOTE_PASSWORD" not in (
        ROOT / "inventory/group_vars/all.yml"
    ).read_text()

    names = set()
    for entry in values["distrobox_images"]:
        assert entry["name"] not in names, f"duplicate Distrobox {entry['name']}"
        names.add(entry["name"])
        assert entry.get("source_tag"), f"{entry['name']} lacks review provenance"
        assert re.fullmatch(
            r"[^\s@]+@sha256:[0-9a-f]{64}", entry.get("image", "")
        ), f"{entry['name']} is not pinned to a manifest digest"

    dotfiles = (ROOT / "roles/dotfiles/tasks/main.yml").read_text()
    assert "version: main" not in dotfiles
    assert 'version: "{{ lazyvim_starter_commit }}"' in dotfiles
    assert 'loop: "{{ distrobox_images }}"' in dotfiles

    updater = (ROOT / "roles/apps/templates/update-user-tools.j2").read_text()
    assert "claude update" not in updater
    assert "opencode-ai@latest" not in updater
    assert "@openai/codex@latest version --json" in updater
    assert 'claude install "$claude_pin"' in updater
    assert '"opencode-ai@$opencode_pin"' in updater
    assert '"@openai/codex@$codex_pin"' in updater
    assert 'codex_version "$stage/node_modules/.bin/codex"' in updater
    assert 'mktemp -d "$root/.stage.' in updater
    render_user_updater(values)

    apps_main = (ROOT / "roles/apps/tasks/main.yml").read_text()
    upstream = (ROOT / "roles/apps/tasks/upstream.yml").read_text()
    dotfiles = (ROOT / "roles/dotfiles/tasks/main.yml").read_text()
    private_hooks = (ROOT / "roles/private-hooks/tasks/main.yml").read_text()
    finalize = (ROOT / "roles/finalize/tasks/main.yml").read_text()
    base = (ROOT / "roles/base/tasks/main.yml").read_text()
    uninstall = (ROOT / "roles/uninstall/tasks/main.yml").read_text()
    assert apps_main.count("    - source_builds") == 3
    source_cleanup = upstream.split(
        "- name: Inspect source-built command links before owned cleanup", 1
    )[1]
    assert "apps_feature_owned.source_builds | bool" in source_cleanup
    assert "item.stat.lnk_source" in source_cleanup
    distrobox_cleanup = dotfiles.split(
        "- name: Remove managed Distrobox launchers and hooks when Podman is disabled",
        1,
    )[1].split("\n- name:", 1)[0]
    assert "apps_feature_owned.podman | default(false) | bool" in distrobox_cleanup
    assert "private_hook_owned.private_hooks | bool" in private_hooks
    assert "private_hook_owned.apple_display | bool" in private_hooks
    assert finalize.count("cleanup_legacy_xps_artifacts | bool") >= 7
    assert "Preserve physical NetworkManager profile zones before first adoption" in base
    assert "Restore first-adoption NetworkManager profile zones" in uninstall
    assert uninstall.index("Restore first-adoption NetworkManager profile zones") < uninstall.index(
        "Remove the project firewalld zone after changing the default"
    )
    assert uninstall.index("Remove the project firewalld zone after changing the default") < uninstall.index(
        "Remove CybexOS system state when it is not retained"
    )

    command_wrapper = (ROOT / "roles/dotfiles/templates/cybex.j2").read_text()
    assert '$verify_scope || set -- --system "$@"' in command_wrapper
    assert 'exec "$agent_command" "$@"' in command_wrapper
    assert "    - cybexos-agent" in dotfiles
    assert uninstall.count(".local/bin/cybexos-agent") == 2
    assert ".config/cybexos/defaults/agent" not in uninstall

    agent_launcher = (ROOT / "assets/scripts/cybexos-agent").read_text()
    for dangerous_flag in (
        "--auto",
        "--approve-for-me",
        "--dangerously-bypass-approvals-and-sandbox",
        "--dangerously-skip-permissions",
    ):
        assert dangerous_flag not in agent_launcher
    assert 'command=(opencode)' in agent_launcher
    assert 'command=(claude)' in agent_launcher
    assert 'command=(codex)' in agent_launcher

    release_workflow = (ROOT / ".github/workflows/release.yml").read_text()
    assert 'scripts/semver validate "$version"' in release_workflow
    assert 'sha256sum "cybexos-$version.tar.zst" >SHA256SUMS' in release_workflow
    assert 'sha256sum "dist/cybexos-$version.tar.zst"' not in release_workflow

    workflow = (ROOT / ".github/workflows/tests.yml").read_text()
    for package, purpose in (
        ("jq", "durable updater fixture"),
        ("dbus-daemon", "isolated QML runtime fixture"),
        ("luajit", "Hyprland Lua policy fixtures"),
        ("python3-websockets", "Hermes bridge protocol fixtures"),
    ):
        assert re.search(rf"^\s+{re.escape(package)} \\$", workflow, re.MULTILINE), (
            f"the clean Fedora CI container must explicitly install {package} "
            f"for the {purpose}"
        )
    workflow_sources = [
        path.read_text() for path in sorted((ROOT / ".github/workflows").glob("*.yml"))
    ]
    action_refs = re.findall(
        r"^\s*- uses:\s*([^\s#]+)", "\n".join(workflow_sources), re.MULTILINE
    )
    assert action_refs, "CI workflow has no externally reviewed actions"
    for action_ref in action_refs:
        assert re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", action_ref), (
            f"CI action is not pinned to a full commit: {action_ref}"
        )

    vm_runner = (ROOT / "tests/fedora-vm-convergence").read_text()
    assert "Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2" in vm_runner
    assert "28680fe5b371a5a82ebf43a31926e086a168e59949d03969c5093e7071f90b7f" in vm_runner
    assert "sha256sum --check" in vm_runner
    assert "no configuration changes" in vm_runner
    assert "git ls-files -z --cached --others --exclude-standard" in vm_runner
    assert "--null --verbatim-files-from --files-from=-" in vm_runner
    assert "tar --exclude=.git" not in vm_runner
    required_commands = re.search(
        r"for command in ([^;]+); do", vm_runner
    )
    assert required_commands is not None
    assert "git" in required_commands.group(1).split()

    runner = (ROOT / "tests/run").read_text()
    assert "rg -l '^#!.*(bash|sh)' -g '!*.j2' ." in runner
    assert "rg --files . -g '*.py'" in runner
    assert "rg -l '^#!.*python' -g '!*.j2' ." in runner

    verifier = (ROOT / "tests/verify-system").read_text()
    assert not re.search(
        r"required_commands=\([^)]*\bhermes\b", verifier, re.DOTALL
    ), "the retired local Hermes runtime cannot also be a required command"
    assert "local connected-service runtimes are absent" in verifier

    fish = (ROOT / "roles/dotfiles/files/fish-config.fish").read_text()
    assert "alias codex='codex --dangerously-bypass-approvals-and-sandbox'" in fish
    assert "--dangerously-skip-permissions" not in fish
    assert "alias update='cybex update'" in fish
    assert "alias a='cybex agent'" in fish


def verify_user_updater_runtime(values: dict) -> None:
    # Keep the exact-version compatibility cases deterministic; latest-channel
    # resolution and failure cases are exercised separately below.
    values = dict(values, codex_cli_version="0.153.2")
    rendered = render_user_updater(values)
    claude_pin = values["claude_code_version"]
    opencode_pin = values["opencode_version"]
    codex_pin = values["codex_cli_version"]

    def run(home: Path) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update({"HOME": str(home), "PATH": "/usr/bin:/bin"})
        return subprocess.run(
            ["bash"], input=rendered, text=True, capture_output=True, env=environment
        )

    # Exact installed pins must be a true no-op and must not touch the network.
    with tempfile.TemporaryDirectory(prefix="cybexos-user-tools.") as temporary:
        home = Path(temporary)
        executable(home / ".local/bin/claude", f'echo "{claude_pin} (Claude Code)"\n')
        executable(home / ".local/bin/opencode", f'echo "{opencode_pin}"\n')
        executable(home / ".local/bin/codex", f'echo "codex-cli {codex_pin}"\n')
        executable(home / ".local/bin/npm", 'echo "unexpected npm call" >&2; exit 99\n')
        executable(home / ".local/bin/curl", 'echo "unexpected curl call" >&2; exit 99\n')
        result = run(home)
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "UNCHANGED: user-managed CLI versions"

    # The Claude pin is a floor. A newer self-updated version is left alone
    # instead of being downgraded to the pin on every converge.
    major, minor, patch = claude_pin.split("-")[0].split("+")[0].split(".")[:3]
    for newer in (f"{major}.{minor}.{int(patch) + 33}", f"{major}.{int(minor) + 1}.0"):
        with tempfile.TemporaryDirectory(prefix="cybexos-user-tools.") as temporary:
            home = Path(temporary)
            executable(
                home / ".local/bin/claude",
                f'if [[ ${{1:-}} == --version ]]; then echo "{newer} (Claude Code)"; '
                'else echo "unexpected claude $*" >&2; exit 99; fi\n',
            )
            executable(home / ".local/bin/opencode", f'echo "{opencode_pin}"\n')
            executable(home / ".local/bin/codex", f'echo "codex-cli {codex_pin}"\n')
            executable(home / ".local/bin/npm", 'echo "unexpected npm call" >&2; exit 99\n')
            executable(home / ".local/bin/curl", 'echo "unexpected curl call" >&2; exit 99\n')
            result = run(home)
            assert result.returncode == 0, (newer, result.stderr)
            assert result.stdout.strip() == "UNCHANGED: user-managed CLI versions"

    # A failed native Claude switch restores the exact prior version symlink.
    with tempfile.TemporaryDirectory(prefix="cybexos-user-tools.") as temporary:
        home = Path(temporary)
        old = home / ".local/share/claude/versions/2.1.246"
        executable(
            old,
            'if [[ ${1:-} == --version ]]; then echo "2.1.246 (Claude Code)"; '
            'else exit 1; fi\n',
        )
        (home / ".local/bin").mkdir(parents=True)
        (home / ".local/bin/claude").symlink_to(old)
        executable(home / ".local/bin/opencode", f'echo "{opencode_pin}"\n')
        executable(home / ".local/bin/codex", f'echo "codex-cli {codex_pin}"\n')
        result = run(home)
        assert result.returncode == 75, (result.stdout, result.stderr)
        assert (home / ".local/bin/claude").resolve() == old
        assert "existing 2.1.246 retained" in result.stderr

    # A missing required tool is not a recoverable update failure merely
    # because the other tool already exists.
    with tempfile.TemporaryDirectory(prefix="cybexos-user-tools.") as temporary:
        home = Path(temporary)
        executable(home / ".local/bin/opencode", f'echo "{opencode_pin}"\n')
        executable(home / ".local/bin/codex", f'echo "codex-cli {codex_pin}"\n')
        executable(home / ".local/bin/curl", 'exit 1\n')
        result = run(home)
        assert result.returncode == 1, (result.stdout, result.stderr)
        assert f"claude>={claude_pin}" in result.stderr

    # OpenCode is built off to the side. A failed npm operation leaves the
    # legacy global installation untouched and reports the recoverable status.
    with tempfile.TemporaryDirectory(prefix="cybexos-user-tools.") as temporary:
        home = Path(temporary)
        executable(home / ".local/bin/claude", f'echo "{claude_pin} (Claude Code)"\n')
        executable(home / ".local/bin/codex", f'echo "codex-cli {codex_pin}"\n')
        npm = home / ".local/bin/npm"
        executable(
            npm,
            'if [[ " $* " == *" list "* ]]; then '
            'echo \'{"dependencies":{"opencode-ai":{"version":"1.17.0"}}}\'; '
            'else exit 1; fi\n',
        )
        legacy = home / ".npm-global/retained-before-failure"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("keep\n")
        result = run(home)
        assert result.returncode == 75, (result.stdout, result.stderr)
        assert legacy.read_text() == "keep\n"
        assert not (home / ".local/bin/opencode").exists()
        assert "existing 1.17.0 retained" in result.stderr

    # A successful staged install becomes visible only after its reported
    # version matches the pin; the legacy prefix remains available for rollback.
    with tempfile.TemporaryDirectory(prefix="cybexos-user-tools.") as temporary:
        home = Path(temporary)
        executable(home / ".local/bin/claude", f'echo "{claude_pin} (Claude Code)"\n')
        executable(home / ".local/bin/codex", f'echo "codex-cli {codex_pin}"\n')
        executable(
            home / ".local/bin/npm",
            'if [[ " $* " == *" list "* ]]; then '
            'echo \'{"dependencies":{"opencode-ai":{"version":"1.17.0"}}}\'; exit 0; fi\n'
            'prefix=""; previous=""\n'
            'for argument in "$@"; do\n'
            '  if [[ $previous == --prefix ]]; then prefix=$argument; fi\n'
            '  previous=$argument\n'
            'done\n'
            'mkdir -p "$prefix/node_modules/.bin"\n'
            f'printf \'#!/usr/bin/env bash\\necho "{opencode_pin}"\\n\' '
            '> "$prefix/node_modules/.bin/opencode"\n'
            'chmod 0755 "$prefix/node_modules/.bin/opencode"\n',
        )
        legacy = home / ".npm-global/retained-before-success"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("keep\n")
        result = run(home)
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert result.stdout.strip() == "CHANGED: user-managed CLI update"
        assert legacy.read_text() == "keep\n"
        installed = subprocess.run(
            [str(home / ".local/bin/opencode")],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        assert installed == opencode_pin

    # Codex uses the same off-to-the-side activation boundary and validates
    # its distinct `codex-cli VERSION` output before replacing a working link.
    with tempfile.TemporaryDirectory(prefix="cybexos-user-tools.") as temporary:
        home = Path(temporary)
        executable(home / ".local/bin/claude", f'echo "{claude_pin} (Claude Code)"\n')
        executable(home / ".local/bin/opencode", f'echo "{opencode_pin}"\n')
        executable(
            home / ".local/bin/npm",
            'prefix=""; previous=""\n'
            'for argument in "$@"; do\n'
            '  if [[ $previous == --prefix ]]; then prefix=$argument; fi\n'
            '  previous=$argument\n'
            'done\n'
            'mkdir -p "$prefix/node_modules/.bin"\n'
            f'printf \'#!/usr/bin/env bash\\necho "codex-cli {codex_pin}"\\n\' '
            '> "$prefix/node_modules/.bin/codex"\n'
            'chmod 0755 "$prefix/node_modules/.bin/codex"\n',
        )
        result = run(home)
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert result.stdout.strip() == "CHANGED: user-managed CLI update"
        installed = subprocess.run(
            [str(home / ".local/bin/codex"), "--version"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        assert installed == f"codex-cli {codex_pin}"


def verify_codex_latest(values: dict) -> None:
    rendered = render_user_updater(dict(values, codex_cli_version="latest"))
    # Cover no-op, upgrade, offline, malformed metadata, missing first install,
    # failed download, and a staged binary that disagrees with the registry.
    for scenario in ("current", "upgrade", "offline", "invalid", "missing", "download", "mismatch"):
        with tempfile.TemporaryDirectory(prefix="cybexos-user-tools.") as temporary:
            home = Path(temporary)
            executable(home / ".local/bin/claude", f'echo "{values["claude_code_version"]}"\n')
            executable(home / ".local/bin/opencode", f'echo "{values["opencode_version"]}"\n')
            prior = "0.200.0" if scenario == "current" else "0.100.0"
            if scenario != "missing":
                executable(home / ".local/bin/codex", f'echo "codex-cli {prior}"\n')
            lookup = 'echo \'"0.200.0"\''
            if scenario in ("offline", "missing"):
                lookup = "exit 1"
            elif scenario == "invalid":
                lookup = 'echo \'"not-a-version"\''
            downloaded = "0.199.0" if scenario == "mismatch" else "0.200.0"
            executable(
                home / ".local/bin/npm",
                f'if [[ $1 == view ]]; then {lookup}; exit; fi\n'
                + ('exit 1\n' if scenario == "download" else '')
                + '[[ " $* " == *" @openai/codex@0.200.0 "* ]]\n'
                'printf "install\\n" >> "$HOME/npm-installs"\n'
                '[[ $1 == --prefix ]]\n'
                'mkdir -p "$2/node_modules/.bin"\n'
                f'printf \'#!/usr/bin/env bash\\necho "codex-cli {downloaded}"\\n\' '
                '> "$2/node_modules/.bin/codex"\n'
                'chmod 0755 "$2/node_modules/.bin/codex"\n',
            )
            environment = dict(os.environ, HOME=str(home), PATH="/usr/bin:/bin")
            result = subprocess.run(
                ["bash"], input=rendered, text=True, capture_output=True, env=environment
            )
            expected = 0 if scenario in ("current", "upgrade") else 1 if scenario == "missing" else 75
            assert result.returncode == expected, (scenario, result.stdout, result.stderr)
            if scenario == "missing":
                assert not (home / ".local/bin/codex").exists()
            else:
                actual = subprocess.check_output([str(home / ".local/bin/codex")], text=True).strip()
                assert actual == f"codex-cli {'0.200.0' if scenario == 'upgrade' else prior}"
            if scenario in ("current", "offline", "invalid", "missing"):
                assert not (home / "npm-installs").exists()
            assert not list(home.glob(".local/share/cybexos-user-tools/codex/.stage.*"))


def verify_asset_provenance() -> None:
    document = json.loads((ROOT / "assets/PROVENANCE.json").read_text())
    assert document["schemaVersion"] == 1
    assert document["rightsPolicy"]["status"] in {
        "unknown-owner-action-required",
        "resolved-no-undocumented-large-assets",
    }
    records = {entry["path"]: entry for entry in document["assets"]}
    assert len(records) == len(document["assets"]), "duplicate provenance path"

    large_assets = {
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / "assets").rglob("*")
        if path.is_file() and path.stat().st_size > 1024 * 1024
    }
    assert set(records) == large_assets, (
        f"provenance mismatch: missing={large_assets - set(records)}, "
        f"extra={set(records) - large_assets}"
    )
    for relative, record in records.items():
        path = ROOT / relative
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        assert record["sha256"] == digest, f"stale hash for {relative}"
        assert record["bytes"] == path.stat().st_size, f"stale size for {relative}"
        rights_status = record.get("rightsStatus", document["rightsPolicy"]["status"])
        if rights_status == "unknown-owner-action-required":
            assert record["creator"] is None
            assert record["sourceUrl"] is None
            assert record["license"] is None
        elif rights_status == "documented":
            assert all(
                isinstance(record[field], str) and record[field].strip()
                for field in ("creator", "sourceUrl", "license")
            ), f"incomplete documented rights for {relative}"
        else:
            raise AssertionError(f"unknown rights status for {relative}: {rights_status}")
        assert re.fullmatch(r"[0-9a-f]{40}", record["introducedByCommit"])


if __name__ == "__main__":
    values = inventory()
    verify_dependency_policy(values)
    verify_user_updater_runtime(values)
    verify_codex_latest(values)
    verify_asset_provenance()
    print("dependency pins and large-asset provenance are internally consistent")
