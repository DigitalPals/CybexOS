"""SPDX SBOM generation, release binding and pipeline wiring; no image build."""
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest import mock

import yaml

import sbom

ROOT = Path(__file__).resolve().parents[1]
REVISION = "a" * 40
ISO = "CybexOS-Live-44-20260926T150946Z-99900b99.iso"
DESKTOP = "cybexos-desktop-1.2.3-1.20260926150946.gaaaaaaaaaaaa.fc44.x86_64.rpm"
PROVENANCE = {"utc": "2026-09-26T15:09:46.164249+00:00", "build_id": "20260926T150946Z-99900b99",
              "source_revision": REVISION, "source_dirty": False, "source_epoch": 1790000000,
              "source_content_sha256": "c" * 64, "source_file_count": 1234}
COMMIT_A, COMMIT_B = "1" * 64, "2" * 64


def row(*fields):
    return "\t".join(fields) + "\n"


RPMS = "".join((
    row("bash", "(none)", "5.3.0", "2.fc44", "x86_64", "GPL-3.0-or-later", "bash-5.3.0-2.fc44.src.rpm",
        "Fedora Project", "Fedora Project", "https://www.gnu.org/software/bash"),
    row("shadow-utils", "2", "4.17.4", "1.fc44", "x86_64", "BSD-3-Clause AND GPL-2.0-or-later",
        "shadow-utils-4.17.4-1.fc44.src.rpm", "Fedora Project", "Fedora Project", "https://github.com/shadow-maint/shadow"),
    row("gcc-c++", "(none)", "15.1.1", "2.fc44", "x86_64", "GPL-3.0-or-later WITH GCC-exception-3.1",
        "gcc-15.1.1-2.fc44.src.rpm", "Fedora Project", "Fedora Project", "http://gcc.gnu.org"),
    row("filesystem", "(none)", "3.18", "40.fc44", "x86_64", "LicenseRef-Fedora-Public-Domain",
        "filesystem-3.18-40.fc44.src.rpm", "Fedora Project", "Fedora Project", "https://pagure.io/filesystem"),
    row("steam", "(none)", "1.0.0.85", "1.fc44", "i686", "Steam License Agreement and MIT",
        "steam-1.0.0.85-1.fc44.src.rpm", "RPM Fusion", "RPM Fusion", "http://www.steampowered.com/"),
    row("hyprland", "(none)", "0.51.0", "1.fc44", "x86_64", "BSD-3-Clause", "hyprland-0.51.0-1.fc44.src.rpm",
        "Fedora Copr - user sdegler", "Fedora Copr - user sdegler", "https://hyprland.org"),
    row("brave-browser", "(none)", "1.80.115", "1", "x86_64", "(none)", "(none)", "Brave Software",
        "(none)", "not a url"),
    row("1password", "(none)", "8.11.0", "1", "x86_64", "Proprietary", "1password-8.11.0-1.src.rpm",
        "(none)", "1Password <support@1password.com>", "https://1password.com"),
    row("voxtype", "(none)", "0.7.5", "1", "x86_64", "MIT", "voxtype-0.7.5-1.src.rpm", "(none)", "(none)", "(none)"),
    row("cybexos-desktop", "1", "1.2.3", "1.20260926150946.gaaaaaaaaaaaa.fc44", "x86_64",
        "MIT AND LicenseRef-CybexOS-Bundled-Components", "cybexos-desktop-1.2.3-1.src.rpm",
        "(none)", "(none)", "https://github.com/DigitalPals/CybexOS"),
    row("gpg-pubkey", "(none)", "105ef944", "65ca2f1c", "(none)", "pubkey", "(none)", "(none)", "(none)", "(none)"),
))
FLATPAKS = "".join((
    row("app", "org.localsend.localsend_app", "x86_64", "stable", "flathub", COMMIT_A, "1.17.0"),
    row("runtime", "org.freedesktop.Platform", "x86_64", "24.08", "flathub", COMMIT_B, ""),
))
INVENTORY = {
    "fedora_release": "44",
    "features": {"developer_tools": False, "source_builds": True, "proprietary_apps": True, "tailscale": False},
    "github_release_apps": [
        {"name": "lazygit", "enabled": "{{ features.developer_tools }}", "repo": "jesseduffield/lazygit",
         "asset_regex": "^lazygit_.*_linux_x86_64[.]tar[.]gz$", "kind": "archive", "version": "v0.64.1",
         "checksum": "sha256:" + "3" * 64},
        {"name": "voxtype", "enabled": True, "repo": "peteonrails/voxtype",
         "asset_regex": "^voxtype-.*[.]x86_64[.]rpm$", "kind": "rpm", "version": "v0.7.5",
         "checksum": "sha256:" + "4" * 64},
        {"name": "balena", "enabled": "true", "repo": "balena-io/balena-cli",
         "asset_regex": "^balena-cli-.*-linux-x64-standalone[.]tar[.]gz$", "kind": "archive",
         "version": "v25.2.5", "checksum": "sha256:" + "5" * 64},
        {"name": "oh-my-posh", "enabled": True, "repo": "JanDeDobbeleer/oh-my-posh",
         "asset_regex": "^posh-linux-amd64$", "kind": "binary", "version": "v30.6.5",
         "checksum": "SHA256:" + "6" * 64},
    ],
    "nerd_font_apps": [
        {"name": "nerd-font-fira-code", "repo": "ryanoasis/nerd-fonts", "asset_regex": "^FiraCode[.]tar[.]xz$",
         "kind": "font", "version": "v3.5.1", "checksum": "sha256:" + "7" * 64},
    ],
    "pinned_font_archives": [
        {"name": "oppo-sans", "version": "4.0", "url": "https://fonts.example/oppo.zip",
         "checksum": "sha256:" + "8" * 64, "expected_font": "OPPO Sans.ttf"},
    ],
    "pinned_font_files": [
        {"name": "figtree", "version": "1.2", "filename": "Figtree[wght].ttf", "checksum": "sha256:" + "9" * 64,
         "url": "https://raw.githubusercontent.com/o/figtree/0123/Figtree%5Bwght%5D.ttf",
         "license_url": "https://raw.githubusercontent.com/o/figtree/0123/OFL.txt",
         "license_checksum": "sha256:" + "a" * 64, "license_filename": "OFL.txt"},
    ],
    "omawrite_version": "v0.5.0", "omawrite_commit": "b" * 40, "omawrite_checksum": "sha256:" + "c" * 64,
    "lazyvim_starter_commit": "d" * 40,
    "source_apps": [
        {"name": "awww", "repo_url": "https://codeberg.org/LGFae/awww.git", "tag": "v0.12.1",
         "commit": "e" * 40, "binary_names": ["awww"]},
        {"name": "wayfreeze", "repo_url": "https://github.com/jappie3/wayfreeze.git", "tag": "0.2.1",
         "commit": "f" * 40, "binary_names": ["wayfreeze"]},
    ],
}
APPS_DEFAULTS = {"apps_vendor_repo_keys": [
    {"name": "brave-browser", "url": "https://keys.example/brave.asc", "checksum": "sha256:" + "0" * 64,
     "enabled": "{{ features.proprietary_apps | bool }}"},
    {"name": "tailscale", "url": "https://keys.example/tailscale.gpg", "checksum": "sha256:" + "1" * 64,
     "enabled": "{{ features.tailscale | bool }}"},
]}
ASSETS = {"5" * 64: "balena-cli-v25.2.5-linux-x64-standalone.tar.gz"}


def owners():
    return {app["name"]: app["repo"].split("/")[0] for app in INVENTORY["github_release_apps"] if app["kind"] == "rpm"}


def document(rpms=RPMS, flatpaks=FLATPAKS, **changes):
    arguments = dict(
        rpms=sbom.parse_rpm_inventory(rpms), flatpaks=sbom.parse_flatpak_inventory(flatpaks),
        pins=sbom.pinned_inputs(INVENTORY, APPS_DEFAULTS, ASSETS), provenance=PROVENANCE,
        version="1.2.3", iso=(ISO, "f" * 64), desktop_rpm=(DESKTOP, "e" * 64),
        source_archive_sha256="d" * 64, owners=owners())
    arguments.update(changes)
    return sbom.build_document(**arguments)


def packages(result):
    return {package["SPDXID"]: package for package in result["packages"]}


def named(result, name):
    found = [package for package in result["packages"] if package["name"] == name]
    assert len(found) == 1, (name, found)
    return found[0]


def purl_of(package):
    return next(item["referenceLocator"] for item in package["externalRefs"] if item["referenceType"] == "purl")


class RawInventories(unittest.TestCase):
    def test_queryformat_is_the_parsed_field_order(self):
        self.assertEqual(re.findall(r"%\{([A-Z]+)\}", sbom.RPM_QUERYFORMAT),
                         [field.upper() for field in sbom.RPM_FIELDS])
        self.assertEqual(sbom.RPM_QUERYFORMAT.count("\t"), len(sbom.RPM_FIELDS) - 1)
        self.assertTrue(sbom.RPM_QUERYFORMAT.endswith("\n"))

    def test_rpm_inventory_handles_none_epoch_and_skips_imported_keys(self):
        records = {record["name"]: record for record in sbom.parse_rpm_inventory(RPMS)}
        self.assertNotIn("gpg-pubkey", records)
        self.assertEqual(len(records), 10)
        self.assertEqual(records["bash"]["epoch"], "")
        self.assertEqual(records["shadow-utils"]["epoch"], "2")
        self.assertEqual(records["voxtype"]["url"], "")
        self.assertEqual(records["brave-browser"]["license"], "")
        self.assertEqual(records["voxtype"]["vendor"], "")

    def test_malformed_rpm_lines_fail_instead_of_dropping_packages(self):
        good = row("bash", "(none)", "5.3", "1", "x86_64", "MIT", "x.src.rpm", "V", "P", "(none)")
        for bad in (good.replace("\tMIT", "\tM\tIT"), good.replace("\tP\t", "\t"),
                    good.replace("(none)\t5.3", "one\t5.3"), good.replace("bash", "ba sh"),
                    good.replace("x86_64", "(none)"), ""):
            with self.subTest(line=bad), self.assertRaises(ValueError):
                sbom.parse_rpm_inventory(bad)

    def test_flatpak_inventory_requires_full_commits(self):
        refs = sbom.parse_flatpak_inventory(FLATPAKS)
        self.assertEqual([(ref["kind"], ref["application"], ref["version"]) for ref in refs],
                         [("app", "org.localsend.localsend_app", "1.17.0"), ("runtime", "org.freedesktop.Platform", "")])
        for bad in (FLATPAKS.replace(COMMIT_A, "1" * 12), FLATPAKS.replace("app\t", "extension\t"),
                    FLATPAKS.replace("\t1.17.0", ""), FLATPAKS.replace("org.localsend.localsend_app", "../x")):
            with self.subTest(text=bad), self.assertRaises(ValueError):
                sbom.parse_flatpak_inventory(bad)

    def test_capture_writes_parseable_inventories_from_the_image_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, output = Path(temporary) / "root", Path(temporary) / "artifacts"
            output.mkdir()
            for kind, application, branch, commit in (("app", "org.localsend.localsend_app", "stable", COMMIT_A),
                                                      ("runtime", "org.freedesktop.Platform", "24.08", COMMIT_B)):
                deploy = root / "var/lib/flatpak" / kind / application / "x86_64" / branch
                (deploy / commit).mkdir(parents=True)
                (deploy / "active").symlink_to(commit)
            calls = []

            class Result:
                def __init__(self, stdout):
                    self.stdout = stdout

            def run(command, **kwargs):
                calls.append(command)
                self.assertTrue(kwargs["check"])
                if command[0] == "rpm":
                    self.assertEqual(command[-1], sbom.RPM_QUERYFORMAT)
                    return Result("".join(reversed(RPMS.splitlines(keepends=True))))
                if "--app" in command:
                    # A title row, as on a terminal, and a dropped empty version.
                    return Result("Application ID\tArch\tBranch\tOrigin\tVersion\n"
                                  "org.localsend.localsend_app\tx86_64\tstable\tflathub\t1.17.0\n")
                return Result("org.freedesktop.Platform\tx86_64\t24.08\tflathub\n")

            rpm_path, flatpak_path = sbom.capture_inventories(root, output, run)
            self.assertEqual(rpm_path.read_text(), "".join(sorted(RPMS.splitlines(keepends=True))))
            self.assertEqual(flatpak_path.read_text(), FLATPAKS)
            self.assertEqual(calls[1][:6], ["chroot", str(root), "flatpak", "list", "--system", "--app"])
            (root / "var/lib/flatpak/app/org.localsend.localsend_app/x86_64/stable/active").unlink()
            with self.assertRaisesRegex(ValueError, "deployed commit"):
                sbom.capture_inventories(root, output, run)


class Licenses(unittest.TestCase):
    def test_spdx_expressions_are_kept_and_others_become_defined_license_refs(self):
        for raw, expected in (
            ("MIT", "MIT"),
            ("MIT  AND (GPL-2.0-or-later OR LGPL-2.1-only)", "MIT AND (GPL-2.0-or-later OR LGPL-2.1-only)"),
            ("((MIT OR ISC) AND Zlib)", "((MIT OR ISC) AND Zlib)"),
            ("GPL-2.0+ WITH Classpath-exception-2.0", "GPL-2.0+ WITH Classpath-exception-2.0"),
            ("LicenseRef-Fedora-Public-Domain AND MIT", "LicenseRef-Fedora-Public-Domain AND MIT"),
            ("(none)", "NOASSERTION"), ("", "NOASSERTION"), ("NONE", "NONE"),
        ):
            extracted = {}
            with self.subTest(raw=raw):
                self.assertEqual(sbom.declared_license(raw, extracted), expected)
                self.assertEqual(set(extracted), set(re.findall(r"LicenseRef-[A-Za-z0-9.-]+", expected)))
        for raw in ("GPLv2+ and MIT", "Proprietary", "(MIT", "MIT)", "MIT AND", "MIT WITH LicenseRef-x",
                    "LicenseRef-Callaway-GPLv2+", "DocumentRef-x:LicenseRef-y", "ASL 2.0", "BSD", "MIT, BSD"):
            extracted = {}
            with self.subTest(raw=raw):
                result = sbom.declared_license(raw, extracted)
                self.assertRegex(result, r"\ALicenseRef-rpm-[A-Za-z0-9.-]+-[0-9a-f]{8}\Z")
                self.assertEqual(extracted[result]["extractedText"], raw)
                self.assertEqual(result, sbom.declared_license(raw, {}))
        self.assertNotEqual(sbom.license_ref_id("GPL v2"), sbom.license_ref_id("GPL-v2"))


class Document(unittest.TestCase):
    def test_required_spdx_fields_and_provenance(self):
        result = document()
        self.assertEqual(result["spdxVersion"], "SPDX-2.3")
        self.assertEqual(result["dataLicense"], "CC0-1.0")
        self.assertEqual(result["SPDXID"], "SPDXRef-DOCUMENT")
        self.assertEqual(result["name"], "CybexOS-Live-44-20260926T150946Z-99900b99")
        self.assertEqual(result["creationInfo"], {"created": "2026-09-26T15:09:46Z",
                                                  "creators": ["Tool: cybexos-sbom-1.2.3"]})
        self.assertRegex(result["documentNamespace"],
                         r"\Ahttps://github\.com/DigitalPals/CybexOS/spdx/CybexOS-Live-44-20260926T150946Z-99900b99-"
                         r"[0-9a-f-]{36}\Z")
        root = sbom.described_package(result)
        self.assertEqual(root["SPDXID"], "SPDXRef-CybexOS")
        self.assertEqual(root["downloadLocation"], f"git+https://github.com/DigitalPals/CybexOS.git@{REVISION}")
        self.assertEqual((root["packageFileName"], sbom.file_checksum(root)), (ISO, "f" * 64))
        self.assertIn("c" * 64, root["sourceInfo"])
        self.assertIn("d" * 64, root["sourceInfo"])
        self.assertEqual(purl_of(root), f"pkg:github/digitalpals/cybexos@{REVISION}")
        for package in result["packages"]:
            self.assertRegex(package["SPDXID"], r"\ASPDXRef-[A-Za-z0-9.-]+\Z")
            for key in ("name", "downloadLocation", "licenseConcluded", "licenseDeclared", "copyrightText"):
                self.assertTrue(package[key], (package["SPDXID"], key))
            self.assertIs(package["filesAnalyzed"], False)

    def test_namespace_is_unique_per_revision_and_artifact(self):
        first = document()["documentNamespace"]
        self.assertEqual(first, document()["documentNamespace"])
        self.assertNotEqual(first, document(provenance={**PROVENANCE, "source_revision": "b" * 40})["documentNamespace"])
        self.assertNotEqual(first, document(provenance={**PROVENANCE, "build_id": "other-build"})["documentNamespace"])

    def test_output_is_byte_identical_for_reordered_inputs(self):
        reordered = document(rpms="".join(reversed(RPMS.splitlines(keepends=True))),
                             flatpaks="".join(reversed(FLATPAKS.splitlines(keepends=True))),
                             pins=list(reversed(sbom.pinned_inputs(INVENTORY, APPS_DEFAULTS, ASSETS))))
        self.assertEqual(sbom.serialize(document()), sbom.serialize(reordered))
        identifiers = [package["SPDXID"] for package in document()["packages"]]
        self.assertEqual(identifiers[0], "SPDXRef-CybexOS")
        self.assertEqual(identifiers[1:], sorted(identifiers[1:]))

    def test_relationships_are_complete_and_reference_existing_elements(self):
        result = document()
        identifiers = [package["SPDXID"] for package in result["packages"]]
        self.assertEqual(len(identifiers), len(set(identifiers)))
        relations = {(item["spdxElementId"], item["relationshipType"], item["relatedSpdxElement"])
                     for item in result["relationships"]}
        self.assertEqual(len(relations), len(result["relationships"]))
        self.assertIn(("SPDXRef-DOCUMENT", "DESCRIBES", "SPDXRef-CybexOS"), relations)
        for source, _, target in relations:
            self.assertIn(source, {*identifiers, "SPDXRef-DOCUMENT"})
            self.assertIn(target, identifiers)
        contained = {target for source, kind, target in relations if kind == "CONTAINS"}
        self.assertEqual(contained, set(identifiers) - {"SPDXRef-CybexOS"})
        parents = {target: source for source, kind, target in relations if kind == "CONTAINS"}
        desktop = named(result, "cybexos-desktop")["SPDXID"]
        self.assertEqual(parents[desktop], "SPDXRef-CybexOS")
        self.assertEqual(parents[named(result, "bash")["SPDXID"]], "SPDXRef-CybexOS")
        # Bundled downloads live in the desktop RPM payload; RPM-kind
        # applications and repository keys are separate parts of the image.
        self.assertEqual(parents["SPDXRef-Download-oh-my-posh-v30.6.5"], desktop)
        self.assertEqual(parents["SPDXRef-Download-figtree-1.2"], desktop)
        self.assertEqual(parents["SPDXRef-RPM-voxtype-0.7.5-1-x86-64"], "SPDXRef-CybexOS")
        self.assertNotIn("SPDXRef-Download-voxtype-v0.7.5", parents)
        self.assertEqual(parents[named(result, "brave-browser-repository-key")["SPDXID"]], "SPDXRef-CybexOS")
        defined = {item["licenseId"] for item in result["hasExtractedLicensingInfos"]}
        used = {reference for package in result["packages"]
                for reference in re.findall(r"LicenseRef-[A-Za-z0-9.-]+", package["licenseDeclared"])}
        self.assertEqual(used, defined)
        self.assertIn("LicenseRef-CybexOS-Bundled-Components", defined)

    def test_rpm_identity_supplier_and_purl(self):
        result = document()
        shadow = named(result, "shadow-utils")
        self.assertEqual(shadow["versionInfo"], "2:4.17.4-1.fc44")
        self.assertEqual(purl_of(shadow),
                         "pkg:rpm/fedora/shadow-utils@4.17.4-1.fc44?arch=x86_64&distro=fedora-44&epoch=2")
        self.assertEqual(shadow["supplier"], "Organization: Fedora Project")
        self.assertEqual(shadow["sourceInfo"], "built from source RPM shadow-utils-4.17.4-1.fc44.src.rpm")
        self.assertEqual(shadow["homepage"], "https://github.com/shadow-maint/shadow")
        self.assertEqual(shadow["downloadLocation"], "NOASSERTION")
        self.assertEqual(purl_of(named(result, "gcc-c++")),
                         "pkg:rpm/fedora/gcc-c%2B%2B@15.1.1-2.fc44?arch=x86_64&distro=fedora-44")
        self.assertTrue(purl_of(named(result, "steam")).startswith("pkg:rpm/rpmfusion/steam@1.0.0.85-1.fc44?arch=i686"))
        self.assertTrue(named(result, "steam")["licenseDeclared"].startswith("LicenseRef-rpm-Steam-License"))
        self.assertTrue(purl_of(named(result, "hyprland")).startswith("pkg:rpm/copr/hyprland@"))
        brave = named(result, "brave-browser")
        self.assertTrue(purl_of(brave).startswith("pkg:rpm/brave/brave-browser@"))
        self.assertNotIn("homepage", brave)
        self.assertNotIn("sourceInfo", brave)
        self.assertEqual(brave["licenseDeclared"], "NOASSERTION")
        onepassword = named(result, "1password")
        self.assertEqual(onepassword["supplier"], "Organization: 1Password (support@1password.com)")
        self.assertTrue(onepassword["licenseDeclared"].startswith("LicenseRef-rpm-Proprietary-"))
        voxtype = named(result, "voxtype")
        self.assertTrue(purl_of(voxtype).startswith("pkg:rpm/peteonrails/voxtype@0.7.5-1?"))
        self.assertEqual(voxtype["supplier"], "NOASSERTION")
        # The installed RPM records the exact pinned release download.
        self.assertEqual(voxtype["downloadLocation"], "https://github.com/peteonrails/voxtype/releases/tag/v0.7.5")
        self.assertEqual(sbom.file_checksum(voxtype), "4" * 64)
        self.assertIn("pkg:github/peteonrails/voxtype@v0.7.5",
                      [item["referenceLocator"] for item in voxtype["externalRefs"]])
        desktop = named(result, "cybexos-desktop")
        self.assertTrue(purl_of(desktop).startswith("pkg:rpm/cybexos/cybexos-desktop@1.2.3-"))
        self.assertEqual((desktop["packageFileName"], sbom.file_checksum(desktop)), (DESKTOP, "e" * 64))

    def test_desktop_artifact_must_be_the_installed_package(self):
        with self.assertRaisesRegex(ValueError, "not the installed"):
            document(desktop_rpm=("cybexos-desktop-9.9.9-1.fc44.x86_64.rpm", "e" * 64))
        without = "".join(line for line in RPMS.splitlines(keepends=True) if not line.startswith("cybexos-desktop"))
        with self.assertRaisesRegex(ValueError, "does not contain the desktop RPM"):
            document(rpms=without)
        # Without the desktop RPM in the root, bundled downloads stay related to the root.
        sbom.verify_document(document(rpms=without, desktop_rpm=None))

    def test_flatpak_components(self):
        result = document()
        app = packages(result)["SPDXRef-Flatpak-app-org.localsend.localsend-app-x86-64-stable"]
        self.assertEqual((app["name"], app["versionInfo"], app["primaryPackagePurpose"]),
                         ("org.localsend.localsend_app", "1.17.0", "APPLICATION"))
        self.assertEqual(app["supplier"], "Organization: Flathub")
        self.assertIn({"referenceCategory": "OTHER", "referenceType": "ostree-commit", "referenceLocator": COMMIT_A},
                      app["externalRefs"])
        runtime = named(result, "org.freedesktop.Platform")
        self.assertEqual((runtime["versionInfo"], runtime["primaryPackagePurpose"]), ("24.08", "FRAMEWORK"))
        self.assertIn("runtime/org.freedesktop.Platform/x86_64/24.08", runtime["sourceInfo"])

    def test_sanitized_identifier_collisions_remain_unique(self):
        colliding = RPMS + row("gcc-c__", "(none)", "15.1.1", "2.fc44", "x86_64", "MIT", "(none)",
                               "Fedora Project", "(none)", "(none)")
        result = document(rpms=colliding)
        identifiers = [package["SPDXID"] for package in result["packages"]]
        self.assertEqual(len(identifiers), len(set(identifiers)))
        self.assertEqual(sbom.serialize(result), sbom.serialize(document(rpms=colliding)))

    def test_invalid_provenance_is_rejected(self):
        for change in ({"source_revision": "abc"}, {"build_id": "../x"}, {"utc": "2026-09-26T15:09:46"}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                document(provenance={**PROVENANCE, **change})

    def test_structural_verification_rejects_broken_documents(self):
        def broken(change):
            result = json.loads(json.dumps(document()))
            change(result)
            return result

        for label, change in (
            ("dangling", lambda d: d["relationships"].append(
                {"spdxElementId": "SPDXRef-CybexOS", "relationshipType": "CONTAINS", "relatedSpdxElement": "SPDXRef-x"})),
            ("duplicate", lambda d: d["packages"].append(dict(d["packages"][1]))),
            ("orphan", lambda d: d["relationships"].pop()),
            ("license", lambda d: d.pop("hasExtractedLicensingInfos")),
            ("describes", lambda d: d["relationships"].pop(0)),
            ("version", lambda d: d.update(spdxVersion="SPDX-2.2")),
            ("created", lambda d: d["creationInfo"].update(created="2026-09-26")),
            ("identifier", lambda d: d["packages"][1].update(SPDXID="SPDXRef-has space")),
            ("checksum", lambda d: d["packages"][0]["checksums"][0].update(checksumValue="F" * 64)),
        ):
            with self.subTest(label=label), self.assertRaises(ValueError):
                sbom.verify_document(broken(change))


class PinnedInputs(unittest.TestCase):
    def pins(self):
        return {package["name"]: (package, bundled)
                for package, bundled in sbom.pinned_inputs(INVENTORY, APPS_DEFAULTS, ASSETS)}

    def test_inventory_pins_with_urls_checksums_and_feature_gates(self):
        pins = self.pins()
        self.assertNotIn("lazygit", pins)  # developer_tools is off in this fixture
        self.assertNotIn("tailscale-repository-key", pins)
        posh, placement = pins["oh-my-posh"]
        self.assertEqual(placement, "desktop")
        self.assertEqual(posh["downloadLocation"],
                         "https://github.com/JanDeDobbeleer/oh-my-posh/releases/download/v30.6.5/posh-linux-amd64")
        self.assertEqual(posh["checksums"], [{"algorithm": "SHA256", "checksumValue": "6" * 64}])
        self.assertEqual(purl_of(posh), "pkg:github/jandedobbeleer/oh-my-posh@v30.6.5")
        balena = pins["balena"][0]
        self.assertEqual(balena["downloadLocation"], "https://github.com/balena-io/balena-cli/releases/download/"
                                                     "v25.2.5/balena-cli-v25.2.5-linux-x64-standalone.tar.gz")
        self.assertEqual(balena["packageFileName"], "balena-cli-v25.2.5-linux-x64-standalone.tar.gz")
        voxtype, placement = pins["voxtype"]
        self.assertEqual(placement, "rpm")
        self.assertEqual(voxtype["downloadLocation"], "https://github.com/peteonrails/voxtype/releases/tag/v0.7.5")
        self.assertEqual(voxtype["checksums"][0]["checksumValue"], "4" * 64)
        self.assertEqual(pins["nerd-font-fira-code"][0]["downloadLocation"],
                         "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/FiraCode.tar.xz")
        figtree = pins["figtree"][0]
        self.assertEqual(figtree["downloadLocation"], INVENTORY["pinned_font_files"][0]["url"])
        self.assertEqual(purl_of(figtree), "pkg:generic/figtree@1.2?checksum=sha256:" + "9" * 64 +
                         "&download_url=https://raw.githubusercontent.com/o/figtree/0123/Figtree%255Bwght%255D.ttf")
        self.assertEqual(pins["oppo-sans"][0]["checksums"][0]["checksumValue"], "8" * 64)
        omawrite = pins["omawrite"][0]
        self.assertEqual(omawrite["downloadLocation"], "https://codeload.github.com/omacom/omawrite/tar.gz/" + "b" * 40)
        self.assertEqual(omawrite["checksums"][0]["checksumValue"], "c" * 64)
        self.assertEqual(pins["awww"][0]["downloadLocation"], "git+https://codeberg.org/LGFae/awww.git@" + "e" * 40)
        self.assertTrue(purl_of(pins["awww"][0]).startswith("pkg:generic/awww@v0.12.1?vcs_url=git%2Bhttps://"))
        self.assertEqual(purl_of(pins["wayfreeze"][0]), "pkg:github/jappie3/wayfreeze@" + "f" * 40)
        self.assertEqual(pins["lazyvim-starter"][0]["downloadLocation"],
                         "git+https://github.com/LazyVim/starter.git@" + "d" * 40)
        key, placement = pins["brave-browser-repository-key"]
        self.assertEqual(placement, "root")
        self.assertEqual(key["checksums"][0]["checksumValue"], "0" * 64)

    def test_source_builds_follow_their_feature(self):
        inventory = {**INVENTORY, "features": {**INVENTORY["features"], "source_builds": False}}
        names = {package["name"] for package, _ in sbom.pinned_inputs(inventory, APPS_DEFAULTS)}
        self.assertFalse({"awww", "wayfreeze"} & names)

    def test_unknown_enable_conditions_fail_closed(self):
        for value in ("{{ features.x and features.y }}", "{{ other }}", "maybe"):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "enable condition"):
                sbom.feature_enabled(value, {"x": True})
        self.assertTrue(sbom.feature_enabled("{{ features.x | bool }}", {"x": True}))
        self.assertFalse(sbom.feature_enabled("{{ features.missing }}", {}))

    def test_download_manifest_names_only_upstream_cache_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "manifest.json"
            manifest.write_text(json.dumps({"entries": [
                {"path": "/var/cache/cybexos-upstream/lazygit/v0.64.1/lazygit_0.64.1_linux_x86_64.tar.gz",
                 "sha256": "3" * 64},
                {"path": "/usr/local/share/fonts/figtree/1.2/Figtree[wght].ttf", "sha256": "9" * 64},
            ]}))
            self.assertEqual(sbom.download_assets(manifest), {"3" * 64: "lazygit_0.64.1_linux_x86_64.tar.gz"})
            self.assertEqual(sbom.download_assets(Path(temporary) / "missing.json"), {})

    def test_repository_inventory_pins_are_complete(self):
        inventory = yaml.safe_load((ROOT / "inventory/group_vars/all.yml").read_text())
        defaults = yaml.safe_load((ROOT / "roles/apps/defaults/main.yml").read_text())
        pins = sbom.pinned_inputs(inventory, defaults)
        names = {package["name"] for package, _ in pins}
        expected = {app["name"] for app in inventory["github_release_apps"] + inventory["nerd_font_apps"]
                    if sbom.feature_enabled(app.get("enabled", True), inventory["features"])}
        expected |= {font["name"] for font in inventory["pinned_font_archives"] + inventory["pinned_font_files"]}
        expected |= {"omawrite", "lazyvim-starter"}
        self.assertLessEqual(expected, names)
        for package, _ in pins:
            with self.subTest(pin=package["name"]):
                location = package["downloadLocation"]
                self.assertTrue(location.startswith(("https://", "git+https://")), location)
                if location.startswith("https://"):
                    self.assertRegex(sbom.file_checksum(package) or "", r"\A[0-9a-f]{64}\Z")
                else:
                    self.assertRegex(location, r"@[0-9a-f]{40}\Z")

    def test_urls_outside_the_inventory_match_their_installers(self):
        installer = (ROOT / "roles/apps/files/omawrite-install").read_text()
        self.assertIn(f'"https://codeload.github.com/{sbom.OMAWRITE_REPOSITORY}/tar.gz/$revision"', installer)
        playbook = yaml.safe_load((ROOT / "image/applications.yml").read_text())
        starter = [task for task in playbook[0]["tasks"] if task.get("name") == "Include the pinned Neovim starter"]
        self.assertEqual(starter[0]["ansible.builtin.git"]["repo"], sbom.LAZYVIM_STARTER)


class ReleaseFiles(unittest.TestCase):
    def artifacts(self, root):
        checkout, artifacts = root / "checkout", root / "artifacts"
        (checkout / "inventory/group_vars").mkdir(parents=True)
        (checkout / "roles/apps/defaults").mkdir(parents=True)
        # JSON is YAML, so the fixture inventory needs no separate encoding.
        (checkout / "inventory/group_vars/all.yml").write_text(json.dumps(INVENTORY))
        (checkout / "roles/apps/defaults/main.yml").write_text(json.dumps(APPS_DEFAULTS))
        (checkout / "VERSION").write_text("1.2.3\n")
        artifacts.mkdir()
        (artifacts / sbom.RPM_INVENTORY).write_text(RPMS)
        (artifacts / sbom.FLATPAK_INVENTORY).write_text(FLATPAKS)
        (artifacts / "build-provenance.json").write_text(json.dumps(PROVENANCE))
        (artifacts / ISO).write_bytes(b"fixture ISO")
        (artifacts / DESKTOP).write_bytes(b"fixture unsigned RPM")
        (artifacts / "source.tar.gz").write_bytes(b"fixture source")
        return checkout, artifacts

    def test_build_helper_names_sbom_after_iso_and_binds_artifact_digests(self):
        with tempfile.TemporaryDirectory() as temporary:
            checkout, artifacts = self.artifacts(Path(temporary))
            path = sbom.write_build_sbom(artifacts, ISO, {ISO: "f" * 64}, checkout=checkout)
            self.assertEqual(path.name, "CybexOS-Live-44-20260926T150946Z-99900b99.spdx.json")
            self.assertEqual(sorted(item.name for item in artifacts.iterdir() if item.name.startswith(".")), [])
            result = sbom.verify_release_sbom(path, ISO, "f" * 64, [sbom.sha256_file(artifacts / DESKTOP)])
            self.assertIn(sbom.sha256_file(artifacts / "source.tar.gz"), sbom.described_package(result)["sourceInfo"])
            with self.assertRaisesRegex(ValueError, "exact ISO"):
                sbom.verify_release_sbom(path, ISO, "0" * 64)
            with self.assertRaisesRegex(ValueError, "exact ISO"):
                sbom.verify_release_sbom(path, "Other.iso", "f" * 64)
            with self.assertRaisesRegex(ValueError, "candidate desktop RPM"):
                sbom.verify_release_sbom(path, ISO, "f" * 64, ["0" * 64])
            (artifacts / "cybexos-desktop-extra.rpm").write_bytes(b"second")
            with self.assertRaisesRegex(ValueError, "exactly one desktop RPM"):
                sbom.write_build_sbom(artifacts, ISO, checkout=checkout)

    def test_command_line_generates_and_verifies(self):
        with tempfile.TemporaryDirectory() as temporary:
            checkout, artifacts = self.artifacts(Path(temporary))
            output = artifacts / "out.spdx.json"
            arguments = ["generate", "--rpm-list", str(artifacts / sbom.RPM_INVENTORY),
                         "--flatpaks", str(artifacts / sbom.FLATPAK_INVENTORY),
                         "--provenance", str(artifacts / "build-provenance.json"),
                         "--inventory", str(checkout / "inventory/group_vars/all.yml"),
                         "--apps-defaults", str(checkout / "roles/apps/defaults/main.yml"),
                         "--version-file", str(checkout / "VERSION"), "--iso", str(artifacts / ISO),
                         "--desktop-rpm", str(artifacts / DESKTOP), "--output", str(output)]
            with open(os.devnull, "w") as quiet, mock.patch("sys.stdout", quiet):
                self.assertEqual(sbom.main(arguments), 0)
                first = output.read_bytes()
                self.assertEqual(sbom.main(arguments), 0)
                self.assertEqual(output.read_bytes(), first)
                sidecar = artifacts / (ISO + ".sha256")
                sidecar.write_text(f"{sbom.sha256_file(artifacts / ISO)}  {ISO}\n")
                self.assertEqual(sbom.main(["verify", str(output), "--iso-checksum", str(sidecar)]), 0)
                sidecar.write_text(f"{'0' * 64}  {ISO}\n")
                with mock.patch("sys.stderr", quiet):
                    self.assertEqual(sbom.main(["verify", str(output), "--iso-checksum", str(sidecar)]), 1)
                    output.write_text("{}")
                    self.assertEqual(sbom.main(["verify", str(output)]), 1)

    def test_oversized_documents_are_rejected_before_attestation(self):
        with mock.patch.object(sbom, "SIZE_LIMIT", 1024), self.assertRaisesRegex(ValueError, "16 MiB"):
            sbom.serialize(document())


class PipelineWiring(unittest.TestCase):
    def test_compose_captures_and_host_build_generates_the_sbom(self):
        compose = (ROOT / "image/compose").read_text()
        self.assertIn("capture_inventories(creator._instroot, Path(\"/home/builder/artifacts\"))", compose)
        self.assertLess(compose.index("capture_inventories(creator._instroot"), compose.index("creator.unmount()"))
        build = (ROOT / "image/build").read_text()
        self.assertIn("write_build_sbom(staging", build)
        # Generated before the delivered SHA256SUMS, so the checksum covers it.
        self.assertLess(build.index("write_build_sbom(staging"), build.index('(Path(staging) / "SHA256SUMS")'))
        self.assertIn("'*.spdx.json'", (ROOT / "image/release-gate").read_text())

    def test_release_workflow_publishes_and_attests_the_sbom(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())
        steps = {step.get("id"): step for step in workflow["jobs"]["publish"]["steps"] if step.get("id")}
        pinned = "actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6"
        self.assertIn("python3 image/sbom.py verify", steps["sbom"]["run"])
        provenance = steps["attest"]
        self.assertEqual(provenance["uses"], pinned)
        self.assertEqual([line.strip() for line in provenance["with"]["subject-path"].splitlines() if line.strip()],
                         ["dist/cybexos-*.tar.zst", "${{ steps.sbom.outputs.path }}"])
        attestation = steps["attest-sbom"]
        self.assertEqual(attestation["uses"], pinned)
        self.assertEqual(attestation["with"], {"subject-checksums": "${{ steps.sbom.outputs.iso-checksum }}",
                                               "sbom-path": "${{ steps.sbom.outputs.path }}"})
        package = next(step for step in workflow["jobs"]["publish"]["steps"]
                       if step.get("name", "").startswith("Package the provenance bundle"))
        self.assertIn('"dist/cybexos-$version.tar.zst" "$SBOM_PATH"', package["run"])
        self.assertIn("https://spdx.dev/Document/v2.3", package["run"])
        publish = next(step for step in workflow["jobs"]["publish"]["steps"]
                       if step.get("name") == "Publish the completed release")
        self.assertIn("dist/*.iso.sbom.sigstore.jsonl", publish["run"])
        self.assertIn("dist/desktop-release/assets/*", publish["run"])


if __name__ == "__main__":
    unittest.main()
