"""Granicus adapter: Irvine City Council and Planning Commission minutes.

The highest-credibility sentiment source available and effectively unmined by
competitors. Residents testify on the record, by name, about the specific
development next to a given parcel — which is simultaneously community sentiment
and construction intelligence.

Names are the thing this adapter is most careful about. Minutes attribute
statements to named residents; those names are stripped before a document is
emitted. What matters for scoring is that concerns were raised about a project,
not who raised them.

robots.txt and rate limiting are handled by the base class. Granicus is a shared
vendor platform serving many municipalities, so the configured rate (one request
per five seconds) sits well below the default.
"""

from __future__ import annotations

import re
import urllib.parse
from datetime import datetime
from typing import Iterator

from base import SentimentAdapter, SentimentDocument

# --- name redaction -----------------------------------------------------------
#
# Rewritten after review found three leaks in a naive two-capitalised-words
# regex: "Maria Elena Rodriguez" left a surname behind, "Mr. Smith" was missed
# entirely, and "Susan May" was whitelisted because "May" is a month.
#
# The shape that works: match name-shaped SPANS (1-4 capitalised tokens, with
# titles and hyphens), then decide per span whether it reads as a person or a
# place. Deciding on the whole span rather than on any single word is what stops
# a calendar or place word in one position from excusing the rest.

TITLE = (
    r"(?:Mr|Mrs|Ms|Dr|Prof|Commissioner|Councilmember|Councilman|Councilwoman"
    r"|Mayor|Chairman|Chairwoman|Chair|Director|Supervisor)\.?"
)
NAME_WORD = r"[A-Z][a-zA-Z'\u2019]+(?:-[A-Z][a-zA-Z'\u2019]+)?"

# A title always introduces a person, however many name words follow.
TITLED_NAME = re.compile(rf"\b{TITLE}\s+(?:{NAME_WORD}\s+){{0,2}}{NAME_WORD}\b")

# Two to four capitalised words: a person or a place, decided by _is_place.
BARE_NAME = re.compile(rf"\b(?:{NAME_WORD}\s+){{1,3}}{NAME_WORD}\b")

# Speaker attribution lines: "Name, resident, said ..." / "Name - ..."
# The delimiter requires whitespace around dash forms. A bare hyphen also
# appears INSIDE hyphenated surnames, and matching it there split
# "Garcia-Lopez" and left the surname in the text.
SPEAKER_LINE = re.compile(
    rf"^\s*(?:{TITLE}\s+)?(?:{NAME_WORD}\s+){{0,2}}{NAME_WORD}\s*(?:,\s|:\s|\s[-\u2013]\s)",
    re.MULTILINE,
)

# Checked against the LAST word of a span: these end place names.
PLACE_SUFFIX = frozenset(
    {
        "canyon", "park", "parks", "village", "villages", "neighborhoods",
        "neighbourhoods", "hills", "hill", "creek", "springs", "ridge", "rock",
        "grove", "bay", "lake", "lakes", "mesa", "vista", "valley", "meadow",
        "meadows", "drive", "road", "street", "avenue", "boulevard", "lane",
        "way", "court", "circle", "trail", "trails", "parkway", "plaza",
        "center", "centre", "square", "crossing", "gate", "gateway", "point",
        "view", "ranch", "wood", "woods", "canyons", "heights", "terrace",
        "high", "elementary", "middle", "school", "college", "university",
        "library", "complex", "district", "preserve", "reserve",
    }
)

# Checked against ANY word: these mark an institution rather than a person.
INSTITUTION_WORD = frozenset(
    {
        "commission", "council", "department", "committee", "board", "agency",
        "authority", "association", "corporation", "company", "communities",
        "properties", "development", "district", "city", "county", "state",
        "unified", "planning", "irvine", "orange", "california", "usa",
        "homeowners", "hoa", "llc", "inc", "corp",
    }
)

MONTHS = frozenset(
    {
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    }
)


def _is_place(span: str) -> bool:
    """True when a capitalised span reads as a place or institution.

    Over-redaction is its own failure: a complaint about construction noise is
    worthless once the street name has been stripped out of it. But the test is
    deliberately narrow — a place SUFFIX in final position, or an institution
    word anywhere — so that "Susan May" is still treated as a person.
    """
    words = [w.strip(".,;:").lower() for w in span.split() if w.strip(".,;:")]
    if not words:
        return False
    if words[-1] in PLACE_SUFFIX:
        return True
    return any(w in INSTITUTION_WORD for w in words)


def _is_date(span: str, text: str, end: int) -> bool:
    """A month name followed by a number is a date, not a person."""
    words = [w.strip(".,;:").lower() for w in span.split()]
    if not any(w in MONTHS for w in words):
        return False
    return bool(re.match(r"\s*\d", text[end:end + 6]))


AGENDA_ITEM = re.compile(r"(?:Agenda\s+Item|ITEM)\s*(?:No\.?)?\s*([0-9]+[A-Za-z]?)", re.I)


class GranicusAdapter(SentimentAdapter):
    source_name = "irvine_granicus_minutes"
    base_url = "https://irvine.granicus.com"

    def __init__(self, contact_email: str, view_id: int = 81, **kwargs) -> None:
        super().__init__(contact_email, **kwargs)
        self.view_id = view_id

    def index_url(self) -> str:
        return f"{self.base_url}/ViewPublisher.php?view_id={self.view_id}"

    # ------------------------------------------------------------------ PII

    @staticmethod
    def strip_names(text: str) -> str:
        """Remove personal names. Runs before anything is stored."""

        def replace_bare(match: re.Match[str]) -> str:
            span = match.group(0)
            if _is_place(span) or _is_date(span, match.string, match.end()):
                return span
            return "[speaker]"

        # Titles first: a titled name is always a person, and matching it before
        # the bare pattern stops "Mr. Smith" falling through as a single word.
        text = TITLED_NAME.sub("[speaker]", text)
        text = SPEAKER_LINE.sub("", text)
        return BARE_NAME.sub(replace_bare, text)

    # --------------------------------------------------------------- parsing

    def parse(self, payload: bytes, url: str) -> Iterator[SentimentDocument]:
        raw = payload.decode("utf-8", errors="replace")
        meeting_date = self._extract_date(raw)
        village = self._infer_village(raw)

        for chunk in self._public_comment_chunks(raw):
            cleaned = self.strip_names(chunk).strip()
            # Very short fragments are procedural noise ("So moved.", "Aye.")
            # and add nothing but cost when sent to a model.
            if len(cleaned) < 80:
                continue
            yield self.emit_document(
                text=cleaned,
                url=url,
                published_at=meeting_date,
                village_hint=village,
            )

    @staticmethod
    def _public_comment_chunks(raw: str) -> Iterator[str]:
        """Isolate the public-comment portions of a minutes document.

        Council minutes are mostly procedure. The resident testimony is the
        signal, and it sits between the public-comment heading and the vote.
        """
        lowered = raw.lower()
        start_markers = ("public comment", "public hearing", "public testimony")
        end_markers = ("motion", "roll call", "vote:", "adjourn")

        cursor = 0
        while True:
            starts = [lowered.find(m, cursor) for m in start_markers]
            starts = [s for s in starts if s != -1]
            if not starts:
                return
            begin = min(starts)
            ends = [lowered.find(m, begin + 1) for m in end_markers]
            ends = [e for e in ends if e != -1]
            finish = min(ends) if ends else len(raw)
            yield raw[begin:finish]
            cursor = finish + 1

    @staticmethod
    def _extract_date(raw: str) -> datetime | None:
        match = re.search(r"([A-Z][a-z]+ \d{1,2}, \d{4})", raw)
        if not match:
            return None
        try:
            return datetime.strptime(match.group(1), "%B %d, %Y")
        except ValueError:
            return None

    @staticmethod
    def _infer_village(raw: str) -> str | None:
        """Tie a document to a village by name mention.

        Minutes rarely tag a village explicitly, so the first mentioned village
        name is used. Documents that resolve to no village are dropped
        downstream rather than assigned to a default — a misattributed comment
        is worse than a missing one.
        """
        from village_names import VILLAGE_ALIASES_BY_LENGTH  # local table, no network

        lowered = raw.lower()
        best: tuple[int, str] | None = None
        for alias, code in VILLAGE_ALIASES_BY_LENGTH.items():
            pos = lowered.find(alias.lower())
            if pos != -1 and (best is None or pos < best[0]):
                best = (pos, code)
        return best[1] if best else None

    def collect(self) -> Iterator[SentimentDocument]:
        index = self.fetch(self.index_url())
        for doc_url in self._minutes_links(index.decode("utf-8", errors="replace")):
            try:
                payload = self.fetch(doc_url)
            except Exception:  # noqa: BLE001 - one bad document must not stop the run
                continue
            yield from self.parse(payload, doc_url)

    def _minutes_links(self, index_html: str) -> Iterator[str]:
        """Extract minutes links, pinned to this adapter's own origin.

        The hrefs come from a page we fetched, so they are untrusted input. An
        unpinned version would follow a protocol-relative "//elsewhere/minutes"
        or an absolute "http://internal-host/minutes" straight out of the
        document — server-side request forgery driven by whatever the remote
        page happens to contain.

        Snowflake's egress allowlist would refuse those in production, but this
        adapter is ordinary Python that can run anywhere, so the constraint
        belongs here too rather than resting on one layer.
        """
        expected = urllib.parse.urlparse(self.base_url).netloc.lower()

        for match in re.finditer(r'href="([^"]*(?:MinutesViewer|minutes)[^"]*)"', index_html, re.I):
            href = match.group(1).strip()
            if href.startswith("//"):
                href = "https:" + href
            elif href.startswith("/"):
                href = self.base_url + href
            elif not href.lower().startswith(("http://", "https://")):
                continue  # relative or javascript:/data: — not a document link

            parsed = urllib.parse.urlparse(href)
            if parsed.scheme != "https":
                continue
            if parsed.netloc.lower() != expected:
                continue
            yield href
