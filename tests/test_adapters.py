"""Unit tests for the sentiment adapters.

Concentrated on the two guarantees that would be most damaging to get wrong:

  PII stripping   Granicus minutes name the residents who spoke. Those names
                  must never reach storage. This is the test that keeps a
                  housing-analysis product from becoming a database of named
                  opinions.

  Fail-closed     An adapter that cannot verify robots.txt must refuse to fetch,
                  and one without a contact address must refuse to exist.

Run: python3 -m pytest tests/test_adapters.py -q
"""

from __future__ import annotations

import sys
import urllib.error
from datetime import datetime
from pathlib import Path

import pytest

ADAPTERS = Path(__file__).resolve().parents[1] / "ingest" / "adapters"
sys.path.insert(0, str(ADAPTERS))

from base import ComplianceError, SentimentAdapter  # noqa: E402
from granicus import GranicusAdapter  # noqa: E402
from news_rss import NewsRssAdapter  # noqa: E402

CONTACT = "test@example.com"


class TestContactRequirement:
    def test_adapter_refuses_to_construct_without_contact(self):
        with pytest.raises(ComplianceError, match="contact_email"):
            SentimentAdapter(contact_email="")

    def test_user_agent_advertises_the_contact(self):
        adapter = SentimentAdapter(contact_email=CONTACT)
        assert CONTACT in adapter.user_agent
        assert "IrvineHomeAnalysis" in adapter.user_agent


class TestRobotsFailClosed:
    def _adapter(self, monkeypatch, side_effect):
        adapter = SentimentAdapter(contact_email=CONTACT)
        monkeypatch.setattr("base.urllib.request.urlopen", side_effect)
        return adapter

    def test_missing_robots_is_permissive(self, monkeypatch):
        def raise_404(*_a, **_k):
            raise urllib.error.HTTPError("u", 404, "Not Found", {}, None)

        adapter = self._adapter(monkeypatch, raise_404)
        assert adapter.may_fetch("https://example.org/page") is True

    def test_unreadable_robots_refuses(self, monkeypatch):
        def raise_500(*_a, **_k):
            raise urllib.error.HTTPError("u", 500, "Error", {}, None)

        adapter = self._adapter(monkeypatch, raise_500)
        with pytest.raises(ComplianceError, match="refusing to fetch"):
            adapter.may_fetch("https://example.org/page")

    def test_disallow_is_honoured(self, monkeypatch):
        class Resp:
            def read(self):
                return b"User-agent: *\nDisallow: /private/\n"

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

        adapter = self._adapter(monkeypatch, lambda *_a, **_k: Resp())
        assert adapter.may_fetch("https://example.org/private/x") is False
        assert adapter.may_fetch("https://example.org/public/x") is True

    def test_site_crawl_delay_overrides_our_faster_default(self, monkeypatch):
        class Resp:
            def read(self):
                return b"User-agent: *\nCrawl-delay: 30\nAllow: /\n"

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

        adapter = SentimentAdapter(contact_email=CONTACT, rate_limit_rps=1.0)
        monkeypatch.setattr("base.urllib.request.urlopen", lambda *_a, **_k: Resp())
        # Our default would be 1s; the site asks for 30 and the site wins.
        assert adapter.crawl_delay("https://example.org/x") == 30.0


class TestGranicusPiiStripping:
    """Speaker names must not survive into a stored document."""

    def test_speaker_attribution_is_removed(self):
        raw = "Sarah Whitfield, a resident of Orchard Hills, objected to the noise."
        cleaned = GranicusAdapter.strip_names(raw)
        assert "Sarah Whitfield" not in cleaned
        assert "Whitfield" not in cleaned

    def test_titled_speakers_are_removed(self):
        raw = "Commissioner Daniel Reyes asked about the traffic study."
        cleaned = GranicusAdapter.strip_names(raw)
        assert "Daniel Reyes" not in cleaned

    def test_substance_survives_stripping(self):
        raw = "Margaret Coleman, resident, said construction noise on Sand Canyon "
        raw += "has continued for two years."
        cleaned = GranicusAdapter.strip_names(raw)
        assert "construction noise" in cleaned
        assert "Sand Canyon" in cleaned
        assert "two years" in cleaned

    @pytest.mark.parametrize(
        "text,token",
        [
            ("Noise on Sand Canyon has continued.", "Sand Canyon"),
            ("Residents of Orchard Hills attended.", "Orchard Hills"),
            ("Northwood High students reported odour.", "Northwood High"),
            ("The Planning Commission voted.", "Planning Commission"),
            ("Construction near Great Park continues.", "Great Park"),
        ],
    )
    def test_place_names_survive_redaction(self, text, token):
        """Over-redaction is its own failure: a complaint about construction noise
        is worthless once the street name has been stripped out of it."""
        assert token in GranicusAdapter.strip_names(text)

    @pytest.mark.parametrize(
        "text,token",
        [
            ("Sarah Whitfield objected to the plan.", "Whitfield"),
            ("Daniel Reyes asked about traffic.", "Reyes"),
            ("Michael Torres of Great Park spoke about Portola Springs.", "Torres"),
            # Each of the following leaked through the first implementation and
            # was found by independent review. [review]
            ("Maria Elena Rodriguez objected.", "Rodriguez"),
            ("Mr. Smith objected to the noise.", "Smith"),
            ("Mrs. Chen asked about traffic.", "Chen"),
            ("Dr. Patel raised health concerns.", "Patel"),
            ("Susan May spoke about traffic.", "Susan May"),
            ("Jose Garcia-Lopez asked a question.", "Lopez"),
        ],
    )
    def test_person_names_are_still_redacted(self, text, token):
        """Place-awareness must not become a loophole for real names."""
        assert token not in GranicusAdapter.strip_names(text)

    @pytest.mark.parametrize(
        "text,token",
        [
            ("The Irvine City Council approved it.", "City Council"),
            ("Great Park Neighborhoods expanded.", "Great Park Neighborhoods"),
            ("Portola Springs residents objected.", "Portola Springs"),
        ],
    )
    def test_institutions_and_multiword_places_survive(self, text, token):
        assert token in GranicusAdapter.strip_names(text)

    def test_emitted_document_has_no_author_field(self):
        adapter = GranicusAdapter(contact_email=CONTACT)
        doc = adapter.emit_document(
            text="Residents raised concerns about the widening.",
            url="https://irvine.granicus.com/x",
            published_at=datetime(2026, 3, 1),
            village_hint="ORCHARD_HILLS",
        )
        # The dataclass must not carry an author at all — absence by design,
        # not by remembering to leave it blank.
        assert not hasattr(doc, "author")
        assert "author" not in doc.as_row()

    def test_document_id_is_stable_for_identical_input(self):
        adapter = GranicusAdapter(contact_email=CONTACT)
        args = dict(
            text="Same text",
            url="https://irvine.granicus.com/x",
            published_at=datetime(2026, 3, 1),
            village_hint="WOODBRIDGE",
        )
        # Stability is what stops the same document being re-scored, which is
        # the difference between pennies and dollars in Cortex spend.
        assert adapter.emit_document(**args).document_id == adapter.emit_document(**args).document_id


class TestGranicusParsing:
    def test_public_comment_section_is_isolated(self):
        raw = (
            "CALL TO ORDER. Roll call taken.\n"
            "PUBLIC COMMENT\n"
            "A resident described sustained construction noise near the school "
            "and asked the Commission to restrict working hours.\n"
            "MOTION to approve carried 4-1.\n"
        )
        chunks = list(GranicusAdapter._public_comment_chunks(raw))
        assert chunks, "public comment section should be found"
        joined = " ".join(chunks)
        assert "construction noise" in joined
        assert "carried 4-1" not in joined, "procedural vote text should be excluded"

    def test_meeting_date_extracted(self):
        assert GranicusAdapter._extract_date("Minutes of March 5, 2026 meeting") == datetime(2026, 3, 5)

    def test_missing_date_returns_none(self):
        assert GranicusAdapter._extract_date("no date here") is None


class TestGranicusLinkPinning:
    """Hrefs come from a page we fetched, so they are untrusted input.

    An unpinned extractor would follow whatever the remote document contained —
    server-side request forgery driven by the page itself. [security-review]
    """

    HTML = (
        '<a href="/MinutesViewer.php?id=1">rel</a>'
        '<a href="https://irvine.granicus.com/minutes/2">same-origin</a>'
        '<a href="//evil.example.com/minutes/x">offsite</a>'
        '<a href="http://169.254.169.254/minutes">metadata host</a>'
        '<a href="javascript:alert(1)//minutes">javascript</a>'
        '<a href="http://irvine.granicus.com/minutes/3">http downgrade</a>'
    )

    def _links(self):
        return list(GranicusAdapter(contact_email=CONTACT)._minutes_links(self.HTML))

    def test_same_origin_links_are_followed(self):
        links = self._links()
        assert any("MinutesViewer.php?id=1" in u for u in links)
        assert any(u.endswith("/minutes/2") for u in links)

    @pytest.mark.parametrize(
        "forbidden", ["evil.example.com", "169.254.169.254", "javascript:"]
    )
    def test_offsite_and_scheme_abuse_rejected(self, forbidden):
        assert not any(forbidden in u for u in self._links())

    def test_every_link_is_https_on_the_expected_host(self):
        for url in self._links():
            assert url.startswith("https://irvine.granicus.com/")


class TestNewsRssParsing:
    FEED = b"""<?xml version="1.0"?>
    <rss version="2.0"><channel>
      <item>
        <title>Portola Springs residents question new arterial plan</title>
        <description>Dozens attended the hearing over the proposed widening.</description>
        <link>https://example.org/a</link>
        <pubDate>Tue, 03 Mar 2026 10:00:00 GMT</pubDate>
      </item>
      <item>
        <title>County budget approved</title>
        <description>No Irvine village named here at all.</description>
        <link>https://example.org/b</link>
        <pubDate>Tue, 03 Mar 2026 11:00:00 GMT</pubDate>
      </item>
    </channel></rss>"""

    def test_village_tagged_item_is_kept(self):
        adapter = NewsRssAdapter(CONTACT, "voice_of_oc", "https://example.org/feed")
        docs = list(adapter.parse(self.FEED, "https://example.org/feed"))
        assert len(docs) == 1
        assert docs[0].village_hint == "PORTOLA_SPRINGS"
        assert "arterial" in docs[0].document_text

    def test_item_naming_no_village_is_dropped(self):
        """Regional coverage cannot inform a village score, so it is not stored."""
        adapter = NewsRssAdapter(CONTACT, "voice_of_oc", "https://example.org/feed")
        texts = [d.document_text for d in adapter.parse(self.FEED, "https://example.org/feed")]
        assert not any("budget approved" in t for t in texts)

    def test_publication_date_parsed(self):
        adapter = NewsRssAdapter(CONTACT, "voice_of_oc", "https://example.org/feed")
        doc = next(iter(adapter.parse(self.FEED, "https://example.org/feed")))
        assert doc.published_at is not None
        assert doc.published_at.year == 2026


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
