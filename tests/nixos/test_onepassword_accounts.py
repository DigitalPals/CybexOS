#!/usr/bin/env python3
"""Count 1Password's accounts as the welcome guide does, without changing its database."""
import hashlib
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / 'desktop/quickshell/scripts/onepassword-accounts.py'


class OnePasswordAccountsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.config = Path(self.temp.name, 'config')
        self.database = self.config / '1Password/1password.sqlite'

    def tearDown(self):
        self.temp.cleanup()

    def count(self):
        env = {**os.environ, 'XDG_CONFIG_HOME': str(self.config)}
        return subprocess.run([sys.executable, '-B', str(SCRIPT)], env=env, capture_output=True, text=True, timeout=10)

    def create(self, accounts):
        self.database.parent.mkdir(parents=True)
        db = sqlite3.connect(self.database)
        # 1Password's own table, kept in write-ahead mode as the app keeps it.
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('CREATE TABLE accounts (account_uuid TEXT PRIMARY KEY NOT NULL, data BLOB NOT NULL)')
        db.executemany('INSERT INTO accounts VALUES (?, ?)', [(f'account-{n}', b'sealed') for n in range(accounts)])
        db.commit()
        return db

    # The database and its log. Readers mark their place in the shared-memory
    # index (-shm), which is how SQLite lets them read beside the app.
    def files(self):
        return {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                for path in sorted(self.database.parent.iterdir()) if not path.name.endswith('-shm')}

    def test_never_started(self):
        result = self.count()
        self.assertEqual((result.returncode, result.stdout), (0, '0\n'))
        self.assertFalse(self.config.exists())

    def test_signed_out_and_signed_in(self):
        app = self.create(0)
        self.assertEqual(self.count().stdout, '0\n')
        app.executemany('INSERT INTO accounts VALUES (?, ?)', [('personal', b'sealed'), ('work', b'sealed')])
        app.commit()
        self.assertEqual(self.count().stdout, '2\n')
        app.close()

    def test_reads_beside_the_running_app_without_writing(self):
        # The app holds the database open; a new account is still in its log.
        app = self.create(1)
        before = self.files()
        result = self.count()
        self.assertEqual((result.returncode, result.stdout), (0, '1\n'))
        self.assertEqual(self.files(), before)
        app.close()

    def test_unknown_database(self):
        self.database.parent.mkdir(parents=True)
        self.database.write_bytes(b'not a database')
        result = self.count()
        self.assertEqual((result.returncode, result.stdout), (1, ''))
        self.assertEqual(self.database.read_bytes(), b'not a database')
        sqlite3.connect(self.database.with_name('other.sqlite')).close()
        self.database.unlink()
        self.database.with_name('other.sqlite').rename(self.database)
        result = self.count()
        self.assertEqual(result.returncode, 1)
        self.assertIn('no such table: accounts', result.stderr)


if __name__ == '__main__':
    unittest.main()
