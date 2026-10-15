#!/usr/bin/python3
"""Hold packages to their qualified series in dnf's versionlock.toml.

The series come from `qualified_package_series` in inventory/group_vars/all.yml
(docs/dependency-policy.md). Each becomes one versionlock entry that admits
`minimum <= evr < below`, so patch releases inside the series still install
and update while the next minor or major release is held back until it has
been reviewed. The checkout installer, the image installer and upgrade
reconciliation all converge the file with this module.

CybexOS owns only the entries whose comment starts with MARKER. Every other
entry is the administrator's and is kept as written. dnf combines the entries
for one package name with OR, so an administrator who has qualified another
version can admit it with an entry of their own, without editing ours. A file
this module cannot read safely is left untouched and reported.

The image build imports this file too: image/compose fails when the resolved
packages fall outside their series (outside_series below).
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import tomllib

MARKER = "CybexOS qualified series"
COMMENT = MARKER + " (docs/dependency-policy.md); managed by CybexOS, edits are replaced"
DEFAULT_PATH = "/etc/dnf/versionlock.toml"
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")
VERSION = re.compile(r"^(?:[0-9]+:)?[A-Za-z0-9._+~^]{1,64}(?:-[A-Za-z0-9._+~^]{1,64})?$")
COMPARATORS = ("<", "<=", "=", ">=", ">", "!=")
MAX_BYTES = 1048576


class Unmanageable(ValueError):
    """The existing file cannot be rewritten without losing what it says."""


# ------------------------------------------------------------------ RPM --

def rpmvercmp(first, second):
    """RPM's version comparison (rpmvercmp.c), including ~ and ^."""
    if first == second:
        return 0
    one, two = first, second
    while one or two:
        one = re.sub(r"^[^A-Za-z0-9~^]+", "", one)
        two = re.sub(r"^[^A-Za-z0-9~^]+", "", two)
        # A tilde sorts before everything, even the end of the string.
        if one.startswith("~") or two.startswith("~"):
            if not one.startswith("~"):
                return 1
            if not two.startswith("~"):
                return -1
            one, two = one[1:], two[1:]
            continue
        # A caret sorts after the end of the string but before anything else.
        if one.startswith("^") or two.startswith("^"):
            if not one:
                return -1
            if not two:
                return 1
            if not one.startswith("^"):
                return 1
            if not two.startswith("^"):
                return -1
            one, two = one[1:], two[1:]
            continue
        if not (one and two):
            break
        numeric = one[0].isdigit()
        pattern = r"^[0-9]+" if numeric else r"^[A-Za-z]+"
        left = re.match(pattern, one)
        right = re.match(pattern, two)
        if right is None:
            # Numeric segments are newer than alphabetic ones.
            return 1 if numeric else -1
        left, right = left.group(0), right.group(0)
        one, two = one[len(left):], two[len(right):]
        if numeric:
            left, right = left.lstrip("0"), right.lstrip("0")
            if len(left) != len(right):
                return 1 if len(left) > len(right) else -1
        if left != right:
            return 1 if left > right else -1
    if not one and not two:
        return 0
    return -1 if not one else 1


def split_evr(text):
    """(epoch, version, release) with release "" when the text names none."""
    epoch, _, rest = text.rpartition(":") if ":" in text else ("0", "", text)
    version, _, release = rest.partition("-")
    return int(epoch or 0), version, release


def compare_evr(first, second):
    """libsolv's EVR order, as dnf's versionlock conditions apply it.

    A value without a release compares as an empty release, which is older
    than any real one: 0.56.2-2 is newer than 0.56.2. Release-less bounds
    therefore read naturally: >= 0.56.2 admits 0.56.2-1, and < 0.57~ excludes
    every 0.57 build, pre-releases included.
    """
    first, second = split_evr(first), split_evr(second)
    if first[0] != second[0]:
        return 1 if first[0] > second[0] else -1
    return rpmvercmp(first[1], second[1]) or rpmvercmp(first[2], second[2])


def satisfies(evr, comparator, value):
    order = compare_evr(evr, value)
    return {"<": order < 0, "<=": order <= 0, "=": order == 0,
            ">=": order >= 0, ">": order > 0, "!=": order != 0}[comparator]


# --------------------------------------------------------------- series --

def validate_series(series):
    if not isinstance(series, list):
        raise ValueError("qualified_package_series must be a list")
    names = set()
    for entry in series:
        if not isinstance(entry, dict) or set(entry) != {"name", "minimum", "below"}:
            raise ValueError("each qualified series needs exactly name, minimum and below")
        name, minimum, below = entry["name"], entry["minimum"], entry["below"]
        if not isinstance(name, str) or not NAME.fullmatch(name) or name in names:
            raise ValueError(f"invalid or repeated series package name: {name!r}")
        for value in (minimum, below):
            if not isinstance(value, str) or not VERSION.fullmatch(value):
                raise ValueError(f"invalid version bound for {name}: {value!r}")
        if compare_evr(minimum, below) >= 0:
            raise ValueError(f"the {name} series is empty: {minimum} is not below {below}")
        names.add(name)
    return series


def desired_entries(series):
    return [{"name": entry["name"], "comment": COMMENT, "conditions": [
        {"key": "evr", "comparator": ">=", "value": entry["minimum"]},
        {"key": "evr", "comparator": "<", "value": entry["below"]},
    ]} for entry in validate_series(series)]


def in_series(evr, entry):
    return satisfies(evr, ">=", entry["minimum"]) and satisfies(evr, "<", entry["below"])


def outside_series(series, installed, require=False):
    """Human-readable problems: `installed(name)` returns an EVR or None."""
    problems = []
    for entry in validate_series(series):
        evr = installed(entry["name"])
        if evr is None:
            if require:
                problems.append(f"{entry['name']} is not installed")
        elif not in_series(evr, entry):
            problems.append(f"{entry['name']} {evr} is outside its qualified series "
                            f">= {entry['minimum']}, < {entry['below']}")
    return problems


def describe(series):
    return ", ".join(f"{entry['name']} >= {entry['minimum']}, < {entry['below']}"
                     for entry in validate_series(series))


# ----------------------------------------------------------------- TOML --

def _string(value):
    escaped = []
    for character in value:
        if character in ('"', "\\"):
            escaped.append("\\" + character)
        elif ord(character) < 0x20 or ord(character) == 0x7F:
            escaped.append("\\u%04X" % ord(character))
        else:
            escaped.append(character)
    return '"' + "".join(escaped) + '"'


def _key(key):
    return key if re.fullmatch(r"[A-Za-z0-9_-]+", key) else _string(key)


def _scalar(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return _string(value)
    raise Unmanageable("the versionlock file holds a value this tool cannot preserve")


def _scalars(table):
    return [f"{_key(key)} = {_scalar(value)}" for key, value in table.items()]


def render(document):
    """TOML for the versionlock schema: scalars, packages and their conditions."""
    lines = []
    top = {key: value for key, value in document.items() if key != "packages"}
    lines += _scalars(top)
    for package in document.get("packages", []):
        lines += ["", "[[packages]]"]
        lines += _scalars({key: value for key, value in package.items() if key != "conditions"})
        for condition in package.get("conditions", []):
            lines.append("[[packages.conditions]]")
            lines += _scalars(condition)
    return "\n".join(lines) + "\n"


def _managed(package):
    return isinstance(package.get("comment"), str) and package["comment"].startswith(MARKER)


def _checked(document):
    """The parsed document, refused when rewriting it could lose data."""
    if document.get("version") != "1.0":
        raise Unmanageable("the versionlock file is not version 1.0")
    packages = document.get("packages", [])
    if not isinstance(packages, list):
        raise Unmanageable("the versionlock packages are not a list")
    for key, value in document.items():
        if key != "packages":
            _scalar(value)
    for package in packages:
        if not isinstance(package, dict):
            raise Unmanageable("a versionlock entry is not a table")
        conditions = package.get("conditions", [])
        if not isinstance(conditions, list) or not all(isinstance(item, dict) for item in conditions):
            raise Unmanageable("a versionlock entry has unreadable conditions")
        for key, value in package.items():
            if key != "conditions":
                _scalar(value)
        for condition in conditions:
            for value in condition.values():
                _scalar(value)
    return document


def converge(text, series):
    """The file's new text, or None when it already says what it should."""
    wanted = desired_entries(series)
    if text is None or not text.strip():
        document = {"version": "1.0", "packages": []}
    else:
        try:
            document = _checked(tomllib.loads(text))
        except tomllib.TOMLDecodeError as error:
            raise Unmanageable(f"the versionlock file is not valid TOML: {error}") from None
    packages = document.get("packages", [])
    kept = [package for package in packages if not _managed(package)]
    # Ours stay last, in series order, so an unchanged file is left alone.
    if packages == kept + wanted and text is not None:
        return None
    if not kept and not wanted and text is None:
        return None
    return render({**document, "packages": kept + wanted})


def read(path):
    path = Path(path)
    if path.is_symlink():
        raise Unmanageable(f"{path} is a symbolic link")
    try:
        with path.open("rb") as stream:
            raw = stream.read(MAX_BYTES + 1)
    except FileNotFoundError:
        return None
    if len(raw) > MAX_BYTES:
        raise Unmanageable(f"{path} is unexpectedly large")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Unmanageable(f"{path} is not UTF-8 text") from None


def write(path, text):
    path = Path(path)
    path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".versionlock-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o644)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def installed_evr(name, root=None):
    command = ["rpm", "-q", "--qf", "%{EPOCHNUM}:%{VERSION}-%{RELEASE}\\n", name]
    if root:
        command[1:1] = ["--root", str(root)]
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    lines = result.stdout.split()
    return lines[-1] if result.returncode == 0 and lines else None


def manage(path, series, check=False):
    """Converge the file; returns (changed, preserved_reason)."""
    try:
        text = read(path)
        updated = converge(text, series)
    except Unmanageable as error:
        return False, str(error)
    if updated is not None and not check:
        write(path, updated)
    return updated is not None, None


def main():
    from ansible.module_utils.basic import AnsibleModule
    module = AnsibleModule(argument_spec={
        "series": {"type": "list", "elements": "dict", "required": True},
        "path": {"type": "path", "default": DEFAULT_PATH},
        "report_installed": {"type": "bool", "default": True},
    }, supports_check_mode=True)
    series = module.params["series"]
    try:
        validate_series(series)
        changed, preserved = manage(module.params["path"], series, module.check_mode)
    except (OSError, ValueError) as error:
        module.fail_json(msg=str(error))
    if preserved:
        module.warn(f"{module.params['path']} was left as it is, so the qualified series "
                    f"({describe(series)}) is not enforced: {preserved}")
    outside = []
    if module.params["report_installed"]:
        outside = outside_series(series, installed_evr)
        for problem in outside:
            module.warn(problem + "; dnf keeps it but will not move within another series "
                        "until a CybexOS release qualifies it")
    module.exit_json(changed=changed, preserved=bool(preserved), outside=outside)


if __name__ == "__main__":
    main()
