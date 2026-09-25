from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import test_cost_backend as base

costs = base.costs
NOW = 1_894_708_800_000


def rate(input_rate=2e-6, output_rate=8e-6, cached=0.2e-6):
    return dict(input_cost_per_token=input_rate, output_cost_per_token=output_rate,
                cache_read_input_token_cost=cached)


def record(model="example", reported=None):
    return costs.UsageRecord("claude", NOW, model, "session", 1_000_000, 1_000_000,
                             1_000_000, 1_000_000, 500_000, reported, None)


def aggregate(records, rates=None, overrides=None):
    return costs.aggregate_usage(records, ["claude"], 7, NOW, rates or {}, "UTC", overrides)["totals"]


class ModelPricingTests(unittest.TestCase):
    def test_explicit_custom_prices_can_resolve_ambiguous_model_aliases(self):
        for model in ("sonnet", "vendor/opus", "haiku"):
            with self.subTest(model=model):
                custom = costs.parse_price_overrides(json.dumps({model: {
                    "inputCostPerMillionTokens": 2, "outputCostPerMillionTokens": 8}}))
                self.assertIsNone(aggregate([record(model)])["costUsd"])
                totals = aggregate([record(model)], overrides=custom)
                self.assertEqual(totals["costUsd"], 14)
                self.assertEqual(totals["costSource"], "customPriced")

    def test_canonical_and_qualified_prices_are_order_independent(self):
        entries = [("example", rate()), ("reseller/example", rate(3e-6, 10e-6, 3e-6))]
        for rows in (entries, list(reversed(entries))):
            table = costs.parse_rate_table(dict(rows))
            self.assertEqual(costs.lookup_rate(" EXAMPLE ", table), (2e-6, 8e-6, .2e-6, 2e-6))
            self.assertEqual(costs.lookup_rate("reseller/example", table)[0], 3e-6)
            self.assertIsNone(costs.lookup_rate("unknown/example", table))
            self.assertAlmostEqual(aggregate([record()], table)["costUsd"], 12.2)

    def test_aliases_require_unanimous_prices(self):
        same = costs.parse_rate_table({"a/example": rate(), "b/example": rate()})
        self.assertEqual(costs.lookup_rate("example", same), same["a/example"])
        conflict = costs.parse_rate_table({"a/example": rate(), "b/example": rate(cached=1e-6)})
        self.assertIsNone(costs.lookup_rate("example", conflict))
        self.assertIsNotNone(costs.lookup_rate("b/example", conflict))

    def test_variants_are_base_priced_with_visible_provenance(self):
        table = costs.parse_rate_table({"example": rate()})
        totals = aggregate([record("example[1m]")], table)
        self.assertEqual(totals["basePricedRecords"], 1)
        self.assertEqual(totals["variantPricedRecords"], 1)
        self.assertAlmostEqual(totals["costUsd"], 12.2)
        for name in ("vendor/sonnet[1m]", "<unattributed>", "<synthetic>"):
            self.assertIsNone(costs.lookup_rate(name, {name: (1, 1, 1, 1)}))

    def test_invalid_rates_and_obsolete_cache_are_rejected(self):
        self.assertEqual(costs.parse_rate_table({"bad": rate(-1), "nan": rate(float("nan")),
                                               "missing": {"input_cost_per_token": 1}}), {})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rates.json"
            path.write_text(json.dumps({"schemaVersion": 1, "fetchedAt": NOW // 1000,
                                        "rates": {"example": [99, 99, 99, 99]}}))
            self.assertIsNone(costs.load_rate_cache(path))
            table = costs.parse_rate_table({"example": rate(), "vendor/example": rate(3e-6)})
            costs.save_rate_cache(path, NOW // 1000, table)
            self.assertEqual(costs.load_rate_cache(path)[1], table)

    def test_custom_rates_are_exact_offline_and_override_reported_cost(self):
        raw = json.dumps({" vendor/Example[1m] ": {"inputCostPerMillionTokens": 2,
                           "outputCostPerMillionTokens": 8, "cacheReadCostPerMillionTokens": .5,
                           "cacheWriteCostPerMillionTokens": 3}})
        custom = costs.parse_price_overrides(raw)
        for reported in (None, 99):
            totals = aggregate([record("vendor/Example[1m]", reported)], overrides=custom)
            self.assertEqual(totals["costUsd"], 13.5)
            self.assertEqual(totals["cacheSavingsUsd"], 1.5)
            self.assertEqual(totals["costSource"], "customPriced")
            self.assertEqual(totals["customPricedRecords"], 1)
            self.assertEqual(totals["basePricedRecords"], 0)
        for other in ("Example[1m]", "vendor/example[1m]", "vendor/Example", "other/Example[1m]"):
            self.assertIsNone(aggregate([record(other)], overrides=custom)["costUsd"])
            self.assertEqual(aggregate([record(other, 99)], overrides=custom)["costUsd"], 99)

    def test_custom_zero_optional_cache_rates_and_mixed_provenance(self):
        custom = costs.parse_price_overrides(json.dumps({
            "free": {"inputCostPerMillionTokens": 0, "outputCostPerMillionTokens": 0},
            "example": {"inputCostPerMillionTokens": 2, "outputCostPerMillionTokens": 8}}))
        self.assertEqual(aggregate([record("free", 99)], overrides=custom)["costUsd"], 0)
        self.assertEqual(aggregate([record()], overrides=custom)["costUsd"], 14)
        result = aggregate([record(), record("reported", 1), record("public"), record("unknown")],
                           costs.parse_rate_table({"public": rate()}), custom)
        self.assertEqual(result["costSource"], "mixed")
        self.assertEqual([result[key] for key in ("customPricedRecords", "providerReportedRecords",
                                                 "basePricedRecords", "unpricedRecords")], [1, 1, 1, 1])

    def test_invalid_custom_prices_fail_without_silently_falling_back(self):
        valid = {"inputCostPerMillionTokens": 2, "outputCostPerMillionTokens": 8}
        bad = ["null", "[]", "{", json.dumps({"": valid}), json.dumps({"<unattributed>": valid}),
               json.dumps({"x": valid, " x ": valid}), json.dumps({"x": {"inputCostPerMillionTokens": 2}}),
               json.dumps({"x": {**valid, "surprise": 2}}), json.dumps({"x" * 257: valid}),
               json.dumps({str(i): valid for i in range(129)})]
        for value in (True, -1, float("inf"), float("nan"), "2", None, 1e10):
            bad.append(json.dumps({"x": {**valid, "inputCostPerMillionTokens": value}}))
        for raw in bad:
            with self.subTest(raw=raw[:100]), self.assertRaises(ValueError):
                costs.parse_price_overrides(raw)
        with self.assertRaises(ValueError):
            costs.parse_price_overrides(" " * (costs.MAX_OVERRIDE_BYTES + 1))

    def test_forced_refresh_bypasses_daily_ttl_but_obeys_floor(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            now = NOW // 1000
            old = costs.parse_rate_table({"example": rate()})
            costs.save_rate_cache(costs.state_path("cost-model-rates.json", path), now - 120, old)
            with mock.patch.object(costs, "fetch_rate_document", return_value={"new": rate()}) as fetch:
                self.assertEqual(costs.load_rates(path, 1, now)[0], old)
                fetch.assert_not_called()
                self.assertIn("new", costs.load_rates(path, 1, now, force=True)[0])
                self.assertEqual(fetch.call_count, 1)
                costs.load_rates(path, 1, now + 59, force=True)
                self.assertEqual(fetch.call_count, 1)
                costs.load_rates(path, 1, now + 60, force=True)
                self.assertEqual(fetch.call_count, 2)
            with mock.patch.object(costs, "fetch_rate_document", side_effect=TimeoutError()):
                table, pricing = costs.load_rates(path, 1, now + 120, force=True)
                self.assertIn("new", table)
                self.assertEqual(pricing["status"], "cached")
                self.assertIn("failed", pricing["message"])

    def test_cli_custom_prices_and_invalid_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            projects = root / "claude" / "projects"
            projects.mkdir(parents=True)
            (projects / "session.jsonl").write_text(base.TranscriptParserTests.claude_line(1) + "\n")
            # Use the transcript's fixture clock in the subprocess without relying on wall time.
            raw = json.loads((projects / "session.jsonl").read_text())
            raw["timestamp"] = costs.iso_timestamp(time.time())
            (projects / "session.jsonl").write_text(json.dumps(raw) + "\n")
            custom = json.dumps({"claude-test": {"inputCostPerMillionTokens": 2, "outputCostPerMillionTokens": 8}})
            command = [sys.executable, str(base.BACKEND), "--providers", "claude", "--state-dir", str(root / "state")]
            env = {**os.environ, "CLAUDE_CONFIG_DIR": str(root / "claude")}
            good = json.loads(subprocess.check_output(command + ["--price-overrides", custom], env=env))
            self.assertEqual(good["totals"]["costSource"], "customPriced")
            self.assertEqual(good["pricing"]["status"], "notNeeded")
            bad = json.loads(subprocess.check_output(command + ["--price-overrides", "[]"], env=env))
            self.assertIn("backendError", bad)


class IncrementalScanTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.transcripts = self.root / "transcripts"
        self.transcripts.mkdir()
        self.state = self.root / "state"
        self.tick = 0

    def write(self, path, content, append=False):
        with path.open("a" if append else "w", encoding="utf-8") as handle:
            handle.write(content)
        self.tick += 1
        stamp = NOW * 1_000_000 + self.tick * 1_000_000
        os.utime(path, ns=(stamp, stamp))

    def scan(self, provider="claude", state=None):
        with mock.patch.object(costs, "transcript_root", return_value=self.transcripts):
            return costs.scan_transcripts([provider], state or self.state, NOW)

    def test_codex_equal_response_sizes_with_advancing_totals_are_distinct(self):
        path = self.transcripts / "codex.jsonl"
        lines = base.fixture_text("codex-rollout.jsonl").splitlines()
        event = json.loads(lines[2])
        last = event["payload"]["info"]["last_token_usage"]
        event["payload"]["info"]["total_token_usage"] = dict(last)
        self.write(path, "\n".join(lines[:2] + [json.dumps(event)]) + "\n")
        self.assertEqual(len(self.scan("codex")[0]), 1)
        # A notification repeats the last response; the next actual response
        # can have exactly the same size but advances the cumulative counters.
        duplicate = json.dumps(event)
        event["timestamp"] = "2030-01-14T13:03:00Z"
        event["payload"]["info"]["total_token_usage"] = {k: v * 2 for k, v in last.items()}
        self.write(path, duplicate + "\n" + json.dumps(event) + "\n", append=True)
        warm, coverage = self.scan("codex")
        self.assertEqual(len(warm), 2)
        self.assertEqual(warm, self.scan("codex", state=self.root / "cold")[0])
        self.assertEqual(coverage[0]["status"], "ok")

    def test_invalid_numeric_transcript_is_isolated_from_readable_history(self):
        good = self.transcripts / "good.jsonl"
        bad = self.transcripts / "bad.jsonl"
        self.write(good, base.TranscriptParserTests.claude_line(1) + "\n")
        row = json.loads(base.TranscriptParserTests.claude_line(2))
        row["message"]["usage"]["input_tokens"] = 10**400
        self.write(bad, json.dumps(row) + "\n")
        records, coverage = self.scan()
        self.assertEqual(len(records), 1)
        self.assertEqual(coverage[0]["status"], "partial")
        self.assertEqual(coverage[0]["skippedFiles"], 1)

    def test_deeply_nested_scan_cache_is_rebuilt(self):
        self.write(self.transcripts / "good.jsonl", base.TranscriptParserTests.claude_line(1) + "\n")
        self.state.mkdir()
        costs.state_path("cost-scan-cache.json", self.state).write_text("[" * 2000 + "0" + "]" * 2000)
        records, coverage = self.scan()
        self.assertEqual(len(records), 1)
        self.assertEqual(coverage[0]["status"], "ok")

    def test_overflowing_cached_counter_rebuilds_the_transcript(self):
        self.write(self.transcripts / "good.jsonl", base.TranscriptParserTests.claude_line(1) + "\n")
        expected, _ = self.scan()
        path = costs.state_path("cost-scan-cache.json", self.state)
        saved = json.loads(path.read_text())
        next(iter(saved["files"].values()))["r"][0][3] = 10**400
        path.write_text(json.dumps(saved))
        records, coverage = self.scan()
        self.assertEqual(records, expected)
        self.assertEqual(coverage[0]["status"], "ok")

    def test_append_reads_only_tail_and_durable_state_contains_no_transcript_text(self):
        path = self.transcripts / "session.jsonl"
        secret = "PRIVATE-PROMPT-DO-NOT-CACHE"
        prefix = json.dumps({"tool_output": secret + "x" * 20_000}) + "\n"
        self.write(path, prefix + base.TranscriptParserTests.claude_line(1) + "\n")
        first, _ = self.scan()
        addition = base.TranscriptParserTests.claude_line(2) + "\n"
        self.write(path, addition, append=True)
        spent = []
        original = costs.TranscriptCursor.spend
        def spend(cursor, count):
            spent.append(count)
            original(cursor, count)
        with mock.patch.object(costs.TranscriptCursor, "spend", spend):
            second, coverage = self.scan()
        self.assertEqual(len(first), 1)
        self.assertEqual(len(second), 2)
        self.assertEqual(coverage[0]["status"], "ok")
        self.assertLessEqual(sum(spent), len(addition.encode()) + 2 * costs.TRANSCRIPT_GUARD_BYTES)
        self.assertEqual(second, self.scan(state=self.root / "cold")[0])
        cache = costs.state_path("cost-scan-cache.json", self.state)
        text = cache.read_text()
        self.assertNotIn(secret, text)
        self.assertNotIn(str(path), text)
        self.assertNotIn('"session"', text)
        self.assertEqual(cache.stat().st_mode & 0o777, 0o600)
        with mock.patch.dict(costs.PARSERS, {"claude": mock.Mock(side_effect=AssertionError("warm file reparsed"))}):
            self.assertEqual(second, self.scan()[0])

    def test_every_provider_matches_a_cold_scan_across_partial_line_boundaries(self):
        for provider, fixture, filename in (("claude", "claude-transcript.jsonl", "claude.jsonl"),
                                            ("codex", "codex-rollout.jsonl", "codex.jsonl"),
                                            ("kimi", "kimi-wire.jsonl", "wire.jsonl")):
            with self.subTest(provider=provider):
                for path in self.transcripts.iterdir():
                    path.unlink()
                path = self.transcripts / filename
                content = base.fixture_text(fixture)
                # Exercise partial JSON, valid JSON without its final newline,
                # duplicate content blocks, and Codex context/signature state.
                self.write(path, "")
                for line in content.splitlines(keepends=True):
                    for part in (line[:len(line)//2], line[len(line)//2:].rstrip("\n"), "\n"):
                        self.write(path, part, append=True)
                        warm, coverage = self.scan(provider)
                        cold = self.scan(provider, state=self.root / ("cold-" + str(self.tick)))[0]
                        self.assertEqual(warm, cold)
                        self.assertEqual(coverage[0]["skippedFiles"], 0)

    def test_codex_fork_state_survives_resumes_and_model_switches(self):
        path = self.transcripts / "codex.jsonl"
        lines = [
            {"timestamp": "2030-01-15T12:00:00Z", "type": "session_meta", "payload": {
                "id": "private-child", "forked_from_id": "private-parent"}},
            {"timestamp": "2030-01-15T12:00:00Z", "type": "turn_context", "payload": {"model": "model-a"}},
        ]
        def usage(timestamp, tokens):
            return {"timestamp": timestamp, "type": "event_msg", "payload": {"type": "token_count", "info": {
                "last_token_usage": {"input_tokens": tokens, "output_tokens": 2}}}}
        lines += [usage("2030-01-15T12:00:00.100Z", 100),
                  {"timestamp": "2030-01-15T12:00:00.150Z", "type": "session_meta", "payload": {"id": "private-parent"}},
                  usage("2030-01-15T12:00:00.200Z", 200),
                  usage("2030-01-15T12:00:03Z", 30),
                  usage("2030-01-15T12:00:03Z", 30),
                  {"timestamp": "2030-01-15T12:00:04Z", "type": "turn_context", "payload": {"model": "model-b"}},
                  usage("2030-01-15T12:00:07Z", 40)]
        for line in lines:
            self.write(path, json.dumps(line) + "\n", append=True)
            result, _ = self.scan("codex")
        self.assertEqual([r.model for r in result], ["model-a", "model-b"])
        self.assertEqual([r.uncached_input for r in result], [30, 40])
        self.assertEqual({r.session_id for r in result}, {costs.opaque_id("codex:private-child")})
        self.assertEqual(result, self.scan("codex", self.root / "cold")[0])
        text = costs.state_path("cost-scan-cache.json", self.state).read_text()
        self.assertNotIn("private-child", text)
        self.assertNotIn("private-parent", text)

    def test_append_budget_counts_tail_not_whole_file_and_rejects_oversized_lines(self):
        path = self.transcripts / "session.jsonl"
        self.write(path, " " * 10_000 + "{}\n" + base.TranscriptParserTests.claude_line(1) + "\n")
        self.scan()
        addition = base.TranscriptParserTests.claude_line(2) + "\n"
        self.write(path, addition, append=True)
        with mock.patch.object(costs, "MAX_TRANSCRIPT_SCAN_BYTES", len(addition) + 128):
            result, coverage = self.scan()
        self.assertEqual(len(result), 2)
        self.assertEqual(coverage[0]["status"], "ok")
        self.write(path, "x" * 600 + "\n", append=True)
        with mock.patch.object(costs, "MAX_TRANSCRIPT_LINE_BYTES", 512):
            result, coverage = self.scan()
        self.assertEqual(result, [])
        self.assertEqual(coverage[0]["status"], "failed")

    def test_rewrite_shrink_replacement_and_guard_mismatch_restart(self):
        path = self.transcripts / "session.jsonl"
        self.write(path, base.TranscriptParserTests.claude_line(1) + "\n")
        self.scan()
        for content in (base.TranscriptParserTests.claude_line(2) + "\n",
                        "{}\n", base.TranscriptParserTests.claude_line(3) + "\n"):
            self.write(path, content)
            self.assertEqual(self.scan()[0], self.scan(state=self.root / ("cold-" + str(self.tick)))[0])
        # Same inode grows but old tail bytes changed: guard must reject resume.
        self.write(path, base.TranscriptParserTests.claude_line(4) + "\n" + base.TranscriptParserTests.claude_line(5) + "\n")
        self.assertEqual(len(self.scan()[0]), 2)
        # Replaced inode, same size and mtime: cache identity must reject reuse.
        stats = path.stat()
        replacement = path.with_suffix(".new")
        self.write(replacement, base.TranscriptParserTests.claude_line(6) + "\n" + base.TranscriptParserTests.claude_line(7) + "\n")
        os.utime(replacement, ns=(stats.st_atime_ns, stats.st_mtime_ns))
        replacement.replace(path)
        self.assertEqual(self.scan()[0], self.scan(state=self.root / "replacement-cold")[0])

    def test_incremental_record_and_byte_limits_remain_atomic(self):
        path = self.transcripts / "session.jsonl"
        self.write(path, base.TranscriptParserTests.claude_line(1) + "\n")
        self.scan()
        self.write(path, base.TranscriptParserTests.claude_line(2) + "\n", append=True)
        with mock.patch.object(costs, "MAX_TRANSCRIPT_RECORDS_PER_FILE", 1):
            records, coverage = self.scan()
        self.assertEqual(records, [])
        self.assertEqual(coverage[0]["status"], "failed")
        self.scan()
        self.write(path, base.TranscriptParserTests.claude_line(3) + "\n", append=True)
        with mock.patch.object(costs, "MAX_TRANSCRIPT_SCAN_BYTES", 1):
            records, coverage = self.scan()
        self.assertEqual(records, [])
        self.assertEqual(coverage[0]["skippedFiles"], 1)
        self.assertEqual(len(self.scan()[0]), 3)

    def test_corrupt_position_and_old_cache_cause_safe_rebuild(self):
        path = self.transcripts / "session.jsonl"
        self.write(path, base.TranscriptParserTests.claude_line(1) + "\n")
        expected, _ = self.scan()
        cache_path = costs.state_path("cost-scan-cache.json", self.state)
        original = json.loads(cache_path.read_text())
        for field, value in (("offset", -1), ("offset", 10**100), ("guard", "raw text"),
                             ("state", {"model": "wrong"})):
            document = json.loads(json.dumps(original))
            next(iter(document["files"].values()))["position"][field] = value
            cache_path.write_text(json.dumps(document))
            self.assertEqual(costs.load_scan_cache(cache_path), {})
            self.assertEqual(self.scan()[0], expected)
        original["schemaVersion"] = 1
        cache_path.write_text(json.dumps(original))
        self.assertEqual(costs.load_scan_cache(cache_path), {})
        self.assertEqual(self.scan()[0], expected)


if __name__ == "__main__":
    unittest.main()
