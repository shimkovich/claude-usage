import importlib.machinery
import importlib.util
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
