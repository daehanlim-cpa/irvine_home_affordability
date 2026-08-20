"""Report the layers inside an ArcGIS service, so layer IDs stop being guesses.

Handler for RAW.SP_DISCOVER_LAYERS. Runs inside Snowflake over
EAI_GOV_SOURCES, which is the one place in this project that can actually
reach gis.cityofirvine.org.

The registry originally assumed layer 0 for everything. That assumption was
wrong at least once — pointing the geocoder at a polygon layer makes every
address resolve to NOT_FOUND, and the symptom appears three layers downstream
from the cause. This turns that into a fact you can read.
"""

from __future__ import annotations

import json
import urllib.parse
import urllib.request
import urllib.robotparser
from typing import Any

USER_AGENT = "IrvineHomeAnalysis/1.0 (+layer-discovery)"


def _robots_allows(url: str) -> bool:
    """Same fail-closed robots gate the ingest path uses."""
    parsed = urllib.parse.urlparse(url)
    origin = f"{parsed.scheme}://{parsed.netloc}"
    parser = urllib.robotparser.RobotFileParser()
    try:
        req = urllib.request.Request(
            f"{origin}/robots.txt", headers={"User-Agent": USER_AGENT}
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            parser.parse(resp.read().decode("utf-8", errors="replace").splitlines())
        return parser.can_fetch(USER_AGENT, url)
    except Exception as exc:  # noqa: BLE001
        message = str(exc)
        # A genuine 404 means no restrictions; anything else is unverified.
        return "404" in message or "410" in message


def main(session: Any, service_url: str) -> str:
    base = service_url.rstrip("/")
    url = f"{base}?f=json"

    if not _robots_allows(url):
        return json.dumps({"service": base, "error": "robots.txt disallows or could not be verified"})

    try:
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"service": base, "error": str(exc)})

    if "error" in payload:
        return json.dumps({"service": base, "error": payload["error"]})

    def describe(entries: list[dict], kind: str) -> list[dict]:
        return [
            {
                "kind": kind,
                "id": e.get("id"),
                "name": e.get("name"),
                "geometry": e.get("geometryType"),
                "type": e.get("type"),
            }
            for e in entries or []
        ]

    return json.dumps(
        {
            "service": base,
            "description": (payload.get("serviceDescription") or "")[:200],
            "layers": describe(payload.get("layers"), "layer"),
            "tables": describe(payload.get("tables"), "table"),
        },
        indent=2,
    )
