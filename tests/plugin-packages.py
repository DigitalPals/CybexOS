#!/usr/bin/env python3
"""Git transactions and cache identity, using only disposable local repositories."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "roles/desktop/files/quickshell/scripts/user-plugins.py"

with tempfile.TemporaryDirectory(prefix="cybex-plugin-packages-") as temporary:
    base = Path(temporary)
    packages = base / "plugins"
    env = {**os.environ, "CYBEXOS_PLUGIN_ROOT": str(packages),
           "CYBEXOS_USER_CONFIG_ROOT": str(base / "config"),
           "XDG_DATA_HOME": str(base / "data"), "PYTHONDONTWRITEBYTECODE": "1"}
    source = base / "source"
    source.mkdir()

    def git(*args):
        return subprocess.run(["git", "-C", str(source), *args], check=True,
                              text=True, capture_output=True).stdout.strip()

    def cli(*args, ok=True):
        result = subprocess.run(["python3", str(HELPER), *map(str, args)], env=env,
                                text=True, capture_output=True)
        assert (result.returncode == 0) == ok, result.stderr
        return result.stdout

    git("init", "-b", "main")
    git("config", "user.email", "test@example.invalid")
    git("config", "user.name", "Test")
    manifest = {"id": "example.git", "schemaVersion": 1, "name": "Git fixture", "version": "1",
                "kinds": ["bar-widget"], "entryPoints": {"barWidget": "Widget.qml"}}
    (source / "manifest.json").write_text(json.dumps(manifest))
    (source / "Widget.qml").write_text('import QtQuick\nItem {}\n')
    (source / "Sibling.qml").write_text('import QtQuick\nItem {}\n')
    git("add", ".")
    git("commit", "-m", "initial")
    cli("add", source)
    cli("add", source, ok=False)
    assert not json.loads(cli("list"))["plugins"][0]["enabled"]
    cli("enable", "example.git")
    cli("set", "example.git", "answer", "42")
    cli("layout-edit", "enable", "example.git", '{"section":"right","index":0}')
    cli("layout-edit", "set", "example.git", '{"key":"first","value":1}')
    cli("layout-edit", "set", "example.git", '{"key":"second","value":2}')
    saved = json.loads((base / "config/plugins.json").read_text())["plugins"]["example.git"]
    assert saved["settings"] == {"answer": 42, "first": 1, "second": 2}
    cli("layout-edit", "put", "example.git", '{"section":"left"}')
    assert json.loads(cli("list"))["widgets"][0]["section"] == "right"
    cli("layout-edit", "move", "example.git", '{"section":"left","fromSection":"right","fromIndex":0}')
    assert json.loads(cli("list"))["widgets"][0]["section"] == "left"
    before_invalid = (base / "config/plugins.json").read_bytes()
    cli("layout-edit", "move", "example.git", '{"section":"bad"}', ok=False)
    assert before_invalid == (base / "config/plugins.json").read_bytes()
    before = json.loads(cli("list", "--runtime-root", base / "runtime"))["plugins"][0]["source"]
    (source / "Sibling.qml").write_text('import QtQuick\nItem { property int answer: 42 }\n')
    git("add", ".")
    git("commit", "-m", "valid update")
    cli("update", "example.git", "--preview")
    assert "answer" not in (packages / "example.git/Sibling.qml").read_text()
    cli("update", "example.git")
    after = json.loads(cli("list", "--runtime-root", base / "runtime"))["plugins"][0]["source"]
    assert before != after, "Sibling edits must change the entrypoint's cache identity"
    installed_head = subprocess.check_output(["git", "-C", str(packages / "example.git"), "rev-parse", "HEAD"])
    manifest["entryPoints"]["barWidget"] = "Missing.qml"
    (source / "manifest.json").write_text(json.dumps(manifest))
    git("add", ".")
    git("commit", "-m", "invalid update")
    cli("update", "example.git", ok=False)
    assert installed_head == subprocess.check_output(["git", "-C", str(packages / "example.git"), "rev-parse", "HEAD"])
    (packages / "example.git/local.txt").write_text("preserve")
    cli("update", "example.git", ok=False)
    cli("clone", "example.git", "example.custom")
    saved = json.loads((base / "config/plugins.json").read_text())["plugins"]
    assert saved["example.custom"]["enabled"] and not saved["example.git"]["enabled"]
    assert saved["example.custom"]["settings"]["answer"] == 42
    cli("remove", "example.custom")
    saved = json.loads((base / "config/plugins.json").read_text())["plugins"]
    assert saved["example.git"]["enabled"]
    cli("clone", "example.git", "../escape", ok=False)
    cli("remove", "../escape", ok=False)
    (packages / "example.link").symlink_to(source, target_is_directory=True)
    cli("remove", "example.link", ok=False)
    builtin = base / "omarchy/shell/plugins/widgets"
    builtin.mkdir(parents=True)
    (builtin / "Original.qml").write_text("import QtQuick\nItem {}\n")
    (builtin / "Original.manifest.json").write_text(json.dumps({
        "schemaVersion": 1, "id": "omarchy.fixture", "name": "Built-in", "version": "1",
        "kinds": ["bar-widget"], "entryPoints": {"barWidget": "Original.qml"}}))
    cli("clone", "omarchy.fixture", "example.builtin", "--from", base / "omarchy")
    assert (packages / "example.builtin/Original.qml").is_file()
    assert json.loads((packages / "example.builtin/manifest.json").read_text())["omarchy"]["clonedFrom"] == "omarchy.fixture"
    cli("remove", "example.builtin")
    cli("remove", "example.git")
    assert not (packages / "example.git").exists()
    saved = json.loads((base / "config/plugins.json").read_text())["plugins"]
    assert saved["example.git"]["settings"]["answer"] == 42
    assert not any(path.name.startswith(".") for path in packages.iterdir())
print("Plugin Git transactions, clone restoration, and code snapshot identity passed")
