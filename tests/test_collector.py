#!/usr/bin/env python3
"""
Unit and Integration Tests for Antigravity Usage Collector
Part of omarchy-antigravity
"""

import importlib.util
from importlib.machinery import SourceFileLoader
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import time
import unittest
import urllib.error
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


class FakeHTTPResponse:
    """Minimal streaming stand-in for urllib's HTTP response.

    Unlike a ``MagicMock`` with ``read.return_value``, this fake advances
    through the body on every ``read`` call, so bounded-read regressions are
    observable and cannot accidentally return the whole payload forever.
    """

    def __init__(self, body=b"", headers=None, status=200):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self._body = body
        self._pos = 0
        self.headers = headers if headers is not None else {}
        self.status = status
        self.bytes_served = 0

    def read(self, amt=None):
        if amt is None:
            chunk = self._body[self._pos:]
        else:
            chunk = self._body[self._pos:self._pos + amt]
        self._pos += len(chunk)
        self.bytes_served += len(chunk)
        return chunk

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class TestQuotaParsing(unittest.TestCase):
    """Test quota bucket parsing and remainingFraction to percent conversion."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.orig_retry_delay = collector.RETRY_DELAY_SECONDS
        collector.RETRY_DELAY_SECONDS = 0
        collector.CACHE_DIR = self.temp_dir
        collector.CACHE_FILE = os.path.join(self.temp_dir, "test-limits.json")

    def tearDown(self):
        collector.RETRY_DELAY_SECONDS = self.orig_retry_delay
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    @patch("urllib.request.urlopen")
    def test_fetch_authoritative_limits_success(self, mock_urlopen):
        payload = json.dumps({
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
        mock_urlopen.return_value = FakeHTTPResponse(payload)

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

    @patch("urllib.request.urlopen")
    def test_fetch_authoritative_limits_retry_success(self, mock_urlopen):
        payload = json.dumps({
            "groups": [{
                "displayName": "GEMINI MODELS",
                "buckets": [{
                    "displayName": "Five Hour Limit",
                    "window": "5h",
                    "remainingFraction": 0.80,
                    "resetTime": "2026-09-04T18:00:00Z"
                }]
            }]
        }).encode("utf-8")

        # Fails first attempt, succeeds on second attempt
        mock_urlopen.side_effect = [urllib.error.URLError("Temporary network blip"), FakeHTTPResponse(payload)]

        limits = collector.fetch_authoritative_limits("fake-token")
        self.assertEqual(len(limits), 1)
        self.assertEqual(mock_urlopen.call_count, 2)

    @patch("urllib.request.urlopen")
    def test_fetch_authoritative_limits_retry_exhausted(self, mock_urlopen):
        mock_urlopen.side_effect = urllib.error.URLError("Persistent connection failure")

        with self.assertRaises(urllib.error.URLError):
            collector.fetch_authoritative_limits("fake-token")

        # 1 initial + 2 retries = 3 attempts
        self.assertEqual(mock_urlopen.call_count, 3)

    @patch("collector.resolve_tool")
    @patch("collector.run_bounded_stdout")
    def test_fetch_limits_via_agy_success(self, mock_bounded, mock_which):
        mock_which.return_value = "/usr/bin/agy"
        stdout = (
            "Gemini Models\tWeekly Limit Remaining\t40%\t2026-09-10T18:37:23Z\n"
            "Gemini Models\tFive Hour Limit Remaining\t58%\t2026-09-08T22:56:17Z\n"
            "Claude and GPT models\tWeekly Limit Remaining\t100%\t2026-09-15T21:20:15Z\n"
            "Claude and GPT models\tFive Hour Limit Remaining\t100%\t2026-09-09T02:20:15Z\n"
        )
        mock_bounded.return_value = (0, stdout.encode("utf-8"), False)

        limits = collector.fetch_limits_via_agy()
        self.assertIsNotNone(limits)
        self.assertEqual(len(limits), 4)
        self.assertEqual(limits[0]["title"], "Gemini (5h)")
        self.assertEqual(limits[0]["percent"], 0.42)
        self.assertEqual(limits[1]["title"], "Gemini (Weekly)")
        self.assertEqual(limits[1]["percent"], 0.6)
        self.assertEqual(limits[2]["title"], "Claude/GPT (5h)")
        self.assertEqual(limits[2]["percent"], 0.0)
        self.assertEqual(limits[3]["title"], "Claude/GPT (Weekly)")
        self.assertEqual(limits[3]["percent"], 0.0)

    @patch("collector.resolve_tool")
    def test_fetch_limits_via_agy_not_installed(self, mock_which):
        mock_which.return_value = None
        self.assertIsNone(collector.fetch_limits_via_agy())


class TestKeyringAndAuthentication(unittest.TestCase):
    """Test token extraction from file and keyring, validation, and token refresh."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.orig_token_file = collector.TOKEN_FILE
        self.test_token_file = os.path.join(self.temp_dir, "test-oauth-token")
        collector.TOKEN_FILE = self.test_token_file

    def tearDown(self):
        collector.TOKEN_FILE = self.orig_token_file
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_get_token_from_file_found(self):
        sample_data = {
            "token": {
                "access_token": "file-access-token",
                "refresh_token": "file-refresh-token",
                "expiry": (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
            }
        }
        with open(self.test_token_file, "w", encoding="utf-8") as f:
            json.dump(sample_data, f)
        os.chmod(self.test_token_file, 0o600)

        data, err = collector.get_token_from_file()
        self.assertIsNotNone(data)
        self.assertEqual(err, "")
        self.assertEqual(data["token"]["access_token"], "file-access-token")

    def test_get_token_from_file_missing(self):
        data, err = collector.get_token_from_file()
        self.assertIsNone(data)
        self.assertIn("Token file not found", err)

    def test_get_token_from_file_corrupt(self):
        with open(self.test_token_file, "w", encoding="utf-8") as f:
            f.write("invalid json content {")
        os.chmod(self.test_token_file, 0o600)
        data, err = collector.get_token_from_file()
        self.assertIsNone(data)
        self.assertIn("Failed to read token file", err)

    def test_get_token_from_file_symlink_rejected(self):
        real_file = os.path.join(self.temp_dir, "real-target-token")
        sample_data = {"token": {"access_token": "target-token"}}
        with open(real_file, "w", encoding="utf-8") as f:
            json.dump(sample_data, f)
        os.chmod(real_file, 0o600)
        os.symlink(real_file, self.test_token_file)

        data, err = collector.get_token_from_file()
        self.assertIsNone(data)
        self.assertIn("Failed to open token file", err)

    def test_get_token_from_file_insecure_mode_rejected(self):
        sample_data = {"token": {"access_token": "tok"}}
        with open(self.test_token_file, "w", encoding="utf-8") as f:
            json.dump(sample_data, f)
        os.chmod(self.test_token_file, 0o644)

        data, err = collector.get_token_from_file()
        self.assertIsNone(data)
        self.assertIn("insecure permissions", err)

    def test_get_token_from_file_owner_mismatch_rejected(self):
        sample_data = {"token": {"access_token": "tok"}}
        with open(self.test_token_file, "w", encoding="utf-8") as f:
            json.dump(sample_data, f)
        os.chmod(self.test_token_file, 0o600)

        with patch("os.getuid", return_value=os.getuid() + 9999):
            data, err = collector.get_token_from_file()
            self.assertIsNone(data)
            self.assertIn("owner mismatch", err)

    def test_get_token_from_file_non_regular_rejected(self):
        os.mkdir(self.test_token_file, 0o700)
        data, err = collector.get_token_from_file()
        self.assertIsNone(data)
        self.assertTrue("not a regular file" in err or "Is a directory" in err or "Failed to open" in err)

    def test_get_token_from_file_oversized_rejected(self):
        with open(self.test_token_file, "wb") as f:
            f.write(b'{"token": "' + b"x" * (collector.MAX_TOKEN_FILE_SIZE + 10) + b'"}')
        os.chmod(self.test_token_file, 0o600)

        data, err = collector.get_token_from_file()
        self.assertIsNone(data)
        self.assertIn("exceeds maximum allowed size", err)

    def test_get_credentials_prefers_file(self):
        sample_data = {"token": {"access_token": "file-tok"}}
        with open(self.test_token_file, "w", encoding="utf-8") as f:
            json.dump(sample_data, f)
        os.chmod(self.test_token_file, 0o600)

        data, source, err = collector.get_credentials()
        self.assertEqual(source, "file")
        self.assertEqual(data["token"]["access_token"], "file-tok")
        self.assertEqual(err, "")

    @patch("collector.get_token_from_keyring")
    def test_get_credentials_fallback_keyring(self, mock_keyring):
        mock_keyring.return_value = ({"token": {"access_token": "keyring-tok"}}, "")
        data, source, err = collector.get_credentials()
        self.assertEqual(source, "keyring")
        self.assertEqual(data["token"]["access_token"], "keyring-tok")
        self.assertEqual(err, "")

    def test_save_token_to_file(self):
        sample_data = {"token": {"access_token": "new-token"}}
        collector.save_token_to_file(sample_data)
        self.assertTrue(os.path.exists(self.test_token_file))
        st = os.stat(self.test_token_file)
        self.assertEqual(st.st_mode & 0o777, 0o600)
        self.assertEqual(st.st_uid, os.getuid())
        with open(self.test_token_file, "r", encoding="utf-8") as f:
            saved = json.load(f)
        self.assertEqual(saved["token"]["access_token"], "new-token")

    def test_save_token_to_file_replaces_symlink_safely(self):
        victim_file = os.path.join(self.temp_dir, "victim-secret")
        with open(victim_file, "w", encoding="utf-8") as f:
            f.write("victim-secret-content")
        os.symlink(victim_file, self.test_token_file)

        sample_data = {"token": {"access_token": "refreshed-safe-token"}}
        collector.save_token_to_file(sample_data)

        # Ensure symlink was replaced, not followed
        self.assertFalse(os.path.islink(self.test_token_file))
        # Ensure victim content was preserved
        with open(victim_file, "r", encoding="utf-8") as f:
            self.assertEqual(f.read(), "victim-secret-content")
        # Ensure token file has new token and 0600 mode
        st = os.stat(self.test_token_file)
        self.assertEqual(st.st_mode & 0o777, 0o600)
        data, err = collector.get_token_from_file()
        self.assertIsNotNone(data)
        self.assertEqual(data["token"]["access_token"], "refreshed-safe-token")

    @patch("collector.resolve_tool", return_value="/usr/bin/secret-tool")
    @patch("collector.run_bounded_stdout")
    def test_get_token_from_keyring_found(self, mock_bounded, _mock_tool):
        sample_data = {
            "token": {
                "access_token": "test-access-token",
                "refresh_token": "test-refresh-token",
                "expiry": (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
            }
        }
        mock_bounded.return_value = (0, json.dumps(sample_data).encode("utf-8"), False)

        data, err = collector.get_token_from_keyring()
        self.assertIsNotNone(data)
        self.assertEqual(err, "")
        self.assertEqual(data["token"]["access_token"], "test-access-token")

    @patch("collector.resolve_tool", return_value="/usr/bin/secret-tool")
    @patch("collector.run_bounded_stdout")
    def test_get_token_from_keyring_empty(self, mock_bounded, _mock_tool):
        mock_bounded.return_value = (0, b"", False)
        data, err = collector.get_token_from_keyring()
        self.assertIsNone(data)
        self.assertIn("No Antigravity credentials", err)

    @patch("collector.resolve_tool", return_value="/usr/bin/secret-tool")
    @patch("collector.run_bounded_stdout")
    def test_get_token_from_keyring_corrupt_json(self, mock_bounded, _mock_tool):
        mock_bounded.return_value = (0, b"invalid json content {", False)
        data, err = collector.get_token_from_keyring()
        self.assertIsNone(data)
        self.assertIn("Failed to read keyring", err)

    @patch("collector.resolve_tool", return_value="/usr/bin/secret-tool")
    @patch("collector.run_bounded_stdout")
    def test_get_token_from_keyring_oversized_output_rejected(self, mock_bounded, _mock_tool):
        mock_bounded.return_value = (0, b"{}", True)
        data, err = collector.get_token_from_keyring()
        self.assertIsNone(data)
        self.assertIn("exceeds maximum allowed size", err)

    @patch("collector.resolve_tool", return_value="/usr/bin/agy")
    @patch("collector.run_bounded_stdout")
    def test_fetch_limits_via_agy_oversized_output_rejected(self, mock_bounded, _mock_tool):
        mock_bounded.return_value = (0, b"", True)
        self.assertIsNone(collector.fetch_limits_via_agy())

    @patch("collector.get_credentials")
    def test_get_valid_access_token_valid(self, mock_cred):
        future_exp = (datetime.now(timezone.utc) + timedelta(hours=2)).isoformat()
        mock_cred.return_value = ({
            "token": {
                "access_token": "valid-token",
                "refresh_token": "refresh-token",
                "expiry": future_exp
            }
        }, "file", "")

        token, err = collector.get_valid_access_token()
        self.assertEqual(token, "valid-token")
        self.assertEqual(err, "")

    @patch("collector.save_token_to_file")
    @patch("urllib.request.urlopen")
    @patch("collector.get_credentials")
    def test_get_valid_access_token_refreshes_expired(self, mock_cred, mock_urlopen, mock_save):
        past_exp = (datetime.now(timezone.utc) - timedelta(minutes=10)).isoformat()
        mock_cred.return_value = ({
            "token": {
                "access_token": "expired-token",
                "refresh_token": "valid-refresh-token",
                "expiry": past_exp
            }
        }, "file", "")

        payload = json.dumps({
            "access_token": "new-refreshed-token",
            "expires_in": 3600
        }).encode("utf-8")
        mock_urlopen.return_value = FakeHTTPResponse(payload)

        token, err = collector.get_valid_access_token()
        self.assertEqual(token, "new-refreshed-token")
        self.assertEqual(err, "")
        mock_save.assert_called_once()


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
            json.dumps({"timestamp": now_ms - 5000, "prompt": "test 2"}),
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

    def _stats_with_history(self, history_path):
        def expand_mock(path):
            if "history.jsonl" in path:
                return history_path
            if "brain" in path:
                return self.brain_dir
            return path

        with patch("os.path.expanduser", side_effect=expand_mock):
            return collector.collect_local_stats()

    def test_collect_local_stats_ignores_symlinked_history(self):
        real = os.path.join(self.temp_dir, "real-history.jsonl")
        with open(real, "w", encoding="utf-8") as f:
            f.write(json.dumps({"timestamp": time.time() * 1000}) + "\n")
        link = os.path.join(self.temp_dir, "linked-history.jsonl")
        os.symlink(real, link)

        stats = self._stats_with_history(link)
        self.assertEqual(stats["totalPrompts"], 0)

    def test_collect_local_stats_ignores_oversized_history(self):
        big = os.path.join(self.temp_dir, "big-history.jsonl")
        with open(big, "wb") as f:
            f.seek(collector.MAX_HISTORY_FILE_SIZE + 1)
            f.write(b"\n")

        stats = self._stats_with_history(big)
        self.assertEqual(stats["totalPrompts"], 0)


class TestMainExecutionScenarios(unittest.TestCase):
    """Test overall collector behavior under various system conditions."""

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.orig_cache_dir = collector.CACHE_DIR
        self.orig_cache_file = collector.CACHE_FILE
        self.orig_user_cache = collector.USER_CACHE_FILE
        self.orig_state_dir = collector.STATE_DIR
        self.orig_state_file = collector.STATE_FILE
        collector.CACHE_DIR = self.temp_dir
        collector.CACHE_FILE = os.path.join(self.temp_dir, "limits.json")
        collector.USER_CACHE_FILE = os.path.join(self.temp_dir, "user.json")
        # Point the state file at a path that does not exist yet, so the
        # session-suspension early return is never triggered by a pre-existing
        # state file on the developer/CI machine.
        collector.STATE_DIR = self.temp_dir
        collector.STATE_FILE = os.path.join(self.temp_dir, "state.json")

    def tearDown(self):
        collector.CACHE_DIR = self.orig_cache_dir
        collector.CACHE_FILE = self.orig_cache_file
        collector.USER_CACHE_FILE = self.orig_user_cache
        collector.STATE_DIR = self.orig_state_dir
        collector.STATE_FILE = self.orig_state_file
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    @patch("collector.resolve_tool")
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

    @patch("collector.resolve_tool")
    @patch("collector.fetch_limits_via_agy")
    @patch("collector.get_valid_access_token")
    def test_main_unauthenticated_state(self, mock_auth, mock_agy, mock_which):
        mock_which.return_value = "/usr/bin/agy"
        mock_auth.return_value = (None, "No Antigravity credentials found in keyring")
        mock_agy.return_value = None

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

    @patch("collector.resolve_tool")
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

    @patch("collector.resolve_tool")
    @patch("collector.fetch_limits_via_agy")
    @patch("collector.fetch_authoritative_limits")
    @patch("collector.get_cached_user_email")
    @patch("collector.get_valid_access_token")
    def test_main_quota_failure_sets_error_and_empty_limits(self, mock_auth, mock_email, mock_limits, mock_agy, mock_which):
        mock_which.return_value = "/usr/bin/agy"
        mock_auth.return_value = ("valid-token", "")
        mock_email.return_value = "developer@example.com"
        mock_limits.side_effect = urllib.error.URLError("Quota endpoint down")
        mock_agy.return_value = None

        # Put a stale cache file in place to ensure it is NOT used when quota fails
        with open(collector.CACHE_FILE, "w", encoding="utf-8") as f:
            json.dump({"limits": [{"title": "Stale Gemini", "percent": 0.5}], "fetchedAt": 1000}, f)

        with patch("builtins.print") as mock_print:
            collector.main(argv=["--force"])
            mock_print.assert_called_once()
            output_str = mock_print.call_args[0][0]
            record = json.loads(output_str)

            self.assertEqual(record["schemaVersion"], 1)
            self.assertEqual(record["id"], "antigravity")
            self.assertEqual(record["usageStatusText"], "Quota unavailable")
            self.assertIn("Failed to retrieve quota", record["authHelpText"])
            self.assertEqual(record["limits"], [])

    @patch("collector.resolve_tool")
    @patch("collector.fetch_limits_via_agy")
    @patch("collector.fetch_authoritative_limits")
    @patch("collector.get_cached_user_email")
    @patch("collector.get_valid_access_token")
    def test_main_quota_failure_falls_back_to_agy(self, mock_auth, mock_email, mock_limits, mock_agy, mock_which):
        mock_which.return_value = "/usr/bin/agy"
        mock_auth.return_value = ("valid-token", "")
        mock_email.return_value = "developer@example.com"
        mock_limits.side_effect = urllib.error.URLError("Quota endpoint down")
        mock_agy.return_value = [
            {"title": "Gemini (5h)", "label": "Session", "percent": 0.42, "resetsAt": "2026-09-08T22:56:17Z"}
        ]

        with patch("builtins.print") as mock_print:
            collector.main(argv=["--force"])
            mock_print.assert_called_once()
            output_str = mock_print.call_args[0][0]
            record = json.loads(output_str)

            self.assertEqual(record["schemaVersion"], 1)
            self.assertEqual(record["id"], "antigravity")
            self.assertEqual(record["usageStatusText"], "")
            self.assertEqual(len(record["limits"]), 1)
            self.assertEqual(record["limits"][0]["percent"], 0.42)

    @patch("collector.resolve_tool", return_value="/usr/bin/pgrep")
    @patch("subprocess.run")
    def test_is_agy_running_detection(self, mock_run, _mock_tool):
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_run.return_value = mock_proc
        self.assertTrue(collector.is_agy_running())

        mock_proc.returncode = 1
        self.assertFalse(collector.is_agy_running())

    @patch("collector.is_agy_running")
    @patch("os.path.exists")
    def test_main_skips_when_no_active_session_and_state_exists(self, mock_exists, mock_running):
        mock_exists.side_effect = lambda path: True if path == collector.STATE_FILE else False
        mock_running.return_value = False

        with patch("builtins.print") as mock_print, patch("sys.stderr.write") as mock_stderr:
            result = collector.main(argv=[])
            self.assertEqual(result, 0)
            mock_print.assert_not_called()
            mock_stderr.assert_called()
            self.assertIn("no active agy session running", mock_stderr.call_args[0][0])

    @patch("collector.is_agy_running")
    @patch("os.path.exists")
    @patch("collector.resolve_tool")
    @patch("collector.get_valid_access_token")
    @patch("collector.fetch_authoritative_limits")
    @patch("collector.get_cached_user_email")
    def test_main_forced_bypasses_session_check(self, mock_email, mock_limits, mock_auth, mock_which, mock_exists, mock_running):
        mock_exists.side_effect = lambda path: True if path == collector.STATE_FILE else False
        mock_running.return_value = False
        mock_which.return_value = "/usr/bin/agy"
        mock_auth.return_value = ("token", "")
        mock_email.return_value = "user@example.com"
        mock_limits.return_value = []

        with patch("builtins.print") as mock_print:
            collector.main(argv=["--force"])
            mock_print.assert_called_once()
            record = json.loads(mock_print.call_args[0][0])
            self.assertEqual(record["id"], "antigravity")

    def test_save_private_json_permissions_and_atomicity(self):
        target = os.path.join(self.temp_dir, "private-data.json")
        collector.save_private_json(target, {"key": "secret_value"})
        self.assertTrue(os.path.exists(target))
        st = os.stat(target)
        self.assertTrue(stat.S_ISREG(st.st_mode))
        self.assertEqual(st.st_mode & 0o077, 0, "Private file must not have group or other permissions")
        with open(target, "r", encoding="utf-8") as f:
            data = json.load(f)
            self.assertEqual(data.get("key"), "secret_value")

    def test_ensure_dir_sets_0700_mode(self):
        test_dir = os.path.join(self.temp_dir, "private_dir")
        collector.ensure_dir(test_dir)
        self.assertTrue(os.path.isdir(test_dir))
        st = os.stat(test_dir)
        self.assertEqual(st.st_mode & 0o077, 0, "Directory must have private 0700 permissions")

    def test_get_cached_limits_descriptor_read(self):
        cache_path = os.path.join(self.temp_dir, "limits-test.json")
        orig_cache = collector.CACHE_FILE
        collector.CACHE_FILE = cache_path
        try:
            collector.save_private_json(cache_path, {"limits": [{"title": "Cached 5h", "percent": 0.25}]})
            cached = collector.get_cached_limits(max_age_seconds=60)
            self.assertIsNotNone(cached)
            self.assertEqual(cached["limits"][0]["title"], "Cached 5h")

            # Stale cache test
            cached_stale = collector.get_cached_limits(max_age_seconds=-1)
            self.assertIsNone(cached_stale)
        finally:
            collector.CACHE_FILE = orig_cache


class TestBoundedNetworkReads(unittest.TestCase):
    """Regression coverage for the bounded HTTP response reader and every
    remote response/error path (OAuth refresh, userinfo, and quota)."""

    def test_read_bounded_accepts_body_at_limit(self):
        body = b"a" * 128
        self.assertEqual(collector.read_bounded(FakeHTTPResponse(body), 128), body)

    def test_read_bounded_rejects_body_over_limit(self):
        with self.assertRaises(collector.BoundedReadError):
            collector.read_bounded(FakeHTTPResponse(b"a" * 129), 128)

    def test_read_bounded_rejects_declared_content_length_before_reading(self):
        resp = FakeHTTPResponse(b"a" * 512, headers={"Content-Length": "999999"})
        with self.assertRaises(collector.BoundedReadError):
            collector.read_bounded(resp, 256)
        self.assertEqual(resp.bytes_served, 0, "oversized Content-Length must short-circuit before reading")

    def test_read_bounded_never_reads_more_than_limit_plus_one(self):
        # A continuously delivered body with no Content-Length must still be capped.
        resp = FakeHTTPResponse(b"a" * (10 * 1024 * 1024))
        with self.assertRaises(collector.BoundedReadError):
            collector.read_bounded(resp, 1024)
        self.assertLessEqual(resp.bytes_served, 1025)

    @patch("urllib.request.urlopen")
    def test_quota_oversized_response_is_rejected_without_retry(self, mock_urlopen):
        mock_urlopen.return_value = FakeHTTPResponse(
            b"{" + b"a" * (collector.QUOTA_RESPONSE_MAX_BYTES + 1)
        )
        with self.assertRaises(collector.BoundedReadError):
            collector.fetch_authoritative_limits("fake-token")
        self.assertEqual(mock_urlopen.call_count, 1)

    @patch("collector.save_token_to_file")
    @patch("urllib.request.urlopen")
    @patch("collector.get_credentials")
    def test_oauth_refresh_oversized_response_is_discarded(self, mock_cred, mock_urlopen, mock_save):
        past_exp = (datetime.now(timezone.utc) - timedelta(minutes=10)).isoformat()
        mock_cred.return_value = ({
            "token": {
                "refresh_token": "valid-refresh-token",
            }
        }, "file", "")
        mock_urlopen.return_value = FakeHTTPResponse(
            b"{" + b"a" * (collector.OAUTH_TOKEN_RESPONSE_MAX_BYTES + 1)
        )

        token, err = collector.get_valid_access_token()
        self.assertIsNone(token)
        self.assertIn("Unable to obtain valid access token", err)
        mock_save.assert_not_called()

    @patch("os.path.expanduser")
    @patch("urllib.request.urlopen")
    def test_userinfo_oversized_response_returns_empty(self, mock_urlopen, mock_expand):
        missing_accounts = "/nonexistent/antigravity-google_accounts.json"
        mock_expand.side_effect = lambda p: missing_accounts if p.endswith("google_accounts.json") else p
        orig_user_cache = collector.USER_CACHE_FILE
        collector.USER_CACHE_FILE = "/nonexistent/antigravity-user-cache.json"
        try:
            mock_urlopen.return_value = FakeHTTPResponse(
                b"{" + b"a" * (collector.USERINFO_RESPONSE_MAX_BYTES + 1)
            )
            self.assertEqual(collector.get_cached_user_email("fake-token"), "")
        finally:
            collector.USER_CACHE_FILE = orig_user_cache

    def test_read_private_json_rejects_oversized_file(self):
        path = os.path.join(tempfile.mkdtemp(), "big.json")
        with open(path, "w", encoding="utf-8") as f:
            f.write("x" * 2048)
        os.chmod(path, 0o600)
        data, st = collector.read_private_json(path, max_bytes=1024)
        self.assertIsNone(data)
        self.assertIsNone(st)

    def test_read_private_json_rejects_symlink(self):
        tmp = tempfile.mkdtemp()
        real = os.path.join(tmp, "real.json")
        with open(real, "w", encoding="utf-8") as f:
            json.dump({"a": 1}, f)
        os.chmod(real, 0o600)
        link = os.path.join(tmp, "link.json")
        os.symlink(real, link)
        data, _ = collector.read_private_json(link)
        self.assertIsNone(data)

    def test_get_cached_user_email_reads_google_accounts_descriptor(self):
        tmp = tempfile.mkdtemp()
        acc = os.path.join(tmp, "google_accounts.json")
        with open(acc, "w", encoding="utf-8") as f:
            json.dump({"active": "user@example.com"}, f)
        os.chmod(acc, 0o600)
        orig_user_cache = collector.USER_CACHE_FILE
        collector.USER_CACHE_FILE = os.path.join(tmp, "missing-user.json")
        try:
            with patch("os.path.expanduser", side_effect=lambda p: acc if p.endswith("google_accounts.json") else p):
                self.assertEqual(collector.get_cached_user_email("fake-token"), "user@example.com")
        finally:
            collector.USER_CACHE_FILE = orig_user_cache

    @patch("urllib.request.urlopen")
    def test_http_error_body_is_bounded_and_reported(self, mock_urlopen):
        err = urllib.error.HTTPError(
            "https://example.invalid/quota",
            500,
            "Server Error",
            {},
            io.BytesIO(b"e" * (collector.HTTP_ERROR_BODY_MAX_BYTES * 8)),
        )
        self.addCleanup(err.close)
        mock_urlopen.side_effect = err
        with self.assertRaises(collector.HttpFetchError) as ctx:
            collector.fetch_json(
                urllib.request.Request("https://example.invalid/quota"),
                timeout=5,
                max_bytes=1024,
                error_label="quota request failed",
            )
        self.assertIn("HTTP 500", str(ctx.exception))

    @patch("urllib.request.urlopen")
    def test_http_error_small_body_is_included_in_diagnostics(self, mock_urlopen):
        mock_urlopen.side_effect = urllib.error.HTTPError(
            "https://example.invalid/quota",
            403,
            "Forbidden",
            {},
            io.BytesIO(b"quota disabled"),
        )
        self.addCleanup(mock_urlopen.side_effect.close)
        with self.assertRaises(collector.HttpFetchError) as ctx:
            collector.fetch_json(
                urllib.request.Request("https://example.invalid/quota"),
                timeout=5,
                max_bytes=1024,
                error_label="quota request failed",
            )
        self.assertIn("HTTP 403", str(ctx.exception))
        self.assertIn("quota disabled", str(ctx.exception))

    @patch("urllib.request.urlopen")
    def test_invalid_json_response_is_wrapped(self, mock_urlopen):
        mock_urlopen.return_value = FakeHTTPResponse(b"not json")
        with self.assertRaises(collector.HttpFetchError):
            collector.fetch_json(
                urllib.request.Request("https://example.invalid/quota"),
                timeout=5,
                max_bytes=1024,
                error_label="quota request failed",
            )

    def test_redirects_are_refused(self):
        handler = collector._NoRedirectHandler()
        req = urllib.request.Request("https://oauth2.googleapis.com/token")
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            handler.redirect_request(
                req, None, 307, "Temporary Redirect", {}, "https://attacker.invalid/token"
            )
        self.addCleanup(ctx.exception.close)
        self.assertIn("refusing redirect", str(ctx.exception))

    def test_default_opener_refuses_redirects(self):
        # The module installs a process-wide opener without a redirect handler;
        # ensure the redirect handler was replaced by the refusing one.
        opener = urllib.request._opener
        handler_types = [type(h).__name__ for h in opener.handlers]
        self.assertIn("_NoRedirectHandler", handler_types)
        self.assertNotIn("HTTPRedirectHandler", handler_types)


class TestTrustedToolResolution(unittest.TestCase):
    """External helpers must resolve to a trusted, non-world-writable path."""

    def test_resolve_tool_rejects_missing(self):
        with patch("shutil.which", return_value=None):
            self.assertIsNone(collector.resolve_tool("definitely-not-a-tool"))

    def test_resolve_tool_rejects_world_writable_directory(self):
        tmp = tempfile.mkdtemp()
        tool = os.path.join(tmp, "evil-tool")
        with open(tool, "w", encoding="utf-8") as f:
            f.write("#!/bin/sh\nexit 0\n")
        os.chmod(tool, 0o755)
        os.chmod(tmp, 0o777)
        with patch("shutil.which", return_value=tool):
            self.assertIsNone(collector.resolve_tool("evil-tool"))

    def test_resolve_tool_rejects_non_executable(self):
        tmp = tempfile.mkdtemp()
        tool = os.path.join(tmp, "plain-file")
        with open(tool, "w", encoding="utf-8") as f:
            f.write("not a program")
        os.chmod(tool, 0o644)
        with patch("shutil.which", return_value=tool):
            self.assertIsNone(collector.resolve_tool("plain-file"))

    def test_resolve_tool_accepts_trusted_user_directory(self):
        tmp = tempfile.mkdtemp()
        tool = os.path.join(tmp, "ok-tool")
        with open(tool, "w", encoding="utf-8") as f:
            f.write("#!/bin/sh\nexit 0\n")
        os.chmod(tool, 0o755)
        with patch("shutil.which", return_value=tool):
            self.assertEqual(collector.resolve_tool("ok-tool"), tool)


if __name__ == "__main__":
    unittest.main()
