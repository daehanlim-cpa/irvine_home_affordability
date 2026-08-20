"""Shared adapter contract for sentiment sources.

Every non-ArcGIS source implements `SentimentAdapter`. The base class owns the
parts that must not vary by source — robots.txt compliance, rate limiting,
User-Agent identification, and PII stripping — so a new adapter cannot
accidentally omit one. Subclasses supply only parsing.

The PII rule is enforced here rather than trusted to each adapter:
`emit_document` accepts text, URL, timestamp, and village, and there is no
parameter for an author. Granicus minutes name the residents who spoke, news
carries bylines, forums carry usernames. None of it is needed to score how a
neighbourhood is discussed, and storing it would turn a housing-analysis product
into a database of named opinions.
"""

from __future__ import annotations

import hashlib
import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser
from dataclasses import dataclass
from datetime import datetime
from typing import Iterator


@dataclass(frozen=True)
class SentimentDocument:
    """One unit of community signal. Deliberately carries no author field."""

    document_id: str
    source_name: str
    village_hint: str | None
    document_url: str
    published_at: datetime | None
    document_text: str

    def as_row(self) -> dict:
        return {
            "document_id": self.document_id,
            "source_name": self.source_name,
            "village": self.village_hint,
            "url": self.document_url,
            "published_at": self.published_at.isoformat() if self.published_at else None,
            "text": self.document_text,
        }


class ComplianceError(RuntimeError):
    """Raised when a source may not be fetched. Never caught to proceed anyway."""


class SentimentAdapter:
    """Base adapter. Subclasses implement `parse`, never `fetch`."""

    source_name: str = "unset"
    base_url: str = ""

    def __init__(self, contact_email: str, rate_limit_rps: float = 0.2,
                 daily_call_cap: int = 200) -> None:
        if not contact_email:
            # A crawler that cannot be contacted is not a polite crawler. This is
            # a hard requirement, not a nicety: a site owner must have a way to
            # reach a human without having to block an IP range first.
            raise ComplianceError(
                "contact_email is required. Set CRAWLER_CONTACT_EMAIL so the "
                "User-Agent advertises a reachable address."
            )
        self.contact_email = contact_email
        self.user_agent = f"IrvineHomeAnalysis/1.0 (+mailto:{contact_email})"
        self.min_interval = 1.0 / rate_limit_rps if rate_limit_rps > 0 else 0.0
        self.daily_call_cap = daily_call_cap
        self._calls_made = 0
        self._last_request = 0.0
        self._robots: dict[str, urllib.robotparser.RobotFileParser | None] = {}

    # --- compliance --------------------------------------------------------

    def _robots_for(self, url: str) -> urllib.robotparser.RobotFileParser | None:
        parsed = urllib.parse.urlparse(url)
        origin = f"{parsed.scheme}://{parsed.netloc}"
        if origin in self._robots:
            return self._robots[origin]

        parser = urllib.robotparser.RobotFileParser()
        try:
            req = urllib.request.Request(
                f"{origin}/robots.txt", headers={"User-Agent": self.user_agent}
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                parser.parse(resp.read().decode("utf-8", errors="replace").splitlines())
            self._robots[origin] = parser
        except urllib.error.HTTPError as exc:
            if exc.code in (404, 410):
                self._robots[origin] = None  # no robots.txt means no restrictions
            else:
                raise ComplianceError(
                    f"robots.txt for {origin} returned HTTP {exc.code}; cannot establish "
                    "permission to crawl, so refusing to fetch."
                ) from exc
        except Exception as exc:  # noqa: BLE001
            raise ComplianceError(
                f"robots.txt for {origin} could not be retrieved ({exc}); refusing to fetch."
            ) from exc

        return self._robots[origin]

    def may_fetch(self, url: str) -> bool:
        parser = self._robots_for(url)
        if parser is None:
            return True
        return parser.can_fetch(self.user_agent, url)

    def crawl_delay(self, url: str) -> float:
        """Honour the site's own Crawl-delay when it asks for more than our default."""
        parser = self._robots_for(url)
        if parser is None:
            return self.min_interval
        declared = parser.crawl_delay(self.user_agent)
        return max(self.min_interval, float(declared)) if declared else self.min_interval

    # --- fetching ----------------------------------------------------------

    def fetch(self, url: str, timeout: int = 30) -> bytes:
        if self._calls_made >= self.daily_call_cap:
            raise ComplianceError(
                f"{self.source_name}: daily call cap of {self.daily_call_cap} reached."
            )
        if not self.may_fetch(url):
            raise ComplianceError(f"{self.source_name}: robots.txt disallows {url}")

        delay = self.crawl_delay(url)
        elapsed = time.monotonic() - self._last_request
        if elapsed < delay:
            time.sleep(delay - elapsed)

        req = urllib.request.Request(url, headers={"User-Agent": self.user_agent})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()

        self._last_request = time.monotonic()
        self._calls_made += 1
        return body

    # --- document construction --------------------------------------------

    def emit_document(
        self,
        text: str,
        url: str,
        published_at: datetime | None,
        village_hint: str | None,
    ) -> SentimentDocument:
        """Build a document. Note there is no author parameter, by design."""
        digest = hashlib.sha256(
            f"{self.source_name}|{url}|{text}".encode("utf-8")
        ).hexdigest()
        return SentimentDocument(
            document_id=digest,
            source_name=self.source_name,
            village_hint=village_hint,
            document_url=url,
            published_at=published_at,
            document_text=" ".join(text.split()),
        )

    # --- subclass contract -------------------------------------------------

    def parse(self, payload: bytes, url: str) -> Iterator[SentimentDocument]:
        raise NotImplementedError

    def collect(self) -> Iterator[SentimentDocument]:
        raise NotImplementedError
