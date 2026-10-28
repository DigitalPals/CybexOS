#!/usr/bin/env python3
"""How many accounts 1Password has, for the welcome guide's Connect step.

1Password keeps a row per signed-in account in its local database and counts
them itself. This opens that database read-only and counts the rows; it
never reads them. It prints the count, or exits 1 when it cannot tell (a
database it cannot open, or one without that table).
"""
import os
import pathlib
import sqlite3
import sys


def main() -> int:
    config = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    path = pathlib.Path(config, "1Password", "1password.sqlite")
    # 1Password creates it on its first start.
    if not path.is_file():
        print(0)
        return 0
    try:
        db = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2)
        try:
            print(db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0])
        finally:
            db.close()
    except sqlite3.Error as error:
        print(f"1Password accounts unknown: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
