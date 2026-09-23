#!/usr/bin/env python3
"""Verify that the Firefox editor mutates only CybexOS's entry."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
EDITOR = ROOT / "roles/dotfiles/files/manage-firefox-policy"
EXTENSION_ID = "{d634138d-c276-4fc8-924b-40a0ea21d284}"


def invoke(policy: Path, operation: str) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["CYBEXOS_FIREFOX_POLICY"] = str(policy)
    return subprocess.run(
        [sys.executable, str(EDITOR), operation],
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="cybexos-firefox.") as temporary:
        policy = Path(temporary) / "distribution/policies.json"
        policy.parent.mkdir(parents=True)
        original = {
            "policies": {
                "DisableTelemetry": True,
                "ExtensionSettings": {
                    "someone-elses-extension@example.invalid": {
                        "installation_mode": "allowed"
                    }
                },
            },
            "vendorMetadata": {"preserve": True},
        }
        policy.write_text(json.dumps(original))

        result = invoke(policy, "enable")
        assert result.returncode == 0, result.stderr
        enabled = json.loads(policy.read_text())
        assert enabled["vendorMetadata"] == original["vendorMetadata"]
        assert enabled["policies"]["DisableTelemetry"] is True
        assert enabled["policies"]["ExtensionSettings"][
            "someone-elses-extension@example.invalid"
        ] == {"installation_mode": "allowed"}
        assert enabled["policies"]["ExtensionSettings"][EXTENSION_ID][
            "installation_mode"
        ] == "force_installed"

        result = invoke(policy, "disable")
        assert result.returncode == 0, result.stderr
        assert json.loads(policy.read_text()) == original

        policy.write_text("{ invalid")
        result = invoke(policy, "enable")
        assert result.returncode == 1
        assert policy.read_text() == "{ invalid"

    print("Firefox policy editing preserves unrelated administrator policy")


if __name__ == "__main__":
    main()
