import importlib.machinery
import importlib.util
import io
import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock


def load_cu_module():
    cu_path = str(Path(__file__).resolve().parent / "cu")
    loader = importlib.machinery.SourceFileLoader("cu_module", cu_path)
    spec = importlib.util.spec_from_loader("cu_module", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class FetchUsageApiTests(unittest.TestCase):
    def setUp(self):
        self.cu = load_cu_module()
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.cache_path = Path(self.tmpdir.name) / "usage-api-cache.json"
        self.original_cache_file = self.cu.USAGE_CACHE_FILE
        self.cu.USAGE_CACHE_FILE = self.cache_path
        self.addCleanup(self._restore_cache_path)

    def _restore_cache_path(self):
        self.cu.USAGE_CACHE_FILE = self.original_cache_file

    def _write_cache(self, cached_at_delta, resets_at_delta):
        now = datetime.now(timezone.utc)
        payload = {
            "_cached_at": (now - cached_at_delta).isoformat(),
            "seven_day": {
                "resets_at": (now + resets_at_delta).isoformat(),
                "utilization": 73,
            },
        }
        self.cache_path.write_text(json.dumps(payload))
        return payload

    def test_returns_fresh_cache_without_keychain_lookup(self):
        cached = self._write_cache(cached_at_delta=timedelta(seconds=60), resets_at_delta=timedelta(days=2))

        with mock.patch.object(self.cu.subprocess, "run") as mocked_run:
            result = self.cu.fetch_usage_api()

        self.assertEqual(result["seven_day"]["resets_at"], cached["seven_day"]["resets_at"])
        mocked_run.assert_not_called()

    def test_returns_stale_cache_if_current_window_is_still_valid(self):
        cached = self._write_cache(cached_at_delta=timedelta(minutes=10), resets_at_delta=timedelta(days=2))

        failed = mock.Mock(returncode=1, stdout="")
        with mock.patch.object(self.cu.subprocess, "run", return_value=failed):
            result = self.cu.fetch_usage_api()

        self.assertEqual(result["seven_day"]["resets_at"], cached["seven_day"]["resets_at"])

    def test_does_not_return_expired_cache_when_refresh_fails(self):
        self._write_cache(cached_at_delta=timedelta(minutes=10), resets_at_delta=timedelta(minutes=-5))

        failed = mock.Mock(returncode=1, stdout="")
        with mock.patch.object(self.cu.subprocess, "run", return_value=failed):
            result = self.cu.fetch_usage_api()

        self.assertIsNone(result)


class FetchCodexWeeklyUsageTests(unittest.TestCase):
    def setUp(self):
        self.cu = load_cu_module()
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.cu.CODEX_USAGE_CACHE_FILE = Path(self.tmpdir.name) / "codex-usage-api-cache.json"

    def _write_cache(self, cached_at_delta, resets_at_delta):
        now = datetime.now(timezone.utc)
        payload = {
            "_cached_at": (now - cached_at_delta).isoformat(),
            "utilization": 12,
            "windowEnd": (now + resets_at_delta).isoformat(),
        }
        self.cu.CODEX_USAGE_CACHE_FILE.write_text(json.dumps(payload))
        return payload

    def test_returns_fresh_cache_without_starting_app_server(self):
        cached = self._write_cache(cached_at_delta=timedelta(seconds=60), resets_at_delta=timedelta(days=2))

        with mock.patch.object(self.cu, "_find_codex_executable") as mocked_find:
            result = self.cu.fetch_codex_weekly_usage()

        self.assertEqual(result["utilization"], cached["utilization"])
        mocked_find.assert_not_called()

    def test_fetches_weekly_window_from_app_server(self):
        resets_at = int((datetime.now(timezone.utc) + timedelta(days=6)).timestamp())
        payload = {
            "rateLimits": {
                "primary": {"usedPercent": 30, "windowDurationMins": 300, "resetsAt": resets_at},
                "secondary": {"usedPercent": 4, "windowDurationMins": 10080, "resetsAt": resets_at},
            },
            "rateLimitsByLimitId": {
                "codex": {
                    "primary": {"usedPercent": 30, "windowDurationMins": 300, "resetsAt": resets_at},
                    "secondary": {"usedPercent": 4, "windowDurationMins": 10080, "resetsAt": resets_at},
                },
            },
        }

        with mock.patch.object(self.cu, "_find_codex_executable", return_value="/tmp/codex"), \
                mock.patch.object(self.cu, "_request_codex_rate_limits", return_value=payload) as mocked_request:
            result = self.cu.fetch_codex_weekly_usage()

        self.assertEqual(result["utilization"], 4)
        self.assertEqual(datetime.fromisoformat(result["windowEnd"]).timestamp(), resets_at)
        mocked_request.assert_called_once_with("/tmp/codex")

    def test_app_server_request_keeps_stdin_open_until_response(self):
        payload = {"rateLimits": {"primary": {"usedPercent": 4, "windowDurationMins": 10080}}}
        process = mock.Mock()
        process.stdin = mock.Mock()
        process.stdout = io.StringIO(json.dumps({"id": 2, "result": payload}) + "\n")
        process.poll.return_value = None

        with mock.patch.object(self.cu.subprocess, "Popen", return_value=process) as mocked_popen, \
                mock.patch.object(self.cu.select, "select", return_value=([process.stdout], [], [])):
            result = self.cu._request_codex_rate_limits("/tmp/codex")

        self.assertEqual(result, payload)
        request_messages = [json.loads(call.args[0]) for call in process.stdin.write.call_args_list]
        self.assertEqual(request_messages[0]["method"], "initialize")
        self.assertEqual(request_messages[1]["method"], "initialized")
        self.assertEqual(request_messages[2]["method"], "account/rateLimits/read")
        process.stdin.flush.assert_called_once_with()
        process.terminate.assert_called_once_with()
        mocked_popen.assert_called_once()
        self.assertEqual(mocked_popen.call_args.args[0], ["/tmp/codex", "app-server"])

    def test_returns_valid_stale_cache_when_app_server_fails(self):
        cached = self._write_cache(cached_at_delta=timedelta(minutes=10), resets_at_delta=timedelta(days=2))

        with mock.patch.object(self.cu, "_find_codex_executable", return_value="/tmp/codex"), \
                mock.patch.object(self.cu, "_request_codex_rate_limits", return_value=None):
            result = self.cu.fetch_codex_weekly_usage()

        self.assertEqual(result["utilization"], cached["utilization"])


class BoundaryParsingTests(unittest.TestCase):
    def setUp(self):
        self.cu = load_cu_module()

    def test_get_5h_boundaries_falls_back_when_resets_at_is_null(self):
        before = datetime.now(timezone.utc)
        start, end, utilization = self.cu.get_5h_boundaries({
            "five_hour": {"utilization": 0.0, "resets_at": None},
        })
        after = datetime.now(timezone.utc)

        self.assertIsNone(utilization)
        self.assertLessEqual(end, after)
        self.assertGreaterEqual(end, before)
        self.assertAlmostEqual((end - start).total_seconds(), 5 * 3600, delta=2)


if __name__ == "__main__":
    unittest.main()
