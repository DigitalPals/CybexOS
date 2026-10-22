"""SPDX 2.3 software bill of materials for the CybexOS live ISO payload.

The image compose records raw inventories of the finished image root: every
installed RPM and Flatpak ref. This module combines them with the
checksum-pinned downloads in the inventory and the build provenance into one
deterministic SPDX JSON document. It uses only the standard library; reading
the Ansible inventory additionally needs PyYAML, which every builder and
release host already installs for the rest of the image tooling.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import quote, urlsplit
import uuid

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "DigitalPals/CybexOS"
SUPPLIER = "Organization: DigitalPals"
ROOT_LICENSE = "MIT"
ROOT_ID = "SPDXRef-CybexOS"
DOCUMENT_ID = "SPDXRef-DOCUMENT"
DESKTOP_PACKAGE = "cybexos-desktop"
OFFLINE_PACKAGE = "cybexos-offline-apps"
# GitHub's SBOM attestation rejects predicates above 16 MiB; fail at build time.
SIZE_LIMIT = 16 * 1024 * 1024

# Raw inventories written beside the build artifacts by image/compose.
RPM_INVENTORY = "rpm-inventory.tsv"
FLATPAK_INVENTORY = "flatpak-inventory.tsv"
RPM_FIELDS = ("name", "epoch", "version", "release", "arch", "license", "sourcerpm",
              "vendor", "packager", "url")
# One package per line, tab-separated in RPM_FIELDS order. rpm prints "(none)"
# for an absent tag; the parser treats it as an empty value.
RPM_QUERYFORMAT = ("%{NAME}\t%{EPOCH}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{LICENSE}\t"
                   "%{SOURCERPM}\t%{VENDOR}\t%{PACKAGER}\t%{URL}\n")
FLATPAK_COLUMNS = "application,arch,branch,origin,version"
FLATPAK_FIELDS = ("kind", "application", "arch", "branch", "origin", "commit", "version")

# Copies of URLs that live in role scripts rather than the inventory; the
# tests keep them equal to the installers that actually download them.
OMAWRITE_REPOSITORY = "omacom/omawrite"
LAZYVIM_STARTER = "https://github.com/LazyVim/starter.git"

# purl namespaces for known RPM vendors; the order matters (Copr before Fedora).
RPM_NAMESPACES = (
    (r"fedora copr", "copr"),
    (r"^fedora( project)?$", "fedora"),
    (r"rpm ?fusion", "rpmfusion"),
    (r"brave", "brave"),
    (r"1password|agilebits", "1password"),
    (r"openai", "openai"),
    (r"tailscale", "tailscale"),
    (r"cybexos|digitalpals", "cybexos"),
)

NAME = re.compile(r"[A-Za-z0-9_+][A-Za-z0-9._+-]*")
EVR_PART = re.compile(r"[A-Za-z0-9._+~^]+")
FLATPAK_ID = re.compile(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+")
FLATPAK_PART = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._-]*")
COMMIT = re.compile(r"[0-9a-f]{64}")
SHA256 = re.compile(r"[0-9a-f]{64}")
REVISION = re.compile(r"[0-9a-f]{40,64}")
SPDX_ID = re.compile(r"SPDXRef-[A-Za-z0-9.-]+")
LICENSE_REF = re.compile(r"LicenseRef-[A-Za-z0-9.-]+")
LICENSE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]*\+?")
# Callaway-era Fedora names and vendor words are syntactically plausible but
# are not SPDX identifiers. Such tags fall back to a LicenseRef.
NOT_SPDX = re.compile(r"(?i)(?:a|l)?gplv\d.*|mplv\d.*|asl|bsd|gpl|lgpl|proprietary|commercial|"
                      r"freeware|freely|redistributable|distributable|unknown|other|restricted|"
                      r"shareware|copyright|public|domain")
FEDORA_LICENSE_DATA = "https://gitlab.com/fedora/legal/fedora-license-data"


def absent(value):
    value = value.strip()
    return "" if value in ("", "(none)") else value


def sha256_file(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def checksum(value):
    value = str(value).lower().removeprefix("sha256:")
    if not SHA256.fullmatch(value):
        raise ValueError(f"Expected a SHA-256 digest: {value!r}")
    return value


def spdx_text(value):
    """Collapse whitespace so free-form vendor strings stay single-line."""
    return " ".join(str(value).split())


# ── Raw inventories ───────────────────────────────────────────────────────

def parse_rpm_inventory(text):
    """Parse RPM_QUERYFORMAT output. Imported gpg-pubkey entries are not packages."""
    packages = []
    for number, line in enumerate(text.split("\n"), 1):
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) != len(RPM_FIELDS):
            raise ValueError(f"RPM inventory line {number}: expected {len(RPM_FIELDS)} tab-separated fields")
        record = {key: absent(value) for key, value in zip(RPM_FIELDS, fields)}
        if record["name"] == "gpg-pubkey":
            continue
        if not NAME.fullmatch(record["name"]):
            raise ValueError(f"RPM inventory line {number}: invalid package name")
        if any(not EVR_PART.fullmatch(record[key]) for key in ("version", "release", "arch")):
            raise ValueError(f"RPM inventory line {number}: invalid version, release or architecture")
        if record["epoch"] and not record["epoch"].isdigit():
            raise ValueError(f"RPM inventory line {number}: invalid epoch")
        packages.append(record)
    if not packages:
        raise ValueError("RPM inventory is empty")
    return packages


def parse_flatpak_inventory(text):
    refs = []
    for number, line in enumerate(text.split("\n"), 1):
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) != len(FLATPAK_FIELDS):
            raise ValueError(f"Flatpak inventory line {number}: expected {len(FLATPAK_FIELDS)} tab-separated fields")
        record = {key: value.strip() for key, value in zip(FLATPAK_FIELDS, fields)}
        if (record["kind"] not in ("app", "runtime") or not FLATPAK_ID.fullmatch(record["application"])
                or not FLATPAK_PART.fullmatch(record["arch"]) or not FLATPAK_PART.fullmatch(record["branch"])
                or not COMMIT.fullmatch(record["commit"])
                or (record["origin"] and not FLATPAK_PART.fullmatch(record["origin"]))):
            raise ValueError(f"Flatpak inventory line {number}: invalid ref, origin or commit")
        refs.append(record)
    return refs


def active_commit(root, kind, application, arch, branch):
    """Read the full deployed commit; `flatpak list` truncates it to 12 digits."""
    if not FLATPAK_ID.fullmatch(application) or not all(
            FLATPAK_PART.fullmatch(part) and part != ".." for part in (arch, branch)):
        raise ValueError(f"Unsafe Flatpak ref: {kind}/{application}/{arch}/{branch}")
    link = Path(root) / "var/lib/flatpak" / kind / application / arch / branch / "active"
    commit = os.readlink(link) if link.is_symlink() else ""
    if not COMMIT.fullmatch(commit):
        raise ValueError(f"No deployed commit for {kind}/{application}/{arch}/{branch}")
    return commit


def capture_inventories(root, directory, run=subprocess.run):
    """Record the composed image root in the formats parsed above."""
    root, directory = Path(root), Path(directory)
    rpms = run(["rpm", "--root", str(root), "-qa", "--queryformat", RPM_QUERYFORMAT],
               check=True, capture_output=True, text=True).stdout
    lines = sorted(line for line in rpms.split("\n") if line.strip())
    rpm_text = "".join(line + "\n" for line in lines)
    parse_rpm_inventory(rpm_text)  # Fail the build now rather than at release time.
    rows = []
    for kind in ("app", "runtime"):
        listing = run(["chroot", str(root), "flatpak", "list", "--system", "--" + kind,
                       "--columns=" + FLATPAK_COLUMNS], check=True, capture_output=True, text=True,
                      env={**os.environ, "LC_ALL": "C"}).stdout
        lines = [line for line in listing.split("\n") if line.strip()]
        # Terminal output starts with a title row; piped output normally has none.
        if lines and not FLATPAK_ID.fullmatch(lines[0].split("\t")[0].strip()):
            lines.pop(0)
        for line in lines:
            fields = [field.strip() for field in line.split("\t")]
            # Non-terminal output is tab-separated; an empty version may be dropped.
            if not 4 <= len(fields) <= 5:
                raise ValueError(f"Unexpected flatpak list output: {line!r}")
            application, arch, branch, origin, version = fields + [""] * (5 - len(fields))
            commit = active_commit(root, kind, application, arch, branch)
            rows.append("\t".join((kind, application, arch, branch, origin, commit, version)))
    flatpak_text = "".join(row + "\n" for row in sorted(rows))
    parse_flatpak_inventory(flatpak_text)
    (directory / RPM_INVENTORY).write_text(rpm_text)
    (directory / FLATPAK_INVENTORY).write_text(flatpak_text)
    return directory / RPM_INVENTORY, directory / FLATPAK_INVENTORY


# ── Licenses and identifiers ──────────────────────────────────────────────

def _license_tokens(expression):
    return re.findall(r"\(|\)|[^\s()]+", expression)


def valid_license_expression(expression):
    """Loose SPDX 2.3 grammar check: listed-looking ids, LicenseRefs, AND/OR/WITH."""
    tokens = _license_tokens(expression)
    position = 0

    def peek():
        return tokens[position] if position < len(tokens) else None

    def identifier(token):
        if token is None or token in ("AND", "OR", "WITH", "(", ")"):
            return False
        if token.startswith(("LicenseRef-", "DocumentRef-")):
            # A LicenseRef cannot take "+"; external documents are not declared here.
            return bool(LICENSE_REF.fullmatch(token))
        return bool(LICENSE_ID.fullmatch(token)) and not NOT_SPDX.fullmatch(token.rstrip("+"))

    def factor():
        nonlocal position
        token = peek()
        if token == "(":
            position += 1
            if not compound() or peek() != ")":
                return False
            position += 1
            return True
        if not identifier(token):
            return False
        position += 1
        if peek() == "WITH":
            position += 1
            exception = peek()
            if not identifier(exception) or exception.startswith("LicenseRef-") or exception.endswith("+"):
                return False
            position += 1
        return True

    def compound():
        nonlocal position
        if not factor():
            return False
        while peek() in ("AND", "OR"):
            position += 1
            if not factor():
                return False
        return True

    return bool(tokens) and compound() and position == len(tokens)


def license_ref_id(raw):
    slug = re.sub(r"[^A-Za-z0-9.]+", "-", raw).strip("-.")[:48].strip("-.") or "unknown"
    return f"LicenseRef-rpm-{slug}-{hashlib.sha256(raw.encode()).hexdigest()[:8]}"


def declared_license(raw, extracted):
    """Return an SPDX expression; record any LicenseRef text in `extracted`."""
    raw = spdx_text(raw)
    if raw in ("", "(none)"):
        return "NOASSERTION"
    if raw in ("NOASSERTION", "NONE"):
        return raw
    if valid_license_expression(raw):
        expression = " ".join(_license_tokens(raw)).replace("( ", "(").replace(" )", ")")
        for reference in sorted(set(LICENSE_REF.findall(expression))):
            entry = {"licenseId": reference, "name": reference,
                     "extractedText": "The package's License tag references this identifier; "
                                      "its text is in the package's license files."}
            if reference.startswith(("LicenseRef-Fedora-", "LicenseRef-Callaway-")):
                entry["seeAlsos"] = [FEDORA_LICENSE_DATA]
            extracted.setdefault(reference, entry)
        return expression
    reference = license_ref_id(raw)
    extracted.setdefault(reference, {
        "licenseId": reference, "name": raw, "extractedText": raw,
        "comment": "Verbatim RPM License tag that is not a valid SPDX license expression."})
    return reference


def spdx_id(prefix, *parts):
    return re.sub(r"[^A-Za-z0-9.-]+", "-", "-".join(("SPDXRef", prefix, *parts))).rstrip("-")


def purl(kind, namespace, name, version=None, qualifiers=None):
    """Canonical-enough package URL: lowercase namespace, sorted encoded qualifiers."""
    text = "pkg:" + kind + "/"
    if namespace:
        text += "/".join(quote(segment, safe="") for segment in namespace.lower().split("/")) + "/"
    text += quote(name.lower() if kind == "github" else name, safe="")
    if version:
        text += "@" + quote(version, safe="")
    pairs = sorted((key, str(value)) for key, value in (qualifiers or {}).items() if value)
    if pairs:
        text += "?" + "&".join(f"{key}={quote(value, safe=':/')}" for key, value in pairs)
    return text


def purl_reference(locator):
    return {"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": locator}


def http_url(value):
    parts = urlsplit(value or "")
    if parts.scheme in ("http", "https") and parts.netloc and not any(char.isspace() for char in value):
        return value
    return None


def rpm_namespace(record, owners):
    vendor = record["vendor"].lower()
    for pattern, namespace in RPM_NAMESPACES:
        if vendor and re.search(pattern, vendor):
            return namespace
    if record["name"] == DESKTOP_PACKAGE:
        return "cybexos"
    if not vendor:
        # Inventory-pinned GitHub RPMs carry no Vendor tag; their owner is the vendor.
        return owners.get(record["name"])
    return re.sub(r"[^a-z0-9.]+", "-", vendor).strip("-.") or None


def supplier(record):
    for key in ("vendor", "packager"):
        value = spdx_text(record[key])
        if value:
            match = re.fullmatch(r"(.*?)\s*<([^<>\s]+@[^<>\s]+)>", value)
            return "Organization: " + (f"{match[1]} ({match[2]})" if match and match[1] else value)
    return "NOASSERTION"


# ── Components ────────────────────────────────────────────────────────────

def rpm_package(record, fedora_release, owners, extracted):
    evr = f"{record['version']}-{record['release']}"
    version = f"{record['epoch']}:{evr}" if record["epoch"] else evr
    package = {
        "SPDXID": spdx_id("RPM", record["name"], version.replace(":", "-"), record["arch"]),
        "name": record["name"],
        "versionInfo": version,
        "supplier": supplier(record),
        # The URL tag is the upstream project, not where this binary came from.
        "downloadLocation": "NOASSERTION",
        "filesAnalyzed": False,
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": declared_license(record["license"], extracted),
        "copyrightText": "NOASSERTION",
        "externalRefs": [purl_reference(purl(
            "rpm", rpm_namespace(record, owners), record["name"], evr,
            {"arch": record["arch"], "epoch": record["epoch"], "distro": f"fedora-{fedora_release}"}))],
    }
    if record["sourcerpm"]:
        package["sourceInfo"] = f"built from source RPM {record['sourcerpm']}"
    homepage = http_url(record["url"])
    if homepage:
        package["homepage"] = homepage
    return package


def flatpak_package(record):
    ref = "/".join((record["kind"], record["application"], record["arch"], record["branch"]))
    package = {
        "SPDXID": spdx_id("Flatpak", record["kind"], record["application"], record["arch"], record["branch"]),
        "name": record["application"],
        "versionInfo": record["version"] or record["branch"],
        "supplier": "Organization: Flathub" if record["origin"] == "flathub" else "NOASSERTION",
        "downloadLocation": "NOASSERTION",
        "filesAnalyzed": False,
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": "NOASSERTION",
        "copyrightText": "NOASSERTION",
        "primaryPackagePurpose": "APPLICATION" if record["kind"] == "app" else "FRAMEWORK",
        "sourceInfo": f"Flatpak {ref} at OSTree commit {record['commit']} from remote "
                      f"{record['origin'] or 'unknown'}",
        # There is no purl type for Flatpak; the ref and commit identify it exactly.
        "externalRefs": [
            {"referenceCategory": "OTHER", "referenceType": "flatpak-ref", "referenceLocator": ref},
            {"referenceCategory": "OTHER", "referenceType": "ostree-commit", "referenceLocator": record["commit"]},
        ],
    }
    return package


def literal_asset(pattern):
    """Return the filename an anchored asset regex can match, if it is literal."""
    body = str(pattern).removeprefix("^").removesuffix("$").replace("[.]", ".").replace(r"\.", ".")
    return body if re.fullmatch(r"[A-Za-z0-9_.+-]+", body) else None


def feature_enabled(value, features):
    if isinstance(value, bool):
        return value
    match = re.fullmatch(r"\{\{\s*features\.([A-Za-z0-9_]+)(?:\s*\|\s*bool)?\s*\}\}", str(value).strip())
    if match:
        value = features.get(match[1], False)
        if isinstance(value, bool):
            return value
    text = str(value).strip().lower()
    if text in ("true", "yes", "on", "1", "false", "no", "off", "0"):
        return text in ("true", "yes", "on", "1")
    # Fail closed: an unknown condition could add or hide a payload component.
    raise ValueError(f"Unsupported enable condition for the SBOM: {value!r}")


def download_assets(manifest):
    """Map pinned digests to the exact upstream filenames the builder downloaded."""
    if not manifest:
        return {}
    manifest = Path(manifest)
    if not manifest.is_file():
        return {}
    assets = {}
    for entry in json.loads(manifest.read_text()).get("entries", []):
        path = str(entry.get("path", ""))
        name = path.rsplit("/", 1)[-1]
        if path.startswith("/var/cache/cybexos-upstream/") and re.fullmatch(r"[A-Za-z0-9_.+-]+", name):
            assets[checksum(entry.get("sha256", ""))] = name
    return assets


def _github(url):
    parts = urlsplit(url)
    path = parts.path.removesuffix(".git").strip("/").split("/")
    if parts.netloc == "github.com" and len(path) == 2:
        return path
    return None


def pinned_inputs(inventory, apps_defaults=None, assets=None):
    """Checksum- or commit-pinned downloads that the image payload contains.

    Returns (package, placement) pairs. Placement "desktop" means the bytes
    are inside the desktop RPM payload (/opt, /usr/local and the user seed),
    "rpm" an inventory-pinned RPM installed as its own image package, and
    "root" other files of the image. XPS camera sources, Distrobox images and
    the source-build container are not part of the ISO payload: they are
    fetched on matching hardware or used only as build environments.
    """
    features, assets = inventory.get("features", {}), assets or {}
    pins = []

    def add(name, version, location, digest=None, reference=None, purpose="FILE", placement="desktop",
            filename=None):
        package = {
            "SPDXID": spdx_id("Download", name, str(version)),
            "name": name,
            "versionInfo": str(version),
            "supplier": "NOASSERTION",
            "downloadLocation": location,
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "primaryPackagePurpose": purpose,
        }
        if digest:
            package["checksums"] = [{"algorithm": "SHA256", "checksumValue": checksum(digest)}]
        if filename:
            package["packageFileName"] = filename
        if reference:
            package["externalRefs"] = [purl_reference(reference)]
        pins.append((package, placement))

    purposes = {"archive": "ARCHIVE", "binary": "APPLICATION", "rpm": "INSTALL", "font": "ARCHIVE"}
    for app in inventory.get("github_release_apps", []) + inventory.get("nerd_font_apps", []):
        if not feature_enabled(app.get("enabled", True), features):
            continue
        owner, name = app["repo"].split("/")
        tag, digest = str(app["version"]), checksum(app["checksum"])
        asset = assets.get(digest) or literal_asset(app["asset_regex"])
        base = f"https://github.com/{app['repo']}/releases"
        location = (f"{base}/download/{quote(tag, safe='')}/{quote(asset)}" if asset
                    else f"{base}/tag/{quote(tag, safe='')}")
        add(app["name"], tag, location, digest, purl("github", owner, name, tag),
            purposes.get(app["kind"], "OTHER"), "rpm" if app["kind"] == "rpm" else "desktop", asset)
    for font in inventory.get("pinned_font_archives", []):
        if feature_enabled(font.get("enabled", True), features):
            add(font["name"], font["version"], font["url"], font["checksum"],
                purl("generic", None, font["name"], str(font["version"]),
                     {"checksum": "sha256:" + checksum(font["checksum"]), "download_url": font["url"]}),
                "ARCHIVE")
    for font in inventory.get("pinned_font_files", []):
        add(font["name"], font["version"], font["url"], font["checksum"],
            purl("generic", None, font["name"], str(font["version"]),
                 {"checksum": "sha256:" + checksum(font["checksum"]), "download_url": font["url"]}),
            "FILE", filename=font.get("filename"))
    if inventory.get("omawrite_commit"):
        commit = inventory["omawrite_commit"]
        owner, name = OMAWRITE_REPOSITORY.split("/")
        add("omawrite", inventory["omawrite_version"],
            f"https://codeload.github.com/{OMAWRITE_REPOSITORY}/tar.gz/{commit}",
            inventory["omawrite_checksum"], purl("github", owner, name, commit), "SOURCE")
    if feature_enabled(features.get("source_builds", False), features):
        for app in inventory.get("source_apps", []):
            repository = _github(app["repo_url"])
            reference = (purl("github", *repository, app["commit"]) if repository else
                         purl("generic", None, app["name"], app["tag"],
                              {"vcs_url": f"git+{app['repo_url']}@{app['commit']}"}))
            add(app["name"], app["tag"], f"git+{app['repo_url']}@{app['commit']}",
                reference=reference, purpose="SOURCE")
    if inventory.get("lazyvim_starter_commit"):
        commit = inventory["lazyvim_starter_commit"]
        add("lazyvim-starter", commit, f"git+{LAZYVIM_STARTER}@{commit}",
            reference=purl("github", *_github(LAZYVIM_STARTER), commit), purpose="SOURCE")
    for key in (apps_defaults or {}).get("apps_vendor_repo_keys", []):
        if feature_enabled(key.get("enabled", True), features):
            add(key["name"] + "-repository-key", checksum(key["checksum"])[:12], key["url"], key["checksum"],
                purl("generic", None, key["name"] + "-repository-key", None,
                     {"checksum": "sha256:" + checksum(key["checksum"]), "download_url": key["url"]}),
                "FILE", "root")
    return pins


# ── Document ──────────────────────────────────────────────────────────────

def _unique(packages):
    seen = {}
    for package in packages:
        identifier = package["SPDXID"]
        if identifier in seen:
            identity = json.dumps(package, sort_keys=True).encode()
            package["SPDXID"] = f"{identifier}-{hashlib.sha256(identity).hexdigest()[:8]}"
        if package["SPDXID"] in seen:
            raise ValueError(f"Duplicate SBOM component: {identifier}")
        seen[package["SPDXID"]] = package


def created_time(provenance):
    timestamp = datetime.fromisoformat(str(provenance["utc"]).replace("Z", "+00:00"))
    if timestamp.tzinfo is None:
        raise ValueError("Build time must include its timezone")
    return timestamp.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_document(*, rpms, flatpaks, pins, provenance, version, fedora_release="44",
                   iso=None, desktop_rpm=None, offline_rpm=None, source_archive_sha256=None, owners=None,
                   source_build_provenance_sha256=None):
    """Assemble the SPDX document. File arguments are (filename, sha256) pairs."""
    revision = str(provenance.get("source_revision", ""))
    build = str(provenance.get("build_id", ""))
    if not REVISION.fullmatch(revision):
        raise ValueError("Build provenance needs the full source revision")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", build):
        raise ValueError("Build provenance needs a safe build identifier")
    if not re.fullmatch(r"[0-9A-Za-z.+~-]+", version):
        raise ValueError("Invalid CybexOS version")
    extracted = {}
    details = [f"Built from Git revision {revision}"
               + (" with uncommitted changes" if provenance.get("source_dirty") else "")]
    if provenance.get("source_content_sha256"):
        details.append(f"source content SHA-256 {checksum(provenance['source_content_sha256'])} "
                       f"over {int(provenance.get('source_file_count', 0))} files")
    if source_archive_sha256:
        details.append(f"builder source archive SHA-256 {checksum(source_archive_sha256)}")
    if source_build_provenance_sha256:
        details.append("resolved source toolchains source-build-provenance.json SHA-256 "
                       + checksum(source_build_provenance_sha256))
    details.append(f"build {build}")
    root = {
        "SPDXID": ROOT_ID,
        "name": "CybexOS",
        "versionInfo": version,
        "supplier": SUPPLIER,
        "downloadLocation": f"git+https://github.com/{REPOSITORY}.git@{revision}",
        "filesAnalyzed": False,
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": ROOT_LICENSE,
        "copyrightText": "NOASSERTION",
        "primaryPackagePurpose": "OPERATING-SYSTEM",
        "sourceInfo": "; ".join(details),
        "externalRefs": [purl_reference(purl("github", *REPOSITORY.split("/"), revision))],
    }
    if iso:
        root["packageFileName"] = iso[0]
        root["checksums"] = [{"algorithm": "SHA256", "checksumValue": checksum(iso[1])}]
        root["comment"] = "The live ISO built from this source; its components are listed below."

    components = []  # (package, inside the desktop RPM payload?)
    installed = {}
    desktop = None
    offline = None
    artifacts = {DESKTOP_PACKAGE: desktop_rpm, OFFLINE_PACKAGE: offline_rpm}
    for record in sorted(rpms, key=lambda item: tuple(item[key] for key in RPM_FIELDS)):
        package = rpm_package(record, fedora_release, owners or {}, extracted)
        if record["name"] in artifacts:
            name = record["name"]
            if name in installed:
                raise ValueError(f"The image contains more than one {name} RPM")
            if name == DESKTOP_PACKAGE:
                desktop = package
            else:
                offline = package
            artifact = artifacts[name]
            if artifact:
                expected = f"{record['name']}-{record['version']}-{record['release']}.{record['arch']}.rpm"
                if artifact[0] != expected:
                    raise ValueError(f"RPM artifact {artifact[0]} is not the installed {expected}")
                package["packageFileName"] = artifact[0]
                package["checksums"] = [{"algorithm": "SHA256", "checksumValue": checksum(artifact[1])}]
                package["comment"] = ("SHA-256 of the unsigned build output; release signing adds a "
                                      "signature header (release.json unsigned_input_sha256).")
        installed.setdefault(record["name"], []).append(package)
        components.append((package, False))
    if desktop_rpm and desktop is None:
        raise ValueError("The image root does not contain the desktop RPM")
    if offline_rpm and offline is None:
        raise ValueError("The image root does not contain the offline applications RPM")
    for record in sorted(flatpaks, key=lambda item: tuple(item[key] for key in FLATPAK_FIELDS)):
        components.append((flatpak_package(record), False))
    for pin, placement in sorted(pins, key=lambda item: item[0]["SPDXID"]):
        matches = installed.get(pin["name"], [])
        if placement == "rpm" and len(matches) == 1:
            # The installed package is exactly this checksum-pinned download.
            matches[0].update({key: pin[key] for key in ("downloadLocation", "checksums", "packageFileName")
                               if key in pin})
            matches[0]["externalRefs"] = matches[0]["externalRefs"] + pin.get("externalRefs", [])
            matches[0]["comment"] = "Installed from the inventory-pinned upstream release asset."
            continue
        components.append((pin, placement == "desktop"))
    _unique([root] + [package for package, _ in components])

    relationships = []
    for package, bundled in components:
        container = offline or desktop
        parent = container["SPDXID"] if bundled and container is not None else ROOT_ID
        relationships.append({"spdxElementId": parent, "relationshipType": "CONTAINS",
                              "relatedSpdxElement": package["SPDXID"]})
    relationships.sort(key=lambda item: (item["spdxElementId"], item["relatedSpdxElement"]))
    packages = [root] + sorted((package for package, _ in components), key=lambda item: item["SPDXID"])
    name = f"CybexOS-Live-{fedora_release}-{build}"
    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": DOCUMENT_ID,
        "name": name,
        "documentNamespace": (f"https://github.com/{REPOSITORY}/spdx/{name}-"
                              f"{uuid.uuid5(uuid.NAMESPACE_URL, f'{revision}/{name}')}"),
        "creationInfo": {"created": created_time(provenance),
                         "creators": [f"Tool: cybexos-sbom-{version}"]},
        "comment": ("Installed RPMs and Flatpak refs of the CybexOS live image, and the "
                    "checksum-pinned downloads it bundles."),
        "packages": packages,
        "relationships": [{"spdxElementId": DOCUMENT_ID, "relationshipType": "DESCRIBES",
                           "relatedSpdxElement": ROOT_ID}] + relationships,
    }
    if extracted:
        document["hasExtractedLicensingInfos"] = [extracted[key] for key in sorted(extracted)]
    return verify_document(document)


def serialize(document):
    data = (json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()
    if len(data) > SIZE_LIMIT:
        raise ValueError("SBOM exceeds the 16 MiB attestation limit")
    return data


def verify_document(document):
    """Structural SPDX 2.3 checks that release tooling relies on."""
    if not isinstance(document, dict):
        raise ValueError("SBOM must be a JSON object")
    expected = {"spdxVersion": "SPDX-2.3", "dataLicense": "CC0-1.0", "SPDXID": DOCUMENT_ID}
    if any(document.get(key) != value for key, value in expected.items()):
        raise ValueError("SBOM must be an SPDX 2.3 document with CC0-1.0 data license")
    namespace = urlsplit(str(document.get("documentNamespace", "")))
    if not document.get("name") or namespace.scheme != "https" or not namespace.netloc or namespace.fragment:
        raise ValueError("SBOM needs a name and a unique HTTPS document namespace")
    creation = document.get("creationInfo") or {}
    if (not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", str(creation.get("created", "")))
            or not creation.get("creators")
            or not all(re.match(r"(Tool|Organization|Person): \S", str(item)) for item in creation["creators"])):
        raise ValueError("SBOM creation information is incomplete")
    packages = document.get("packages")
    if not isinstance(packages, list) or not packages:
        raise ValueError("SBOM lists no packages")
    identifiers = set()
    for package in packages:
        identifier = package.get("SPDXID", "")
        if not SPDX_ID.fullmatch(identifier) or identifier in identifiers:
            raise ValueError(f"Invalid or duplicate SPDX identifier: {identifier!r}")
        identifiers.add(identifier)
        if not package.get("name") or not package.get("downloadLocation"):
            raise ValueError(f"{identifier} lacks a name or download location")
        if package.get("filesAnalyzed") is not False and "packageVerificationCode" not in package:
            raise ValueError(f"{identifier} must declare filesAnalyzed false")
        for item in package.get("checksums", []):
            if item.get("algorithm") != "SHA256" or not SHA256.fullmatch(str(item.get("checksumValue", ""))):
                raise ValueError(f"{identifier} has an invalid checksum")
    defined = {item.get("licenseId") for item in document.get("hasExtractedLicensingInfos", [])
               if item.get("extractedText")}
    for package in packages:
        for key in ("licenseDeclared", "licenseConcluded"):
            missing = set(LICENSE_REF.findall(str(package.get(key, "")))) - defined
            if missing:
                raise ValueError(f"{package['SPDXID']} uses undefined {', '.join(sorted(missing))}")
    relationships = document.get("relationships")
    if not isinstance(relationships, list):
        raise ValueError("SBOM lacks relationships")
    described, contained, seen = [], set(), set()
    for item in relationships:
        source, kind, target = (item.get(key) for key in ("spdxElementId", "relationshipType", "relatedSpdxElement"))
        if source not in identifiers | {DOCUMENT_ID} or target not in identifiers:
            raise ValueError(f"Relationship references an unknown element: {source} {kind} {target}")
        if (source, kind, target) in seen:
            raise ValueError("Repeated SBOM relationship")
        seen.add((source, kind, target))
        if kind == "DESCRIBES" and source == DOCUMENT_ID:
            described.append(target)
        elif kind == "CONTAINS":
            contained.add(target)
    if len(described) != 1:
        raise ValueError("SBOM must describe exactly one root package")
    orphans = identifiers - contained - set(described)
    if orphans:
        raise ValueError(f"SBOM components are not related to the root: {', '.join(sorted(orphans)[:5])}")
    return document


def described_package(document):
    root = next(item["relatedSpdxElement"] for item in document["relationships"]
                if item["spdxElementId"] == DOCUMENT_ID and item["relationshipType"] == "DESCRIBES")
    return next(package for package in document["packages"] if package["SPDXID"] == root)


def file_checksum(package):
    return next((item["checksumValue"] for item in package.get("checksums", [])
                 if item.get("algorithm") == "SHA256"), None)


def verify_release_sbom(path, iso_name, iso_sha256, rpm_sha256s=()):
    """Bind an SBOM to the exact ISO and every unsigned release RPM."""
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > SIZE_LIMIT:
        raise ValueError("Release SBOM must be a regular file below 16 MiB")
    document = verify_document(json.loads(path.read_text()))
    root = described_package(document)
    if root.get("packageFileName") != iso_name or file_checksum(root) != iso_sha256:
        raise ValueError("Release SBOM does not describe the exact ISO")
    if rpm_sha256s:
        expected = rpm_sha256s if isinstance(rpm_sha256s, dict) else {DESKTOP_PACKAGE: set(rpm_sha256s)}
        if any(package['name'] == OFFLINE_PACKAGE for package in document['packages']) and OFFLINE_PACKAGE not in expected:
            raise ValueError('Release SBOM requires the exact candidate cybexos-offline-apps RPM')
        for name, digests in expected.items():
            packages = [package for package in document["packages"] if package["name"] == name]
            digests = {digests} if isinstance(digests, str) else set(digests)
            if len(packages) != 1 or file_checksum(packages[0]) not in digests:
                label = 'desktop' if name == DESKTOP_PACKAGE else name
                raise ValueError(f"Release SBOM does not identify the exact candidate {label} RPM")
    return document


# ── Inputs and command line ───────────────────────────────────────────────

def load_yaml(path):
    try:
        import yaml
    except ImportError as error:
        raise RuntimeError("Reading the inventory needs PyYAML (python3-pyyaml or python3-yaml)") from error
    return yaml.safe_load(Path(path).read_text()) or {}


def generate(*, rpm_list, flatpaks, provenance, output, inventory=None, apps_defaults=None,
             version_file=None, iso=None, desktop_rpm=None, offline_rpm=None, source_archive_sha256=None, downloads=None,
             source_build_provenance_sha256=None):
    """Write the SBOM atomically. `iso` and `desktop_rpm` are (filename, sha256)."""
    inventory = load_yaml(inventory or ROOT / "inventory/group_vars/all.yml")
    defaults = load_yaml(apps_defaults or ROOT / "roles/apps/defaults/main.yml")
    owners = {app["name"]: app["repo"].split("/")[0]
              for app in inventory.get("github_release_apps", []) if app.get("kind") == "rpm"}
    document = build_document(
        rpms=parse_rpm_inventory(Path(rpm_list).read_text()),
        flatpaks=parse_flatpak_inventory(Path(flatpaks).read_text()),
        pins=pinned_inputs(inventory, defaults, download_assets(downloads)),
        provenance=json.loads(Path(provenance).read_text()),
        version=Path(version_file or ROOT / "VERSION").read_text().strip(),
        fedora_release=str(inventory.get("fedora_release", "44")),
        iso=iso, desktop_rpm=desktop_rpm, offline_rpm=offline_rpm,
        source_archive_sha256=source_archive_sha256, owners=owners,
        source_build_provenance_sha256=source_build_provenance_sha256)
    output = Path(output)
    data = serialize(document)
    temporary = output.with_name(f".{output.name}.tmp")
    try:
        temporary.write_bytes(data)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    return output


def sbom_name(iso_name):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.iso", iso_name):
        raise ValueError("ISO filename must be ASCII without spaces")
    return iso_name.removesuffix(".iso") + ".spdx.json"


def write_build_sbom(artifacts, iso_name, checksums=None, downloads=None, checkout=ROOT):
    """Generate <ISO stem>.spdx.json inside a verified artifact staging directory."""
    artifacts, checksums = Path(artifacts), dict(checksums or {})

    def digest(name):
        return checksums.get(name) or sha256_file(artifacts / name)

    rpms = sorted(path.name for path in artifacts.glob(DESKTOP_PACKAGE + "-*.rpm"))
    if len(rpms) != 1:
        raise ValueError("Artifacts must contain exactly one desktop RPM")
    offline = sorted(path.name for path in artifacts.glob(OFFLINE_PACKAGE + "-*.rpm"))
    if len(offline) > 1:
        raise ValueError("Artifacts contain more than one offline applications RPM")
    installed = parse_rpm_inventory((artifacts / RPM_INVENTORY).read_text())
    if any(record['name'] == OFFLINE_PACKAGE for record in installed) and not offline:
        raise ValueError("Artifacts must contain the installed offline applications RPM")
    archive = artifacts / "source.tar.gz"
    return generate(
        rpm_list=artifacts / RPM_INVENTORY, flatpaks=artifacts / FLATPAK_INVENTORY,
        provenance=artifacts / "build-provenance.json", output=artifacts / sbom_name(iso_name),
        inventory=checkout / "inventory/group_vars/all.yml",
        apps_defaults=checkout / "roles/apps/defaults/main.yml", version_file=checkout / "VERSION",
        iso=(iso_name, digest(iso_name)), desktop_rpm=(rpms[0], digest(rpms[0])),
        offline_rpm=(offline[0], digest(offline[0])) if offline else None,
        source_archive_sha256=digest(archive.name) if archive.is_file() else None, downloads=downloads,
        source_build_provenance_sha256=digest("source-build-provenance.json"))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser("generate", help="Write an SPDX 2.3 JSON SBOM from raw build inventories")
    make.add_argument("--rpm-list", type=Path, required=True, help=f"{RPM_INVENTORY} (rpm --queryformat output)")
    make.add_argument("--flatpaks", type=Path, required=True, help=FLATPAK_INVENTORY)
    make.add_argument("--provenance", type=Path, required=True, help="build-provenance.json")
    make.add_argument("--output", type=Path, required=True)
    make.add_argument("--inventory", type=Path, default=ROOT / "inventory/group_vars/all.yml")
    make.add_argument("--apps-defaults", type=Path, default=ROOT / "roles/apps/defaults/main.yml")
    make.add_argument("--version-file", type=Path, default=ROOT / "VERSION")
    make.add_argument("--iso", type=Path, help="Built ISO; recorded with its SHA-256")
    make.add_argument("--iso-name", help="Delivered ISO filename when it differs from --iso")
    make.add_argument("--desktop-rpm", type=Path, help="Unsigned cybexos-desktop RPM artifact")
    make.add_argument("--offline-rpm", type=Path, help="Unsigned cybexos-offline-apps RPM artifact")
    make.add_argument("--source-archive", type=Path, help="Builder source archive (source.tar.gz)")
    make.add_argument("--downloads", type=Path, help="Download cache manifest naming fetched release assets")
    check = commands.add_parser("verify", help="Check an SBOM's structure and its ISO binding")
    check.add_argument("sbom", type=Path)
    check.add_argument("--iso-checksum", type=Path, help="ISO .sha256 file the SBOM must describe")
    args = parser.parse_args(argv)
    try:
        if args.command == "verify":
            if args.iso_checksum:
                match = re.fullmatch(r"([0-9a-f]{64}) [ *]([A-Za-z0-9._-]+\.iso)\n?", args.iso_checksum.read_text())
                if not match:
                    raise ValueError("Invalid ISO checksum file")
                verify_release_sbom(args.sbom, match[2], match[1])
            else:
                verify_document(json.loads(args.sbom.read_text()))
            print(f"Valid SPDX 2.3 SBOM: {args.sbom}")
            return 0
        iso = (args.iso_name or args.iso.name, sha256_file(args.iso)) if args.iso else None
        rpm = (args.desktop_rpm.name, sha256_file(args.desktop_rpm)) if args.desktop_rpm else None
        offline = (args.offline_rpm.name, sha256_file(args.offline_rpm)) if args.offline_rpm else None
        archive = sha256_file(args.source_archive) if args.source_archive else None
        print(generate(rpm_list=args.rpm_list, flatpaks=args.flatpaks, provenance=args.provenance,
                       output=args.output, inventory=args.inventory, apps_defaults=args.apps_defaults,
                       version_file=args.version_file, iso=iso, desktop_rpm=rpm, offline_rpm=offline,
                       source_archive_sha256=archive, downloads=args.downloads))
        return 0
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, json.JSONDecodeError) as error:
        print(f"sbom: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
