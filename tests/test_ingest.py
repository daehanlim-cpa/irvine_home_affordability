"""Unit tests for the ingest handler's pure logic.

The parts worth testing here are the ones that protect other people's servers
and our own bill: rate limiting, the robots gate's fail-closed behaviour, and
payload hashing for idempotency. None of them need Snowflake, so they run in the
local gate rather than costing credits.

Run: python3 -m pytest tests/test_ingest.py -q
"""

from __future__ import annotations

import importlib.util
import sys
import time
import urllib.error
from pathlib import Path

import pytest

HANDLER = Path(__file__).resolve().parents[1] / "snowflake" / "10_raw" / "proc_ingest_arcgis.py"
spec = importlib.util.spec_from_file_location("proc_ingest_arcgis", HANDLER)
assert spec and spec.loader
ingest = importlib.util.module_from_spec(spec)
sys.modules["proc_ingest_arcgis"] = ingest
spec.loader.exec_module(ingest)


class TestRateLimiter:
    def test_spaces_requests_by_the_configured_interval(self):
        limiter = ingest.RateLimiter(rps=20.0)  # 50ms apart
        limiter.wait()
        start = time.monotonic()
        limiter.wait()
        elapsed = time.monotonic() - start
        assert elapsed >= 0.045, f"second call returned after only {elapsed:.3f}s"

    def test_zero_rps_disables_throttling(self):
        limiter = ingest.RateLimiter(rps=0)
        start = time.monotonic()
        for _ in range(5):
            limiter.wait()
        assert time.monotonic() - start < 0.05


class TestRobotsGate:
    """The gate must fail CLOSED. Allowing a fetch we could not verify is the
    failure mode that gets a crawler banned, and it is silent."""

    def _gate_with_opener(self, monkeypatch, side_effect):
        gate = ingest.RobotsGate("TestAgent/1.0")
        monkeypatch.setattr(ingest.urllib.request, "urlopen", side_effect)
        return gate

    def test_missing_robots_txt_is_permissive(self, monkeypatch):
        def raise_404(*_a, **_k):
            raise urllib.error.HTTPError("u", 404, "Not Found", {}, None)

        gate = self._gate_with_opener(monkeypatch, raise_404)
        allowed, reason = gate.allows("https://example.gov/arcgis/rest")
        assert allowed is True
        assert "404" in reason

    def test_server_error_fails_closed(self, monkeypatch):
        def raise_500(*_a, **_k):
            raise urllib.error.HTTPError("u", 500, "Server Error", {}, None)

        gate = self._gate_with_opener(monkeypatch, raise_500)
        allowed, reason = gate.allows("https://example.gov/arcgis/rest")
        assert allowed is False, "unreadable robots.txt must not be treated as permission"
        assert "failing closed" in reason

    def test_network_failure_fails_closed(self, monkeypatch):
        def raise_conn(*_a, **_k):
            raise OSError("connection refused")

        gate = self._gate_with_opener(monkeypatch, raise_conn)
        allowed, reason = gate.allows("https://example.gov/arcgis/rest")
        assert allowed is False
        assert "failing closed" in reason

    def test_disallow_directive_is_honoured(self, monkeypatch):
        class FakeResponse:
            def read(self):
                return b"User-agent: *\nDisallow: /arcgis/\n"

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

        gate = self._gate_with_opener(monkeypatch, lambda *_a, **_k: FakeResponse())
        allowed, _ = gate.allows("https://example.gov/arcgis/rest/services")
        assert allowed is False

    def test_verdict_is_cached_per_host(self, monkeypatch):
        calls = {"n": 0}

        class FakeResponse:
            def read(self):
                calls["n"] += 1
                return b"User-agent: *\nAllow: /\n"

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

        gate = self._gate_with_opener(monkeypatch, lambda *_a, **_k: FakeResponse())
        gate.allows("https://example.gov/a")
        gate.allows("https://example.gov/b")
        assert calls["n"] == 1, "robots.txt should be fetched once per host, not per URL"


class TestPayloadHashing:
    def test_identical_payloads_hash_identically(self):
        assert ingest._sha256('{"a":1}') == ingest._sha256('{"a":1}')

    def test_different_payloads_differ(self):
        assert ingest._sha256('{"a":1}') != ingest._sha256('{"a":2}')

    def test_hash_is_sha256_shaped(self):
        digest = ingest._sha256("x")
        assert len(digest) == 64 and all(c in "0123456789abcdef" for c in digest)


class TestConstants:
    """These bound the blast radius of a paging bug; a regression that removes
    them would be silent until the bill arrives."""

    def test_circuit_breaker_is_set(self):
        assert 1 <= ingest.CIRCUIT_BREAKER_THRESHOLD <= 10

    def test_page_ceiling_is_set(self):
        assert 0 < ingest.MAX_PAGES <= 10000


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
