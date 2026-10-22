#!/usr/bin/env python3
"""Inventory every CybexOS/Cybex reference in a git checkout (stdlib only).

Usage:  python3 inventory.py [REPO_ROOT] > inventory.txt

Sections: spelling counts, distinct identifiers, tracked paths that carry the
name, the files with the most references, repository/infrastructure
identities, brand surfaces, and the old names that must survive the rename.
"""
import collections
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()


def git(*args):
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout


files = [f for f in git("ls-files", "-z").split("\0") if f]
head = git("rev-parse", "--short", "HEAD").strip()


def text_of(rel):
    p = root / rel
    try:
        data = p.read_bytes()
    except (IsADirectoryError, FileNotFoundError, PermissionError):
        return None
    if b"\0" in data[:8192]:
        return None
    return data.decode("utf-8", "replace")


FAMILIES = [
    ("CybexOS", re.compile(r"CybexOS")),
    ("cybexos", re.compile(r"cybexos")),
    ("CYBEXOS", re.compile(r"CYBEXOS")),
    ("Cybex (bare, not +OS)", re.compile(r"Cybex(?![oO][sS])")),
    ("cybex (bare, not +os)", re.compile(r"cybex(?![oO][sS])")),
    ("CYBEX (bare, not +OS)", re.compile(r"CYBEX(?![oO][sS])")),
]
IDENT = re.compile(r"[A-Za-z0-9_.-]*[Cc][Yy][Bb][Ee][Xx][A-Za-z0-9_.-]*")
SPECIAL = [
    ("GitHub repository DigitalPals/CybexOS", re.compile(r"DigitalPals/CybexOS(?![A-Za-z_])")),
    ("GitHub Pages package repo", re.compile(r"digitalpals\.github\.io/CybexOS")),
    ("Reverse-DNS org.cybexos.*", re.compile(r"org\.cybexos\b")),
    ("Actions secrets/vars CYBEXOS_*", re.compile(r"(secrets|vars)\.CYBEXOS_[A-Z_]+")),
    ("Release manifest product id", re.compile(r'"product":\s*"cybexos"')),
    ("Kernel argument cybexos.install", re.compile(r"cybexos\.install")),
    ("Signing key file CYBEXOS-desktop.asc", re.compile(r"CYBEXOS-desktop\.asc")),
    ("Live ISO name CybexOS-Live-", re.compile(r"CybexOS-Live-")),
    ("Old brand red (#dd0034 family)", re.compile(r"(?i)#(dd0034|f0164a|b8002b|ff6b86)\b")),
    ("cybex-wordmark.svg", re.compile(r"cybex-wordmark\.svg")),
    ("Plymouth theme 'cybex'", re.compile(r"themes/cybex\b|plymouth_theme\s*[=:]\s*'?cybex|cybex\.(plymouth|script)")),
]
KEEP = [
    ("External upstream DigitalPals/omarchy-cybex", re.compile(r"omarchy-cybex")),
    ("Previous name fedora-config", re.compile(r"fedora-config")),
]

counts = collections.Counter()
idents = collections.Counter()
per_file = collections.Counter()
special = collections.defaultdict(list)
keep = collections.defaultdict(list)

for rel in files:
    text = text_of(rel)
    if text is None:
        continue
    for name, rx in FAMILIES:
        n = len(rx.findall(text))
        counts[name] += n
    hits = IDENT.findall(text)
    idents.update(hits)
    per_file[rel] += len(hits)
    for lineno, line in enumerate(text.splitlines(), 1):
        for name, rx in SPECIAL:
            if rx.search(line):
                special[name].append(f"{rel}:{lineno}")
        for name, rx in KEEP:
            if rx.search(line):
                keep[name].append(f"{rel}:{lineno}")

paths = [f for f in files if re.search(r"(?i)cybex", f)]
dirs = sorted({str(pathlib.PurePosixPath(f).parent) for f in files
               for part in [pathlib.PurePosixPath(f).parent] if re.search(r"(?i)cybex", str(part))})
binaries = [f for f in files if text_of(f) is None and re.search(r"(?i)\.(png|svg|ico|jpg|jpeg|webp|gif)$", f)]

out = []
w = out.append
w(f"# CybexOS → NerdOS rename inventory\n# repository: {root}\n# commit: {head}\n# tracked files: {len(files)}\n")
w("## 1. Occurrences by spelling (case-sensitive; 'bare' excludes the +OS forms)")
for name, _ in FAMILIES:
    w(f"  {counts[name]:>6}  {name}")
w("")
w(f"## 2. Distinct identifiers containing 'cybex' ({len(idents)})")
for ident, n in sorted(idents.items(), key=lambda kv: (-kv[1], kv[0])):
    w(f"  {n:>6}  {ident}")
w("")
w(f"## 3. Tracked files whose path contains 'cybex' ({len(paths)})")
for p in paths:
    w(f"  {p}")
w("")
w(f"## 4. Directories whose path contains 'cybex' ({len(dirs)})")
for p in dirs:
    w(f"  {p}/")
w("")
w("## 5. Files with the most references (top 60)")
for rel, n in per_file.most_common(60):
    if n:
        w(f"  {n:>6}  {rel}")
w("")
w("## 6. Identity, infrastructure and brand-surface hits")
for name, _ in SPECIAL:
    hits = special.get(name, [])
    w(f"### {name} ({len(hits)})")
    for h in hits[:200]:
        w(f"  {h}")
    if len(hits) > 200:
        w(f"  … {len(hits) - 200} more")
w("")
w("## 7. Image files in the repository (check each for old branding)")
for b in binaries:
    w(f"  {b}")
w("")
w("## 8. Old names that must survive (do not rename blindly)")
for name, _ in KEEP:
    hits = keep.get(name, [])
    w(f"### {name} ({len(hits)})")
    for h in hits[:120]:
        w(f"  {h}")
    if len(hits) > 120:
        w(f"  … {len(hits) - 120} more")
print("\n".join(out))
