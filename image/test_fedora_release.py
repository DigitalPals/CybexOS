"""One targeted Fedora release, and no release literal that can drift from it.

inventory/group_vars/all.yml fedora_release names the release both installation
paths target; release-manifest.json supportedFedora must include it. Files that
used to repeat the number derive it instead. The literals that remain are
checksum-pinned inputs (the Fedora Cloud builder image), published paths, or
names reviewed with the release (the required CI check); they must equal it.
The next-release CI preview must stay unable to block or slow a release.
These are source checks: they qualify no Fedora release.
"""
import configparser
import json
from pathlib import Path
import re
import tempfile
import unittest

import yaml

from fedora_target import fedora_release

ROOT = Path(__file__).resolve().parents[1]

# Release numbers in the forms these files spell them.
RELEASE_TOKEN = re.compile(
    r"Fedora (\d+)\b|\bfedora:(\d+)\b|\bfc(\d+)\b|/releases/(\d+)/|Generic-(\d+)-"
    r"|\bfedora-(\d+)-x86_64|RPM-GPG-KEY-fedora-(\d+)|repo=fedora(?:-cisco-openh264)?-(\d+)"
    r"|updates-released-f(\d+)|--version F(\d+)\b|/(\d+)/x86_64|CybexOS-Live-(\d+)|CYBEXOS-LIVE-(\d+)")

# These derive the release (inventory, $releasever or a CI build argument).
DERIVED = (
    ".github/actions/fedora-source-environment/action.yml",
    ".github/workflows/live-image.yml",
    "image/build-in-guest",
    "image/build.repo",
    "image/live.ks",
)
# These spell it out and are reviewed when it changes. Each must name it.
PINNED = (
    ".github/workflows/tests.yml",  # required check name and its container
    ".github/workflows/fedora-vm-convergence.yml",
    ".github/workflows/desktop-release.yml",  # RPM signing container
    "image/build",  # checksum-pinned Fedora Cloud builder image
    "image/qualify-checkout",
    "tests/fedora-vm-convergence",
    "image/compose",  # the livecd-tools behaviour its adapter compensates for
    "image/channels/stable.json",  # published update channel path
    "image/github_release.py",
    "inventory/group_vars/all.yml",  # mdview fcNN asset, source-build base image
)


def release_tokens(relative):
    for number, line in enumerate((ROOT / relative).read_text().splitlines(), 1):
        for match in RELEASE_TOKEN.finditer(line):
            yield number, match.group(0), next(group for group in match.groups() if group)


def workflow(name):
    document = yaml.safe_load((ROOT / ".github/workflows" / name).read_text())
    # YAML 1.1 reads the bare key `on` as true.
    document["on"] = document.pop(True, document.get("on"))
    return document


def steps_using(job, action):
    return [step for step in job["steps"] if step.get("uses", "").split("@")[0] == action]


class TargetedReleaseTests(unittest.TestCase):
    def test_inventory_release_is_supported_by_the_release_manifest(self):
        inventory = yaml.safe_load((ROOT / "inventory/group_vars/all.yml").read_text())
        manifest = json.loads((ROOT / "release-manifest.json").read_text())
        self.assertIsInstance(inventory["fedora_release"], str)
        self.assertIn(inventory["fedora_release"], manifest["supportedFedora"])
        self.assertEqual(fedora_release(), inventory["fedora_release"])

    def test_helper_refuses_an_unsupported_or_ambiguous_declaration(self):
        cases = {
            "unsupported": ('fedora_release: "45"\n', ["44"]),
            "unquoted": ("fedora_release: 44\n", ["44"]),
            "repeated": ('fedora_release: "44"\nfedora_release: "44"\n', ["44"]),
            "manifest without a list": ('fedora_release: "44"\n', "44"),
        }
        for label, (inventory, supported) in cases.items():
            with self.subTest(label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "inventory/group_vars").mkdir(parents=True)
                (root / "inventory/group_vars/all.yml").write_text(inventory)
                (root / "release-manifest.json").write_text(json.dumps({"supportedFedora": supported}))
                with self.assertRaises(ValueError):
                    fedora_release(root)


class ReleaseLiteralTests(unittest.TestCase):
    def test_derived_files_name_no_release(self):
        for relative in DERIVED:
            with self.subTest(relative):
                self.assertEqual([], list(release_tokens(relative)),
                                 "derive the release from inventory instead of spelling it")

    def test_pinned_release_literals_match_inventory(self):
        release = fedora_release()
        for relative in PINNED:
            with self.subTest(relative):
                tokens = list(release_tokens(relative))
                self.assertTrue(tokens, "names no release any more; move it to DERIVED")
                stale = [f"{relative}:{line}: {text}" for line, text, number in tokens if number != release]
                self.assertEqual([], stale, f"review these for Fedora {release} (see docs/fedora-major-upgrade.md)")

    def test_image_tooling_derives_the_release(self):
        compose = (ROOT / "image/compose").read_text()
        self.assertIn("release = fedora_release()", compose)
        self.assertIn('releasever=release,', compose)
        self.assertIn('f"CybexOS-Live-{fedora_release()}"', (ROOT / "image/build").read_text())
        self.assertIn('fedora_release=$(python3 "$source_root/image/fedora_target.py")',
                      (ROOT / "image/build-in-guest").read_text())
        self.assertIn("releases/$releasever/", (ROOT / "image/live.ks").read_text())
        # CI passes the release as a build argument; the default serves local builds.
        containerfile = (ROOT / "image/Containerfile.tests").read_text().splitlines()
        self.assertEqual([f"ARG FEDORA_RELEASE={fedora_release()}", "FROM fedora:${FEDORA_RELEASE}"],
                         [line for line in containerfile if line.startswith(("ARG ", "FROM "))])

    def test_image_repositories_expand_to_the_targeted_release(self):
        release = fedora_release()
        repositories = configparser.ConfigParser(interpolation=None)
        repositories.read(ROOT / "image/build.repo")
        for section in ("fedora", "updates", "fedora-cisco-openh264"):
            entry = repositories[section]
            for key in ("metalink", "gpgkey"):
                self.assertIn("$releasever", entry[key], f"{section} {key}")
                # image/compose substitutes exactly these two variables.
                expanded = entry[key].replace("$releasever", release).replace("$basearch", "x86_64")
                self.assertNotIn("$", expanded, f"{section} {key}")
        self.assertEqual(repositories["fedora"]["gpgkey"],
                         "file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-$releasever-x86_64")
        # The image composes from the COPR chroot the workstation template uses.
        template = configparser.ConfigParser(interpolation=None)
        template.read(ROOT / "roles/desktop/templates/hyprland-copr.repo.j2")
        workstation = template["copr:copr.fedorainfracloud.org:sdegler:hyprland"]["baseurl"]
        self.assertEqual(repositories["hyprland"]["baseurl"], workstation.replace("$basearch", "x86_64"))

    def test_fedora_cloud_builder_pins_agree(self):
        def assigned(source, pattern):
            return re.search(pattern, source, re.MULTILINE).group(1)

        pins = {}
        for relative in ("image/build", "image/qualify-checkout"):
            source = (ROOT / relative).read_text()
            name = assigned(source, r"^IMAGE = ['\"]([^'\"]+)['\"]$")
            pins[relative] = (assigned(source, r"^IMAGE_URL = ['\"]([^'\"]+)['\"] \+ IMAGE$") + name, name,
                              assigned(source, r"^IMAGE_SHA256 = ['\"]([0-9a-f]{64})['\"]$"))
        runner = (ROOT / "tests/fedora-vm-convergence").read_text()
        url = assigned(runner, r"^image_url=\$\{FEDORA_VM_IMAGE_URL:-([^}]+)\}$")
        pins["tests/fedora-vm-convergence"] = (url, url.rsplit("/", 1)[1],
                                               assigned(runner, r"^image_sha256=\$\{FEDORA_VM_IMAGE_SHA256:-([0-9a-f]{64})\}$"))
        # The image name and its checksum change together, in every consumer.
        self.assertEqual(1, len(set(pins.values())), pins)
        url, name, _ = pins["image/build"]
        release = fedora_release()
        self.assertTrue(name.startswith(f"Fedora-Cloud-Base-Generic-{release}-"), name)
        self.assertTrue(url.startswith(f"https://download.fedoraproject.org/pub/fedora/linux/releases/{release}/"), url)


class ContinuousIntegrationTests(unittest.TestCase):
    def test_required_source_contract_tracks_inventory(self):
        release = fedora_release()
        tests = workflow("tests.yml")
        # release.yml gates a release on this workflow, so every job is required.
        self.assertIn("workflow_call", tests["on"])
        for job in tests["jobs"].values():
            self.assertNotIn("continue-on-error", job)
        # Branch protection names the job; keep its id when the release changes.
        job = tests["jobs"]["fedora-44"]
        self.assertEqual(f"Fedora {release} source contract", job["name"])
        self.assertEqual(f"fedora:{release}", job["container"]["image"])
        [environment] = steps_using(job, "./.github/actions/fedora-source-environment")
        # Without inputs the shared step asserts the inventory release strictly.
        self.assertNotIn("with", environment)
        self.assertEqual("./tests/run", job["steps"][-1]["run"])
        action = yaml.safe_load((ROOT / ".github/actions/fedora-source-environment/action.yml").read_text())
        self.assertEqual("false", action["inputs"]["best-effort"]["default"])
        self.assertIn("python3 image/fedora_target.py", action["runs"]["steps"][-1]["run"])

    def test_preview_cannot_block_or_slow_a_release(self):
        release = fedora_release()
        supported = json.loads((ROOT / "release-manifest.json").read_text())["supportedFedora"]
        preview = workflow("fedora-preview.yml")
        self.assertLessEqual(set(preview["on"]), {"pull_request", "push", "schedule", "workflow_dispatch"})
        self.assertEqual({"branches": ["main"]}, preview["on"]["push"])
        # Nothing calls the preview, release.yml included.
        for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
            self.assertNotRegex(path.read_text(), r"uses:\s*\S*fedora-preview", path.name)
        tests = workflow("tests.yml")["jobs"]["fedora-44"]
        for job in preview["jobs"].values():
            self.assertIs(True, job["continue-on-error"])
            self.assertIs(False, job["strategy"]["fail-fast"])
            releases = job["strategy"]["matrix"]["fedora"]
            self.assertTrue(releases)
            for next_release in releases:
                # A qualified release belongs in tests.yml, not in a preview.
                self.assertRegex(next_release, r"^[1-9][0-9]*$")
                self.assertGreater(int(next_release), int(release))
                self.assertNotIn(next_release, supported)
            self.assertEqual("fedora:${{ matrix.fedora }}", job["container"]["image"])
            self.assertEqual(tests["env"], job["env"])
            [environment] = steps_using(job, "./.github/actions/fedora-source-environment")
            self.assertEqual({"fedora-release": "${{ matrix.fedora }}", "best-effort": "true"},
                             environment["with"])
            self.assertEqual(steps_using(tests, "actions/checkout")[0]["uses"],
                             steps_using(job, "actions/checkout")[0]["uses"])
            # Every check runs; what the release lacked still fails the job.
            runs = [step.get("run", "") for step in job["steps"]]
            self.assertIn("./tests/run", runs)
            self.assertIn("steps.environment.outputs.unavailable != ''", job["steps"][-1]["if"])
            self.assertIn("exit 1", job["steps"][-1]["run"])

    def test_image_source_contract_builds_the_inventory_release(self):
        job = workflow("live-image.yml")["jobs"]["welcome-and-accounts"]
        commands = "\n".join(step.get("run", "") for step in job["steps"])
        self.assertIn("release=$(python3 image/fedora_target.py)", commands)
        self.assertIn('--build-arg FEDORA_RELEASE="$FEDORA_RELEASE"', commands)
        self.assertEqual(2, commands.count('--version "F$FEDORA_RELEASE"'))


if __name__ == "__main__":
    unittest.main()
