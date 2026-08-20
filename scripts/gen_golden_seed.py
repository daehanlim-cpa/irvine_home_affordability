#!/usr/bin/env python3
"""Generate the golden-address seed SQL from the YAML fixture.

tests/fixtures/golden_addresses.yaml stays the source of truth — it is where a
human edits addresses and expectations. This renders it into
tests/seed_golden_addresses.sql so the deploy runner can load it, and so the
two can be checked for drift rather than hand-maintained in parallel.

Run: python3 scripts/gen_golden_seed.py
Verified by scripts/verify.sh, which regenerates and fails if the checked-in
SQL no longer matches the YAML.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "fixtures" / "golden_addresses.yaml"
OUTPUT = ROOT / "tests" / "seed_golden_addresses.sql"

PLACEHOLDER = "<REPLACE"

HEADER = """\
-- =============================================================================
-- seed_golden_addresses.sql
--
-- GENERATED FILE — do not edit by hand.
-- Source: tests/fixtures/golden_addresses.yaml
-- Regenerate: python3 scripts/gen_golden_seed.py
--
-- Loads the regression fixtures and resolves each to a parcel. Resolution
-- happens here rather than being hard-coded, so the seed exercises the same
-- geocoder the product uses: if address matching regresses, these rows stop
-- resolving and the golden tests report it.
-- =============================================================================

USE ROLE IHA_ENGINEER;
USE DATABASE IRVINE_HOME_ANALYSIS;
USE SCHEMA MART;

"""

FOOTER = """
-- Resolve each fixture to a parcel using the product's own resolver. A fixture
-- that fails to resolve leaves APN NULL, and tests/test_scoring.sql reports
-- that as a FAIL on "resolves:<id>" rather than skipping quietly.
UPDATE MART.GOLDEN_ADDRESSES AS GOLD
SET APN = RESOLVED.APN
FROM (
    SELECT
        SRC.GOLDEN_ID,
        RES.APN
    FROM MART.GOLDEN_ADDRESSES AS SRC,
        LATERAL TABLE(APP.FN_RESOLVE_ADDRESS(SRC.RAW_ADDRESS)) AS RES
    WHERE RES.MATCH_CONFIDENCE IN ('EXACT', 'FUZZY')
) AS RESOLVED
WHERE GOLD.GOLDEN_ID = RESOLVED.GOLDEN_ID;

-- Report what landed, so a deploy shows resolution health immediately.
SELECT
    GOLDEN_ID,
    RAW_ADDRESS,
    VILLAGE_EXPECTED,
    COALESCE(APN, '<unresolved>') AS APN,
    IFF(APN IS NULL, 'FAIL', 'PASS') AS STATUS,
    'Golden fixture must resolve to a parcel for its assertions to run.' AS DETAIL
FROM MART.GOLDEN_ADDRESSES
ORDER BY GOLDEN_ID;
"""


def sql_quote(value: str) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def main() -> int:
    doc = yaml.safe_load(FIXTURE.read_text())
    rows = doc.get("golden_addresses") or []
    if not rows:
        print("no golden_addresses in fixture", file=sys.stderr)
        return 1

    unfilled = [r["id"] for r in rows if PLACEHOLDER in str(r.get("address", ""))]
    if unfilled:
        print(
            "Placeholder addresses still present: "
            + ", ".join(unfilled)
            + "\nReplace them with real Irvine addresses before generating the seed.",
            file=sys.stderr,
        )
        return 1

    values = []
    for row in rows:
        expectations = dict(row.get("expect") or {})
        # Phase-2 expectations are carried through so they are visible in the
        # database, but the test view only asserts on the active `expect` block.
        if row.get("expect_pending_phase_2"):
            expectations["_pending_phase_2"] = row["expect_pending_phase_2"]

        values.append(
            "        ("
            + ", ".join(
                [
                    sql_quote(row["id"]),
                    sql_quote(row["address"]),
                    sql_quote(row["village_expected"]),
                    f"PARSE_JSON({sql_quote(json.dumps(expectations))})",
                    sql_quote(" ".join(str(row.get("rationale", "")).split())),
                ]
            )
            + ")"
        )

    merge = (
        "MERGE INTO MART.GOLDEN_ADDRESSES AS TGT\n"
        "USING (\n"
        "    SELECT\n        *\n    FROM VALUES\n"
        + ",\n".join(values)
        + "\n    AS SRC (GOLDEN_ID, RAW_ADDRESS, VILLAGE_EXPECTED, EXPECTATIONS, RATIONALE)\n"
        ") AS SRC\n"
        "ON TGT.GOLDEN_ID = SRC.GOLDEN_ID\n"
        "WHEN MATCHED THEN UPDATE SET\n"
        "    TGT.RAW_ADDRESS = SRC.RAW_ADDRESS,\n"
        "    TGT.VILLAGE_EXPECTED = SRC.VILLAGE_EXPECTED,\n"
        "    TGT.EXPECTATIONS = SRC.EXPECTATIONS,\n"
        "    TGT.RATIONALE = SRC.RATIONALE\n"
        "WHEN NOT MATCHED THEN INSERT\n"
        "    (GOLDEN_ID, RAW_ADDRESS, VILLAGE_EXPECTED, EXPECTATIONS, RATIONALE)\n"
        "VALUES\n"
        "    (SRC.GOLDEN_ID, SRC.RAW_ADDRESS, SRC.VILLAGE_EXPECTED,\n"
        "     SRC.EXPECTATIONS, SRC.RATIONALE);\n"
    )

    OUTPUT.write_text(HEADER + merge + FOOTER)

    # Normalise through sqlfluff so generation is idempotent. Without this the
    # formatter rewrites the file after generation and the next run reports
    # spurious drift — a drift check that cries wolf gets ignored.
    if shutil.which("sqlfluff"):
        subprocess.run(
            ["sqlfluff", "fix", "--dialect", "snowflake", "--force", str(OUTPUT)],
            capture_output=True,
            check=False,
        )

    print(f"wrote {OUTPUT.relative_to(ROOT)} ({len(rows)} fixtures)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
