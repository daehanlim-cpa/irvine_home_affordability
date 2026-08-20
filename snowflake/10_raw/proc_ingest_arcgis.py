"""Paginated ArcGIS REST reader, deployed as a Snowflake Python stored procedure.

Handler for RAW.SP_INGEST_ARCGIS (see proc_ingest_arcgis.sql). Kept as a separate
.py file so it can be linted, unit-tested, and reviewed as code rather than as a
string embedded in DDL.

What this enforces, beyond fetching:

  Rate limiting   A token bucket per host, configured per source in
                  ingest/sources.yaml. These are public agency servers running on
                  public money; we do not hammer them.

  Circuit breaker N consecutive failures stops the run rather than retrying into
                  an outage. A source that is down stays down for this run.

  Daily cap       A hard ceiling on outbound calls per source per day, checked
                  against OPS.API_CALL_LOG before every request. This is the
                  control that survives a bug in the paging loop.

  robots.txt      Consulted before the first request to a host, and honoured.
                  ArcGIS REST endpoints are machine-readable public records, but
                  the policy is uniform across every source so there is no
                  category of fetch that skips the check.

  Provenance      Every landed row carries source, URL, timestamp, payload hash,
                  and batch id. Re-ingesting identical data is a no-op.
"""

from __future__ import annotations

import hashlib
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser
import uuid
from datetime import datetime, timezone
from typing import Any

# Stop after this many consecutive HTTP failures. Retrying into an outage wastes
# credits and looks like abuse from the far end.
CIRCUIT_BREAKER_THRESHOLD = 5

# Refuse to loop forever if the service reports exceededTransferLimit
# indefinitely. At the configured page sizes this is far more data than any
# Irvine layer holds, so hitting it means something is wrong.
MAX_PAGES = 500

DEFAULT_USER_AGENT = "IrvineHomeAnalysis/1.0"


class RateLimiter:
    """Token bucket, one per host.

    Simple and deliberately conservative: it sleeps rather than dropping
    requests, because the goal is politeness to the far end, not throughput here.
    """

    def __init__(self, rps: float) -> None:
        self.min_interval = 1.0 / rps if rps > 0 else 0.0
        self._last = 0.0

    def wait(self) -> None:
        if self.min_interval <= 0:
            return
        elapsed = time.monotonic() - self._last
        if elapsed < self.min_interval:
            time.sleep(self.min_interval - elapsed)
        self._last = time.monotonic()


class RobotsGate:
    """robots.txt check, cached per host for the life of the run.

    Fails OPEN for government REST APIs only when robots.txt is genuinely absent
    (404), which is the documented meaning of "no restrictions". Any other
    failure to retrieve robots.txt fails CLOSED: if we cannot establish that we
    are allowed to fetch, we do not fetch.
    """

    def __init__(self, user_agent: str) -> None:
        self.user_agent = user_agent
        self._cache: dict[str, tuple[bool, str]] = {}
        self._parsers: dict[str, urllib.robotparser.RobotFileParser | None] = {}

    def allows(self, url: str) -> tuple[bool, str]:
        parsed = urllib.parse.urlparse(url)
        host = f"{parsed.scheme}://{parsed.netloc}"
        # Cache the PARSED rules per host, but evaluate the verdict per URL:
        # robots.txt is path-scoped, so caching a host-level verdict would apply
        # one path's answer to every other path on the same host.
        if host in self._parsers:
            parser = self._parsers[host]
            if parser is None:
                return True, "no robots.txt published (404)"
            allowed = parser.can_fetch(self.user_agent, url)
            return allowed, ("allowed by robots.txt" if allowed else "disallowed by robots.txt")
        if host in self._cache:
            return self._cache[host]

        robots_url = f"{host}/robots.txt"
        parser = urllib.robotparser.RobotFileParser()
        try:
            request = urllib.request.Request(
                robots_url, headers={"User-Agent": self.user_agent}
            )
            with urllib.request.urlopen(request, timeout=15) as response:
                parser.parse(response.read().decode("utf-8", errors="replace").splitlines())
            self._parsers[host] = parser
            verdict = parser.can_fetch(self.user_agent, url)
            reason = "allowed by robots.txt" if verdict else "disallowed by robots.txt"
        except urllib.error.HTTPError as exc:
            if exc.code in (404, 410):
                self._parsers[host] = None
                verdict, reason = True, "no robots.txt published (404)"
            else:
                verdict, reason = False, f"robots.txt unreadable (HTTP {exc.code}) - failing closed"
        except Exception as exc:  # noqa: BLE001 - any failure to verify is a refusal
            verdict, reason = False, f"robots.txt check failed ({exc}) - failing closed"

        self._cache[host] = (verdict, reason)
        return verdict, reason


def _sha256(payload: str) -> str:
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _calls_used_today(session: Any, source_name: str) -> int:
    row = session.sql(
        """
        SELECT COUNT(*) AS N
        FROM OPS.API_CALL_LOG
        WHERE SOURCE_NAME = ?
          AND CALLED_AT >= DATEADD('hour', -24, SYSDATE())
        """,
        params=[source_name],
    ).collect()
    return int(row[0]["N"]) if row else 0


def _log_call(
    session: Any,
    batch_id: str,
    source_name: str,
    url: str,
    status: int | None,
    latency_ms: int,
    bytes_returned: int,
    error: str | None,
) -> None:
    session.sql(
        """
        INSERT INTO OPS.API_CALL_LOG
            (BATCH_ID, SOURCE_NAME, REQUEST_URL, HTTP_STATUS, LATENCY_MS, BYTES_RETURNED, ERROR_MESSAGE)
        SELECT ?, ?, ?, ?, ?, ?, ?
        """,
        params=[batch_id, source_name, url, status, latency_ms, bytes_returned, error],
    ).collect()


def _fetch(url: str, user_agent: str, timeout: int) -> tuple[int, bytes]:
    request = urllib.request.Request(url, headers={"User-Agent": user_agent})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.status, response.read()


def main(
    session: Any,
    source_name: str,
    service_url: str,
    layer_id: int,
    raw_table: str,
    page_size: int = 1000,
    rate_limit_rps: float = 2.0,
    daily_call_cap: int = 500,
    timeout_seconds: int = 30,
    contact_email: str = "",
) -> str:
    """Ingest one ArcGIS layer into a RAW table. Returns a JSON run summary."""

    # raw_table is interpolated into SQL below because Snowflake cannot bind an
    # object name. Callers are privileged (a task or an engineer) and the value
    # comes from ingest/sources.yaml, so this is not a user-facing injection
    # path — but an identifier that reaches SQL as text gets validated anyway,
    # so a future caller cannot turn a config typo into arbitrary SQL.
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*){0,2}", raw_table):
        raise ValueError(f"raw_table is not a plain qualified identifier: {raw_table!r}")

    batch_id = str(uuid.uuid4())
    user_agent = (
        f"{DEFAULT_USER_AGENT} (+mailto:{contact_email})"
        if contact_email
        else DEFAULT_USER_AGENT
    )

    session.sql(
        "INSERT INTO RAW.INGEST_RUNS (BATCH_ID, SOURCE_NAME, STATUS) SELECT ?, ?, 'RUNNING'",
        params=[batch_id, source_name],
    ).collect()

    def finish(status: str, pages: int, landed: int, dupes: int, calls: int, err: str | None) -> str:
        session.sql(
            """
            UPDATE RAW.INGEST_RUNS
            SET FINISHED_AT = SYSDATE(), STATUS = ?, PAGES_FETCHED = ?,
                ROWS_LANDED = ?, ROWS_DUPLICATE = ?, HTTP_CALLS = ?, ERROR_MESSAGE = ?
            WHERE BATCH_ID = ?
            """,
            params=[status, pages, landed, dupes, calls, err, batch_id],
        ).collect()
        return json.dumps(
            {
                "batch_id": batch_id,
                "source": source_name,
                "status": status,
                "pages": pages,
                "rows_landed": landed,
                "rows_duplicate": dupes,
                "http_calls": calls,
                "error": err,
            }
        )

    # --- daily cap ---------------------------------------------------------
    used = _calls_used_today(session, source_name)
    if used >= daily_call_cap:
        return finish("CAP_REACHED", 0, 0, 0, 0, f"daily cap {daily_call_cap} already used ({used})")
    remaining = daily_call_cap - used

    # --- robots gate -------------------------------------------------------
    limiter = RateLimiter(rate_limit_rps)
    query_url = f"{service_url.rstrip('/')}/{layer_id}/query"

    # Check the path we will actually request, not the service root. robots.txt
    # rules are path-scoped, so a verdict for "/arcgis/rest/services" says
    # nothing about "/arcgis/rest/services/X/0/query".
    gate = RobotsGate(user_agent)
    allowed, reason = gate.allows(query_url)
    if not allowed:
        return finish("BLOCKED_BY_ROBOTS", 0, 0, 0, 0, reason)

    pages = landed = dupes = calls = 0
    consecutive_failures = 0
    offset = 0

    while pages < MAX_PAGES:
        if calls >= remaining:
            return finish("CAP_REACHED", pages, landed, dupes, calls,
                          f"daily cap {daily_call_cap} reached mid-run")

        params = urllib.parse.urlencode(
            {
                "where": "1=1",
                "outFields": "*",
                "f": "geojson",
                "outSR": "4326",
                "resultOffset": offset,
                "resultRecordCount": page_size,
            }
        )
        url = f"{query_url}?{params}"

        limiter.wait()
        started = time.monotonic()
        try:
            status, body = _fetch(url, user_agent, timeout_seconds)
            latency_ms = int((time.monotonic() - started) * 1000)
            calls += 1
            _log_call(session, batch_id, source_name, url, status, latency_ms, len(body), None)
            consecutive_failures = 0
        except Exception as exc:  # noqa: BLE001
            latency_ms = int((time.monotonic() - started) * 1000)
            calls += 1
            consecutive_failures += 1
            _log_call(session, batch_id, source_name, url, None, latency_ms, 0, str(exc))
            if consecutive_failures >= CIRCUIT_BREAKER_THRESHOLD:
                return finish("CIRCUIT_OPEN", pages, landed, dupes, calls,
                              f"{consecutive_failures} consecutive failures; last: {exc}")
            time.sleep(min(2 ** consecutive_failures, 30))
            continue

        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            return finish("FAILED", pages, landed, dupes, calls, f"unparseable response: {exc}")

        # ArcGIS reports its own errors inside a 200 response.
        if isinstance(payload, dict) and "error" in payload:
            return finish("FAILED", pages, landed, dupes, calls,
                          f"ArcGIS error: {json.dumps(payload['error'])[:400]}")

        features = payload.get("features") or []
        if not features:
            break

        payload_text = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        payload_hash = _sha256(payload_text)

        # Idempotency: an identical page from a previous run is not re-landed.
        already = session.sql(
            f"SELECT COUNT(*) AS N FROM {raw_table} WHERE _PAYLOAD_HASH = ?",  # noqa: S608
            params=[payload_hash],
        ).collect()
        if already and int(already[0]["N"]) > 0:
            dupes += len(features)
        else:
            session.sql(
                f"""
                INSERT INTO {raw_table}
                    (_SOURCE_NAME, _SOURCE_URL, _PAYLOAD_HASH, _BATCH_ID, _PAYLOAD)
                SELECT ?, ?, ?, ?, PARSE_JSON(?)
                """,  # noqa: S608 - raw_table comes from the source registry, not user input
                params=[source_name, url, payload_hash, batch_id, payload_text],
            ).collect()
            landed += len(features)

        pages += 1
        offset += page_size

        # ArcGIS signals more data with exceededTransferLimit; absence of the
        # flag alongside a short page means we have reached the end.
        exceeded = bool(payload.get("properties", {}).get("exceededTransferLimit")) or bool(
            payload.get("exceededTransferLimit")
        )
        if not exceeded and len(features) < page_size:
            break

    if pages >= MAX_PAGES:
        return finish("FAILED", pages, landed, dupes, calls,
                      f"page ceiling {MAX_PAGES} hit; paging may not be terminating")

    return finish("SUCCESS", pages, landed, dupes, calls, None)
