"""RSS adapter for local journalism.

Headline, link, date, and summary only. Full article text is neither stored nor
redistributed — the report links back to the publisher, which is both the
correct copyright posture and better for the reader.

Bylines are not stored. Who wrote a piece does not affect what the public record
shows about a neighbourhood.
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from datetime import datetime
from email.utils import parsedate_to_datetime
from typing import Iterator

from base import SentimentAdapter, SentimentDocument

TAG_STRIP = re.compile(r"<[^>]+>")


class NewsRssAdapter(SentimentAdapter):
    """Generic RSS/Atom reader. One instance per publication."""

    def __init__(self, contact_email: str, source_name: str, feed_url: str, **kwargs) -> None:
        super().__init__(contact_email, **kwargs)
        self.source_name = source_name
        self.feed_url = feed_url
        self.base_url = feed_url

    def parse(self, payload: bytes, url: str) -> Iterator[SentimentDocument]:
        try:
            root = ET.fromstring(payload)
        except ET.ParseError:
            return

        # RSS 2.0 and Atom in one pass.
        items = root.findall(".//item") or root.findall(
            ".//{http://www.w3.org/2005/Atom}entry"
        )

        for item in items:
            title = self._text(item, "title")
            summary = self._text(item, "description") or self._text(item, "summary")
            link = self._link(item)
            published = self._published(item)

            body = " ".join(filter(None, [title, summary])).strip()
            if len(body) < 60:
                continue

            village = self._infer_village(body)
            if village is None:
                # Regional coverage that names no Irvine village cannot inform a
                # village score.
                continue

            yield self.emit_document(
                text=body, url=link or url, published_at=published, village_hint=village
            )

    @staticmethod
    def _text(item: ET.Element, tag: str) -> str | None:
        for candidate in (tag, f"{{http://www.w3.org/2005/Atom}}{tag}"):
            found = item.find(candidate)
            if found is not None and found.text:
                return TAG_STRIP.sub(" ", found.text).strip()
        return None

    @staticmethod
    def _link(item: ET.Element) -> str | None:
        found = item.find("link")
        if found is not None:
            if found.text:
                return found.text.strip()
            href = found.get("href")
            if href:
                return href
        atom = item.find("{http://www.w3.org/2005/Atom}link")
        return atom.get("href") if atom is not None else None

    @staticmethod
    def _published(item: ET.Element) -> datetime | None:
        for tag in ("pubDate", "published", "updated"):
            raw = NewsRssAdapter._text(item, tag)
            if not raw:
                continue
            try:
                return parsedate_to_datetime(raw)
            except (TypeError, ValueError):
                try:
                    return datetime.fromisoformat(raw.replace("Z", "+00:00"))
                except ValueError:
                    continue
        return None

    @staticmethod
    def _infer_village(text: str) -> str | None:
        # Longest alias first. Insertion order meant "Great Park ... near
        # Northwood" resolved to NORTHWOOD purely because of dict ordering.
        # VILLAGE_ALIASES_BY_LENGTH exists for this and was never imported.
        from village_names import VILLAGE_ALIASES_BY_LENGTH

        lowered = text.lower()
        best: tuple[int, str] | None = None
        for alias, code in VILLAGE_ALIASES_BY_LENGTH.items():
            pos = lowered.find(alias.lower())
            if pos != -1 and (best is None or pos < best[0]):
                best = (pos, code)
        return best[1] if best else None

    def collect(self) -> Iterator[SentimentDocument]:
        payload = self.fetch(self.feed_url)
        yield from self.parse(payload, self.feed_url)
