"""The Fedora release image tooling targets, read from the installation contract.

`fedora_release` in inventory/group_vars/all.yml is the release both
installation paths assert at runtime (site.yml and image/provision.yml), and
release-manifest.json `supportedFedora` is what updates and major upgrades
accept. Image tooling derives its release from the former and refuses one the
latter does not support. Checksum-pinned inputs that still name a release (the
Fedora Cloud builder image, for one) are kept in step by
image/test_fedora_release.py. `python3 image/fedora_target.py` prints the
release for shell steps.
"""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
# One quoted decimal, exactly as the inventory declares it. CI workflows and
# the image builder call this module rather than parsing the line themselves.
DECLARATION = re.compile(r'^fedora_release: "([1-9][0-9]*)"$', re.MULTILINE)


def fedora_release(root=ROOT):
    """Return the targeted release as a string, e.g. "44"."""
    root = Path(root)
    declared = DECLARATION.findall((root / "inventory/group_vars/all.yml").read_text())
    if len(declared) != 1:
        raise ValueError('inventory/group_vars/all.yml must declare fedora_release once, as a quoted number')
    release = declared[0]
    supported = json.loads((root / "release-manifest.json").read_text()).get("supportedFedora")
    if not isinstance(supported, list) or release not in supported:
        raise ValueError(f"Fedora {release} is not in release-manifest.json supportedFedora")
    return release


if __name__ == "__main__":
    print(fedora_release())
