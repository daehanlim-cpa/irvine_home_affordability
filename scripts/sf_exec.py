#!/usr/bin/env python3
"""Execute a .sql file against Snowflake using snowflake-connector-python.

Fallback for environments without the `snow` CLI. requirements-dev.txt pins the
connector but not the CLI, so without this the verification gate would report
"command not found" for every Snowflake check.

Credentials come from the environment (see .env.example). Key-pair auth is
preferred; password auth is supported for convenience.

Exit codes:
    0  all statements executed and no result row contained the token FAIL
    1  a statement raised, or a result row contained FAIL
    2  configuration/connection problem (reported as a skip-worthy condition)
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

# Split on semicolons that end a statement, while leaving $$-quoted bodies
# (Snowflake Scripting blocks) intact — they contain semicolons of their own.
_DOLLAR_BLOCK = re.compile(r"\$\$.*?\$\$", re.DOTALL)


def split_statements(sql: str) -> list[str]:
    placeholders: list[str] = []

    def stash(match: re.Match[str]) -> str:
        placeholders.append(match.group(0))
        return f"__SF_BLOCK_{len(placeholders) - 1}__"

    masked = _DOLLAR_BLOCK.sub(stash, sql)
    parts = [p.strip() for p in masked.split(";")]

    out = []
    for part in parts:
        if not part:
            continue
        for i, block in enumerate(placeholders):
            part = part.replace(f"__SF_BLOCK_{i}__", block)
        # Drop statements that are only comments.
        if all(
            line.strip().startswith("--") or not line.strip()
            for line in part.splitlines()
        ):
            continue
        out.append(part)
    return out


def connect():
    try:
        import snowflake.connector
    except ImportError:
        print("snowflake-connector-python is not installed", file=sys.stderr)
        sys.exit(2)

    account = os.environ.get("SNOWFLAKE_ACCOUNT")
    user = os.environ.get("SNOWFLAKE_USER")
    if not account or not user:
        print("SNOWFLAKE_ACCOUNT and SNOWFLAKE_USER must be set", file=sys.stderr)
        sys.exit(2)

    kwargs = {
        "account": account,
        "user": user,
        "role": os.environ.get("SNOWFLAKE_ROLE", "IHA_ENGINEER"),
        "warehouse": os.environ.get("SNOWFLAKE_WAREHOUSE", "IHA_WH_XS"),
        "database": os.environ.get("SNOWFLAKE_DATABASE", "IRVINE_HOME_ANALYSIS"),
        # Tag every gate query so its cost lands in OPS.VW_CORTEX_SPEND under a
        # name that distinguishes CI from real user traffic.
        "session_parameters": {"QUERY_TAG": "iha_verify_gate"},
    }

    key_path = os.environ.get("SNOWFLAKE_PRIVATE_KEY_PATH")
    if key_path:
        from cryptography.hazmat.backends import default_backend
        from cryptography.hazmat.primitives import serialization

        passphrase = os.environ.get("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE")
        with open(key_path, "rb") as fh:
            pkey = serialization.load_pem_private_key(
                fh.read(),
                password=passphrase.encode() if passphrase else None,
                backend=default_backend(),
            )
        kwargs["private_key"] = pkey.private_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    elif os.environ.get("SNOWFLAKE_PASSWORD"):
        kwargs["password"] = os.environ["SNOWFLAKE_PASSWORD"]
    else:
        print(
            "No credential found: set SNOWFLAKE_PRIVATE_KEY_PATH (preferred) "
            "or SNOWFLAKE_PASSWORD",
            file=sys.stderr,
        )
        sys.exit(2)

    return snowflake.connector.connect(**kwargs)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <file.sql>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"no such file: {path}", file=sys.stderr)
        return 2

    statements = split_statements(path.read_text())
    conn = connect()
    saw_fail = False

    try:
        with conn.cursor() as cur:
            for stmt in statements:
                try:
                    cur.execute(stmt)
                except Exception as exc:  # noqa: BLE001 - surface the real error
                    preview = " ".join(stmt.split())[:120]
                    print(f"FAIL executing: {preview}\n  {exc}", file=sys.stderr)
                    return 1

                if cur.description:
                    for row in cur.fetchall():
                        rendered = " | ".join("" if v is None else str(v) for v in row)
                        print(rendered)
                        # The probe and test scripts signal failure with a FAIL
                        # token in a result column rather than by raising.
                        if any(
                            isinstance(v, str) and v.strip().upper() == "FAIL"
                            for v in row
                        ):
                            saw_fail = True
    finally:
        conn.close()

    return 1 if saw_fail else 0


if __name__ == "__main__":
    sys.exit(main())
