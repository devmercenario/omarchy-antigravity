#!/usr/bin/env python3
"""
Unit and Integration Tests for Antigravity Usage Collector
Part of omarchy-antigravity
"""

import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone, timedelta
from unittest.mock import patch, MagicMock

# Load collector module from bin/omarchy-agent-usage-antigravity
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COLLECTOR_PATH = os.path.join(PROJECT_ROOT, "bin", "omarchy-agent-usage-antigravity")

loader = SourceFileLoader("collector", COLLECTOR_PATH)
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
sys.modules["collector"] = collector
loader.exec_module(collector)


class TestQuotaParsing(unittest.TestCase):
    """Test quota bucket parsing and remainingFraction to percent conversion."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        collector.CACHE_DIR = self.temp_dir
        collector.CACHE_FILE = os.path.join(self.temp_dir, "test-limits.json")

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    @patch("urllib.request.urlopen")
    def test_fetch_authoritative_limits_success(self, mock_urlopen):
        mock_response = MagicMock()
        mock_response.read.return_value = json.dumps({
            "groups": [
                {
                    "displayName": "GEMINI MODELS",
                    "buckets": [
                        {
                            "displayName": "Five Hour Limit",
                            "window": "5h",
                            "remainingFraction": 0.85,
                            "resetTime": "2026-09-04T18:00:00Z"
                        },
                        {
                            "displayName": "Weekly Limit",
                            "window": "weekly",
                            "remainingFraction": 0.95,
                            "resetTime": "2026-09-11T12:00:00Z"
                        }
                    ]
                },
                {
                    "displayName": "CLAUDE AND GPT MODELS",
                    "buckets": [
                        {
                            "displayName": "Five Hour Limit",
                            "window": "5h",
                            "remainingFraction": 1.0,
                            "resetTime": "2026-09-04T20:00:00Z"
                        },
                        {
                            "displayName": "Weekly Limit",
                            "window": "weekly",
                            "remainingFraction": 0.70,
                            "resetTime": "2026-09-11T15:00:00Z"
                        }
                    ]
                }
            ]
        }).encode("utf-8")
        mock_response.__enter__.return_value = mock_response
        mock_urlopen.return_value = mock_response

        limits = collector.fetch_authoritative_limits("fake-token")

        self.assertEqual(len(limits), 4)

        # Gemini 5h: 1.0 - 0.85 = 0.15 used
        self.assertEqual(limits[0]["title"], "Gemini (5h)")
        self.assertEqual(limits[0]["label"], "Session")
        self.assertAlmostEqual(limits[0]["percent"], 0.15, places=4)
        self.assertEqual(limits[0]["resetsAt"], "2026-09-04T18:00:00Z")

        # Gemini Weekly: 1.0 - 0.95 = 0.05 used
        self.assertEqual(limits[1]["title"], "Gemini (Weekly)")
        self.assertEqual(limits[1]["label"], "Weekly")
        self.assertAlmostEqual(limits[1]["percent"], 0.05, places=4)

        # Claude/GPT 5h: 1.0 - 1.0 = 0.0 used
        self.assertEqual(limits[2]["title"], "Claude/GPT (5h)")
        self.assertEqual(limits[2]["label"], "Session")
        self.assertAlmostEqual(limits[2]["percent"], 0.0, places=4)

        # Claude/GPT Weekly: 1.0 - 0.70 = 0.30 used
        self.assertEqual(limits[3]["title"], "Claude/GPT (Weekly)")
        self.assertEqual(limits[3]["label"], "Weekly")
        self.assertAlmostEqual(limits[3]["percent"], 0.30, places=4)

        # Verify disk cache written
        self.assertTrue(os.path.exists(collector.CACHE_FILE))


class TestKeyringAndAuthentication(unittest.TestCase):
    """Test keyring extraction, validation, and token refresh."""

    @patch("subprocess.check_output")
    def test_get_token_from_keyring_found(self, mock_subp):
        sample_data = {
            "token": {
                "access_token": "test-access-token",
                "refresh_token": "test-refresh-token",
                "expiry": (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
            }
        }
        mock_subp.return_value = json.dumps(sample_data).encode("utf-8")

        data, err = collector.get_token_from_keyring()
        self.assertIsNotNone(data)
        self.assertEqual(err, "")
        self.assertEqual(data["token"]["access_token"], "test-access-token")

    @patch("subprocess.check_output")
    def test_get_token_from_keyring_empty(self, mock_subp):
        mock_subp.return_value = b""
        data, err = collector.get_token_from_keyring()
        self.assertIsNone(data)
        self.assertIn("No Antigravity credentials", err)

    @patch("subprocess.check_output")
    def test_get_token_from_keyring_corrupt_json(self, mock_subp):
        mock_subp.return_value = b"invalid json content {"
        data, err = collector.get_token_from_keyring()
        self.assertIsNone(data)
        self.assertIn("Failed to read keyring", err)

    @patch("collector.get_token_from_keyring")
    def test_get_valid_access_token_valid(self, mock_keyring):
        future_exp = (datetime.now(timezone.utc) + timedelta(hours=2)).isoformat()
        mock_keyring.return_value = ({
            "token": {
                "access_token": "valid-token",
                "refresh_token": "refresh-token",
                "expiry": future_exp
            }
        }, "")

        token, err = collector.get_valid_access_token()
        self.assertEqual(token, "valid-token")
        self.assertEqual(err, "")

    @patch("subprocess.Popen")
    @patch("urllib.request.urlopen")
    @patch("collector.get_token_from_keyring")
    def test_get_valid_access_token_refreshes_expired(self, mock_keyring, mock_urlopen, mock_popen):
        past_exp = (datetime.now(timezone.utc) - timedelta(minutes=10)).isoformat()
        mock_keyring.return_value = ({
            "token": {
                "access_token": "expired-token",
                "refresh_token": "valid-refresh-token",
                "expiry": past_exp
            }
        }, "")

        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps({
            "access_token": "new-refreshed-token",
            "expires_in": 3600
        }).encode("utf-8")
        mock_resp.__enter__.return_value = mock_resp
        mock_urlopen.return_value = mock_resp

        mock_proc = MagicMock()
        mock_proc.communicate.return_value = (b"", b"")
        mock_popen.return_value = mock_proc

        token, err = collector.get_valid_access_token()
        self.assertEqual(token, "new-refreshed-token")
        self.assertEqual(err, "")


class TestLocalStats(unittest.TestCase):
    """Test reading local history and counting prompt usage."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.history_file = os.path.join(self.temp_dir, "history.jsonl")
        self.brain_dir = os.path.join(self.temp_dir, "brain")
        os.makedirs(self.brain_dir, exist_ok=True)
        os.makedirs(os.path.join(self.brain_dir, "session-1"), exist_ok=True)
        os.makedirs(os.path.join(self.brain_dir, "session-2"), exist_ok=True)

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_collect_local_stats_with_data(self):
        now_ms = time.time() * 1000
        lines = [
            json.dumps({"timestamp": now_ms, "prompt": "test 1"}),
            json.dumps({"timestamp": now_ms - 3600000, "prompt": "test 2"}),
            "corrupted line",
            ""
        ]
        with open(self.history_file, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))

        with patch("os.path.expanduser") as mock_expand:
            def expand_mock(path):
                if "history.jsonl" in path:
                    return self.history_file
                if "brain" in path:
                    return self.brain_dir
                return path
            mock_expand.side_effect = expand_mock

            stats = collector.collect_local_stats()

            self.assertEqual(stats["todayPrompts"], 2)
            self.assertEqual(stats["totalPrompts"], 2)
            self.assertEqual(stats["todaySessions"], 1)
            self.assertEqual(stats["totalSessions"], 2)
            self.assertEqual(len(stats["recentDays"]), 7)


class TestMainExecutionScenarios(unittest.TestCase):
    """Test overall collector behavior under various system conditions."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.orig_cache_dir = collector.CACHE_DIR
        self.orig_cache_file = collector.CACHE_FILE
        self.orig_user_cache = collector.USER_CACHE_FILE
        collector.CACHE_DIR = self.temp_dir
        collector.CACHE_FILE = os.path.join(self.temp_dir, "limits.json")
        collector.USER_CACHE_FILE = os.path.join(self.temp_dir, "user.json")

    def tearDown(self):
        collector.CACHE_DIR = self.orig_cache_dir
        collector.CACHE_FILE = self.orig_cache_file
        collector.USER_CACHE_FILE = self.orig_user_cache
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    @patch("shutil.which")
    @patch("collector.get_valid_access_token")
    def test_main_cli_not_installed(self, mock_auth, mock_which):
        mock_which.return_value = None  # agy missing
        mock_auth.return_value = (None, "No credentials")

        with patch("builtins.print") as mock_print:
            collector.main(argv=[])
            mock_print.assert_called_once()
            output_str = mock_print.call_args[0][0]
            record = json.loads(output_str)

            self.assertEqual(record["schemaVersion"], 1)
            self.assertEqual(record["usageStatusText"], "Not installed")
            self.assertIn("not found in PATH", record["authHelpText"])

    @patch("shutil.which")
    @patch("collector.get_valid_access_token")
    def test_main_unauthenticated_state(self, mock_auth, mock_which):
        mock_which.return_value = "/usr/bin/agy"
        mock_auth.return_value = (None, "No Antigravity credentials found in keyring")

        with patch("builtins.print") as mock_print:
            collector.main(argv=[])
            mock_print.assert_called_once()
            output_str = mock_print.call_args[0][0]
            record = json.loads(output_str)

            self.assertEqual(record["schemaVersion"], 1)
            self.assertEqual(record["id"], "antigravity")
            self.assertTrue(record["ready"])
            self.assertEqual(record["usageStatusText"], "Waiting for auth")
            self.assertIn("No Antigravity credentials", record["authHelpText"])
            self.assertEqual(record["limits"], [])
            self.assertEqual(record["tierLabel"], "Pro")

    @patch("shutil.which")
    @patch("collector.fetch_authoritative_limits")
    @patch("collector.get_cached_user_email")
    @patch("collector.get_valid_access_token")
    def test_main_authenticated_healthy(self, mock_auth, mock_email, mock_limits, mock_which):
        mock_which.return_value = "/usr/bin/agy"
        mock_auth.return_value = ("valid-token", "")
        mock_email.return_value = "developer@example.com"
        mock_limits.return_value = [
            {"title": "Gemini (5h)", "label": "Session", "percent": 0.12, "resetsAt": ""}
        ]

        with patch("builtins.print") as mock_print:
            collector.main(argv=[])
            mock_print.assert_called_once()
            output_str = mock_print.call_args[0][0]
            record = json.loads(output_str)

            self.assertEqual(record["schemaVersion"], 1)
            self.assertEqual(record["id"], "antigravity")
            self.assertEqual(record["usageStatusText"], "")
            self.assertEqual(record["tierLabel"], "Pro · developer@example.com")
            self.assertEqual(len(record["limits"]), 1)


if __name__ == "__main__":
    unittest.main()
