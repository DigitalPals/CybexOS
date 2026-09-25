#!/usr/bin/env python3
"""The vendored Model Usage widget: upstream's unit tests, and its settings.

Upstream's tests expect the plugin's own layout (sources beside tests/), so
they run against a disposable copy assembled from the shell tree and
tests/model-usage. The settings check holds Common/SettingsHelpers.js to the
vendored manifest: the same keys and defaults, and every declared bound and
option accepted as is.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "roles/desktop/files/quickshell/ModelUsage"
TESTS = ROOT / "tests/model-usage"
HELPERS = ROOT / "roles/desktop/files/quickshell/Common/SettingsHelpers.js"

SETTINGS_CHECK = r"""
const H = require(process.argv[1]);
const widget = require(process.argv[2]).barWidget;
const defaults = H.defaultModOpts().modelusage;
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const fail = message => { console.error(message); process.exit(1); };
const keys = widget.schema.map(entry => entry.key).sort();
if (!same(Object.keys(defaults).sort(), keys))
    fail("modelusage keys differ from the manifest schema: " + keys);
if (!same(Object.keys(widget.defaults).sort(), keys))
    fail("the manifest's defaults and schema disagree");
for (const key of keys)
    if (!same(defaults[key], widget.defaults[key]))
        fail("default " + key + " differs: " + JSON.stringify(defaults[key]));
const accepted = (key, value) => {
    const saved = {}; saved[key] = value;
    return same(H.normalizeModOpts({ modelusage: saved }).modelusage[key], value);
};
for (const entry of widget.schema) {
    const options = (entry.options || []).map(option => option.value ?? option);
    const samples = entry.type === "integer" ? [entry.min, entry.max]
        : entry.type === "enum" ? options
        : entry.type === "multiselect" ? [options, [], options.slice(0, 1)]
        : entry.type === "boolean" ? [true, false]
        : [entry.defaultValue];
    for (const value of samples)
        if (!accepted(entry.key, value))
            fail("modelusage." + entry.key + " rejects " + JSON.stringify(value));
}
if (!accepted("cliproxyKeyFile", "~/.config/key") || !accepted("costKeeperUrl", ""))
    fail("optional paths and URLs must keep a value and allow clearing");
"""


def main() -> None:
    subprocess.run(["node", "-e", SETTINGS_CHECK, str(HELPERS), str(TESTS / "manifest.json")],
                   check=True)
    with tempfile.TemporaryDirectory(prefix="cybex-model-usage-") as temporary:
        package = Path(temporary) / "model-usage"
        shutil.copytree(RUNTIME, package)
        shutil.copytree(TESTS, package / "tests")
        env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
        for script in sorted((package / "scripts").glob("*.py")):
            subprocess.run(["python3", "-m", "py_compile", str(script)], check=True, env=env)
        result = subprocess.run(["python3", "-m", "unittest", "discover", "-s",
                                 str(package / "tests"), "-p", "test_*.py"],
                                cwd=package, env=env, text=True, capture_output=True)
        if result.returncode:
            raise SystemExit(result.stdout + result.stderr)
        subprocess.run(["node", str(package / "tests/test_usage_logic.js")], check=True,
                       stdout=subprocess.DEVNULL)
    print("Model Usage upstream tests and settings contract passed")


if __name__ == "__main__":
    main()
