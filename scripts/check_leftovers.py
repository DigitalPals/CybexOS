#!/usr/bin/env python3
"""Fail if any 'NerdOS / nerd' reference survives the rename outside the allowlist (stdlib only).

Usage:
  python3 check_leftovers.py [--repo REPO_ROOT] [--allowlist FILE] [--untracked] [--show-allowed]

Scans tracked file paths and text contents (plus untracked, non-ignored files
with --untracked) for the retired product name and CLI. Every hit must match an allowlist rule:

    <path-glob> :: <regex on the matching line>      # reason (required)

`*` in the glob also matches '/'. For a path hit the regex is tested against
the path itself. Exit status: 0 = clean, 1 = unexpected leftovers, 2 = usage error.
"""
import argparse
import fnmatch
import pathlib
import re
import subprocess
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--repo", default=".")
ap.add_argument("--allowlist", default=str(pathlib.Path(__file__).with_name("rename-leftovers-allowlist.txt")))
ap.add_argument("--untracked", action="store_true", help="also scan untracked, non-ignored files")
ap.add_argument("--show-allowed", action="store_true", help="list allowlisted hits too")
args = ap.parse_args()
root = pathlib.Path(args.repo).resolve()

rules = []
for n, raw in enumerate(pathlib.Path(args.allowlist).read_text().splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if "::" not in line or "#" not in line.split("::", 1)[1]:
        sys.exit(f"{args.allowlist}:{n}: expected '<glob> :: <regex>  # reason'")
    glob, rest = (s.strip() for s in line.split("::", 1))
    regex, reason = (s.strip() for s in rest.split("#", 1))
    if not reason:
        sys.exit(f"{args.allowlist}:{n}: every rule needs a reason after '#'")
    rules.append((glob, re.compile(regex), reason, n))


def allowed(path, subject):
    for glob, rx, reason, n in rules:
        if fnmatch.fnmatchcase(path, glob) and rx.search(subject):
            return n
    return None


cmd = ["git", "-C", str(root), "ls-files", "-z"]
files = [f for f in subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.split("\0") if f and (root / f).is_file()]
if args.untracked:
    cmd = ["git", "-C", str(root), "ls-files", "-z", "--others", "--exclude-standard"]
    files += [f for f in subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.split("\0") if f]

NAME = re.compile(r"(?i)nerdos|\bnerd\b")
bad, ok = [], []
for rel in files:
    if NAME.search(rel):
        (ok if allowed(rel, rel) else bad).append(f"{rel}  [path]")
    p = root / rel
    try:
        data = p.read_bytes()
    except (IsADirectoryError, FileNotFoundError, PermissionError):
        continue
    if b"\0" in data[:8192]:
        if NAME.search(data.decode("latin-1")):
            (ok if allowed(rel, "<binary>") else bad).append(f"{rel}  [binary content]")
        continue
    for lineno, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
        if NAME.search(line):
            entry = f"{rel}:{lineno}: {line.strip()[:160]}"
            (ok if allowed(rel, line) else bad).append(entry)

if args.show_allowed and ok:
    print(f"== allowlisted ({len(ok)})")
    print("\n".join(ok))
if bad:
    print(f"== unexpected 'NerdOS / nerd' references ({len(bad)})")
    print("\n".join(bad))
    files_bad = len({b.split(":", 1)[0].split("  [", 1)[0] for b in bad})
    print(f"\nFAIL: {len(bad)} unexpected references in {files_bad} files ({len(ok)} allowlisted).")
    sys.exit(1)
print(f"OK: no unexpected 'NerdOS / nerd' references ({len(ok)} allowlisted).")
