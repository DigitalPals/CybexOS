#!/usr/bin/env python3
"""Boot comparisons reject incomparable and incomplete evidence."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("startup_evidence", Path(__file__).resolve().parents[1] / "scripts/startup-evidence.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ComparisonTests(unittest.TestCase):
    def samples(self, revision, values):
        return [{"host": "same-hardware", "configuration": "same-settings", "bootKind": "warm",
                 "loginKind": "normal", "architecture": "x86_64", "revision": revision,
                 "bootId": revision + str(index), "milestoneEvidence": "observer log",
                 "milestonesSeconds": {"desktopReady": value, "portalReady": value + 1,
                                       "humanAuthentication": 2}}
                for index, value in enumerate(values)]

    def test_median_and_spread(self):
        result = module.compare(self.samples("base", [8, 12, 9]), self.samples("candidate", [8, 6, 7]))
        self.assertEqual(result["comparison"]["before"]["desktopReady"],
                         {"medianSeconds": 9, "minimumSeconds": 8, "maximumSeconds": 12})
        self.assertEqual(result["comparison"]["after"]["desktopReady"]["medianSeconds"], 7)

    def test_mixed_hardware_repeated_boots_and_missing_milestones_are_blocked(self):
        before = self.samples("base", [8, 12, 9])
        after = self.samples("candidate", [8, 6, 7])
        for key, value in (("host", "other"), ("bootKind", "cold"), ("loginKind", "first"),
                           ("configuration", "different"), ("bootId", before[0]["bootId"]),
                           ("milestoneEvidence", ""), ("milestonesSeconds", {})):
            broken = copy.deepcopy(after)
            broken[0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                module.compare(before, broken)
        with self.assertRaises(ValueError):
            module.compare(before[:1], after)


if __name__ == "__main__":
    unittest.main()
