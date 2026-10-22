"""Boot-selection command fixtures, not boot or Secure Boot qualification."""
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'lifecycle'))
from nerdos.boot import entry, trial
from nerdos.common import Failure

OLD = '/nix/store/' + 'a' * 32 + '-nixos-system-old'
NEW = '/nix/store/' + 'b' * 32 + '-nixos-system-new'


def boot_entry(system, identifier, kind='type1'):
    return {'id': identifier, 'type': kind, 'options': 'quiet init=' + system + '/init loglevel=4'}


class BootSelectionTests(unittest.TestCase):
    def test_standard_entries_and_lanzaboote_ukis(self):
        for kind, suffix in [('type1', 'conf'), ('type2', 'efi')]:
            entries = [boot_entry(NEW, 'nixos-generation-2.' + suffix, kind),
                       boot_entry(OLD, 'nixos-generation-1.' + suffix, kind)]
            calls = []
            def run(args, **kwargs):
                calls.append(args)
                return json.dumps(entries) if args[1] == 'list' else ''
            trial([NEW, OLD], run)
            self.assertEqual(calls[1:], [['bootctl', 'set-default', 'nixos-generation-1.' + suffix],
                                        ['bootctl', 'set-oneshot', 'nixos-generation-2.' + suffix]])
            calls.clear()
            trial(['--restore', OLD], run)
            self.assertEqual(calls[1:], [['bootctl', 'set-oneshot', ''],
                                        ['bootctl', 'set-default', 'nixos-generation-1.' + suffix]])
            calls.clear()
            trial(['--commit', NEW], run)
            self.assertEqual(calls[1:], [['bootctl', 'set-default', 'nixos-generation-2.' + suffix]])

    def test_no_substring_specialisation_or_ambiguous_init_match(self):
        for options in ['other=' + NEW + ' init=' + OLD + '/init',
                        'init=' + NEW + '/init-other',
                        'init=' + NEW + '/init init=' + OLD + '/init',
                        'init=' + NEW + '/specialisation/rescue/init']:
            with self.subTest(options=options), self.assertRaises(Failure):
                entry(NEW, [{'type': 'type1', 'id': 'nixos-generation-2.conf', 'options': options}])

    def test_missing_candidate_changes_no_firmware_state(self):
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            return json.dumps([boot_entry(OLD, 'nixos-generation-1.conf')])
        with self.assertRaises(Failure):
            trial([NEW, OLD], run)
        self.assertEqual(len(calls), 1)

    def test_reject_unsafe_or_exhausted_entries(self):
        with self.assertRaises(Failure):
            entry(NEW, [boot_entry(NEW, '*.efi', 'type2')])
        with self.assertRaises(Failure):
            entry(NEW, [boot_entry(NEW, 'nixos-2.efi', 'type2') | {'triesLeft': 0}])


if __name__ == '__main__':
    unittest.main()
