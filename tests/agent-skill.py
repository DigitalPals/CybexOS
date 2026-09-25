#!/usr/bin/env python3
"""Validate the CybexOS skill package and its local references."""

from __future__ import annotations

from pathlib import Path
import re

import yaml


ROOT = Path(__file__).resolve().parents[1]
SKILL_ROOT = ROOT / "agent-skills/cybexos"
ENTRYPOINT = SKILL_ROOT / "SKILL.md"


def frontmatter(text: str) -> tuple[dict[str, object], str]:
    match = re.fullmatch(r"---\n(.*?)\n---\n(.*)", text, re.DOTALL)
    assert match is not None, "SKILL.md needs one YAML frontmatter block"
    metadata = yaml.safe_load(match.group(1))
    assert isinstance(metadata, dict), "skill frontmatter must be a mapping"
    return metadata, match.group(2)


def local_links(path: Path, text: str) -> list[Path]:
    links = []
    for target in re.findall(r"(?<!!)\[[^]]+\]\(([^)]+)\)", text):
        if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
            continue
        target = target.split("#", 1)[0]
        links.append((path.parent / target).resolve())
    return links


def main() -> None:
    text = ENTRYPOINT.read_text(encoding="utf-8")
    metadata, body = frontmatter(text)
    assert set(metadata) == {"name", "description"}
    assert metadata["name"] == ENTRYPOINT.parent.name == "cybexos"
    description = metadata["description"]
    assert isinstance(description, str) and 80 <= len(description) <= 400
    for trigger in (
        "installed CybexOS",
        "Hyprland/Quickshell",
        "diagnostics",
        "screenshots",
        "LocalSend",
        "unrelated Fedora systems",
    ):
        assert trigger in description, f"description lacks trigger boundary: {trigger}"
    assert "$cybexos" in body and "/cybexos" in body

    expected_references = {
        (SKILL_ROOT / "references/quickshell-settings.md").resolve(),
        (SKILL_ROOT / "references/managed-configuration.md").resolve(),
        (SKILL_ROOT / "references/commands.md").resolve(),
        (SKILL_ROOT / "references/user-widgets.md").resolve(),
    }
    assert set(local_links(ENTRYPOINT, body)) == expected_references

    markdown_files = [ENTRYPOINT, *sorted((SKILL_ROOT / "references").glob("*.md"))]
    assert len(markdown_files) == 5
    for path in markdown_files:
        source = path.read_text(encoding="utf-8")
        assert len(source.splitlines()) < 140, f"{path.name} is not concise"
        for link in local_links(path, source):
            assert link.is_file(), f"broken local link in {path.name}: {link}"

    settings = (SKILL_ROOT / "references/quickshell-settings.md").read_text()
    for contract in (
        "SettingsHelpers.js",
        "preserves every existing key",
        "cp -a",
        "jq -e",
        "mv -T",
        "qs_live_begin",
        "qs_live_end",
    ):
        assert contract in settings, f"settings safety contract missing: {contract}"

    managed = (SKILL_ROOT / "references/managed-configuration.md").read_text()
    assert "https://github.com/DigitalPals/CybexOS.git" in managed
    assert "ask before cloning" in managed
    assert "./tests/run" in managed and "ansible-playbook site.yml" in managed
    assert "Never substitute" in managed and "pkill qs" in managed

    dotfiles = (ROOT / "roles/dotfiles/tasks/agent-skills.yml").read_text()
    assert "import_tasks: agent-skills.yml" in (ROOT / "roles/dotfiles/tasks/main.yml").read_text()
    uninstall = (ROOT / "roles/uninstall/tasks/main.yml").read_text()
    update_worker = (ROOT / "assets/scripts/cybexos-update-run").read_text()
    release_updater = (ROOT / "assets/scripts/cybexos-release-update").read_text()
    release_workflow = (ROOT / ".github/workflows/release.yml").read_text()
    assert "scripts/manage-agent-skills" in dotfiles and "provision" in dotfiles
    assert "scripts/manage-agent-skills" in uninstall and "uninstall" in uninstall
    assert "is match('^CHANGED:')" in dotfiles
    assert "is match('^CHANGED:')" in uninstall
    assert '"$repo/scripts/manage-agent-skills" provision' in update_worker
    assert '"$current_link/agent-skills/cybexos"' in update_worker
    assert "run_as_update_owner" in update_worker
    assert '/usr/bin/sudo -n -u "#$owner_uid" -g "#$owner_gid"' in update_worker
    assert "stage/scripts/manage-agent-skills" in release_updater
    assert "stage/agent-skills/cybexos/SKILL.md" in release_updater
    assert "dist/verify/scripts/manage-agent-skills" in release_workflow
    assert "dist/verify/agent-skills/cybexos/SKILL.md" in release_workflow

    print("CybexOS skill metadata, routing, safety, and references are valid")


if __name__ == "__main__":
    main()
