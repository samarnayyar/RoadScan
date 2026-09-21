#!/usr/bin/env python3
"""
Static consistency check for supabase/schema.sql + supabase/migrations/*.sql
against the Dart that calls them.

    python tool/check_schema.py

This is not a SQL parser and does not replace running the schema against a real
Postgres. It catches the class of error that is otherwise invisible until
runtime: the app and the database quietly disagreeing -- a renamed RPC, a
constant tuned in one place and not the other, or an OUT parameter that shadows
a table or column inside PL/pgSQL.

Migrations are read in filename order and concatenated after schema.sql, so a
function `create or replace`-d again in a later migration (e.g. submit_report
gaining p_captured_at in 002_captured_at.sql) is understood as the live
definition, not flagged as an accidental duplicate. This does NOT simulate
`drop function` -- a signature a migration drops is still visible to the
shadowing check below, harmlessly, as dead SQL text rather than a live
function. Treat this tool as a static heuristic, not a full schema simulator.
"""

from __future__ import annotations

import io
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SQL = ROOT / "supabase" / "schema.sql"
MIGRATIONS_DIR = ROOT / "supabase" / "migrations"
CONFIG = ROOT / "lib" / "config" / "app_config.dart"
SERVICE = ROOT / "lib" / "services" / "supabase_service.dart"
MODEL = ROOT / "lib" / "models" / "hazard_report.dart"

# RPCs that return one row per hazard pin, shaped for HazardReport.fromRpc.
# Each may return a different column subset (e.g. only the list RPCs return
# photo_count), so a key read by Dart only needs to appear in the UNION of
# these, not in every one of them.
HAZARD_REPORT_RPCS = ("nearby_reports", "all_reports", "device_reports")

failures: list[str] = []


def check(name: str, cond: bool, detail: object = "") -> None:
    if cond:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}" + (f"  -> {detail}" if detail != "" else ""))
        failures.append(name)


def read(p: Path) -> str:
    return io.open(p, encoding="utf-8").read()


def declared_functions(text: str) -> list[str]:
    return re.findall(r"create or replace function\s+(\w+)", text, re.I)


def function_blocks(sql: str) -> list[tuple[str, str]]:
    """(name, full source) for each function, split so that no regex below can
    accidentally span from one function into the next."""
    parts = re.split(r"(?=create or replace function\s)", sql, flags=re.I)
    blocks = []
    for part in parts:
        m = re.match(r"create or replace function\s+(\w+)", part, re.I)
        if m:
            blocks.append((m.group(1), part))
    return blocks


def plpgsql_bodies(sql: str) -> list[tuple[str, str, str]]:
    """(name, returns-table param list, body) for each plpgsql function."""
    out = []
    for name, block in function_blocks(sql):
        if not re.search(r"language plpgsql", block, re.I):
            continue
        ret = re.search(r"returns table\s*\((.*?)\)\s*language", block, re.I | re.S)
        body = re.search(r"as \$fn\$(.*?)\$fn\$;", block, re.S)
        out.append((name, ret.group(1) if ret else "", body.group(1) if body else ""))
    return out


def returns_table_columns(sql: str, fn_name: str) -> set[str]:
    """Column names in the LAST `returns table (...)` for a given function name
    -- i.e. the live definition if a migration redeclared it."""
    cols: set[str] = set()
    for m in re.finditer(
        rf"create or replace function {fn_name}\b.*?returns table\s*\((.*?)\)\s*language",
        sql, re.I | re.S,
    ):
        cols = set(re.findall(r"^\s*(\w+)\s+\w", m.group(1), re.M))  # last match wins
    return cols


def table_columns(sql: str) -> set[str]:
    """Column names declared inside create-table blocks, plus columns added by
    `alter table ... add column if not exists ...` in migrations.

    Scoping the create-table half to real tables matters: scraping every
    `  name type` line in the file would also pick up the functions' own OUT
    parameter declarations, and the shadowing check would then report every
    parameter as colliding with itself.
    """
    cols: set[str] = set()
    for m in re.finditer(
        r"create table if not exists \w+\s*\((.*?)\n\);", sql, re.I | re.S
    ):
        for line in m.group(1).splitlines():
            cm = re.match(r"\s{2,}(\w+)\s+\w", line)
            if cm and cm.group(1).lower() not in {"create", "primary", "unique"}:
                cols.add(cm.group(1))
    for m in re.finditer(
        r"alter table \w+\s+add column if not exists\s+(\w+)", sql, re.I
    ):
        cols.add(m.group(1))
    return cols


def main() -> int:
    schema_text = read(SQL)
    migration_files = sorted(MIGRATIONS_DIR.glob("*.sql")) if MIGRATIONS_DIR.exists() else []
    migrations = [(p.name, read(p)) for p in migration_files]
    config = read(CONFIG)
    service = read(SERVICE)
    model = read(MODEL)

    sources = [("schema.sql", schema_text)] + migrations
    print(f"reading schema.sql + {len(migrations)} migration(s): "
          f"{', '.join(name for name, _ in migrations) or '(none)'}")

    print("\ndollar quoting")
    for label, text in sources:
        for tag in ("$fn$", "$enums$"):
            n = text.count(tag)
            check(f"{label}: {tag} balanced ({n})", n % 2 == 0, n)

    print("\nfunctions declared per file (no accidental duplicate CREATE within one file)")
    for label, text in sources:
        names = declared_functions(text)
        check(f"{label}: no duplicate CREATE statements",
              len(names) == len(set(names)), names)

    # Combined text is the source of truth for "does this function/RPC exist"
    # style checks below. A function redeclared in a later migration is simply
    # present twice in this text -- see the module docstring for why that's
    # fine here.
    sql = "\n".join(text for _, text in sources)
    declared = sorted(set(declared_functions(sql)))
    print(f"\nlive function names: {', '.join(declared)}")

    plpg = plpgsql_bodies(sql)
    expected_plpgsql = len(re.findall(r"language plpgsql", sql, re.I))
    check("every 'language plpgsql' function body parsed",
          len(plpg) == expected_plpgsql,
          f"parsed {len(plpg)}, found {expected_plpgsql}")
    for name, _, body in plpg:
        check(
            f"{name}: begin/end balanced",
            len(re.findall(r"\bbegin\b", body, re.I))
            == len(re.findall(r"^end;\s*$", body, re.I | re.M)),
        )

    print("\nOUT parameter shadowing (plpgsql only)")
    # In PL/pgSQL an OUT parameter is a variable over the whole body, so one
    # named after a table or a column it touches produces an ambiguity error at
    # call time. SQL-language functions do not substitute this way and their
    # bodies here are fully column-qualified, so they are exempt.
    tables = set(re.findall(r"create table if not exists (\w+)", sql, re.I))
    reserved = tables | table_columns(sql)
    print(f"        guarding against: {len(reserved)} table/column names")
    for name, params, _ in plpg:
        for pname in re.findall(r"^\s*(\w+)\s+\w", params, re.M):
            check(
                f"{name}.{pname} does not shadow a table/column",
                pname not in reserved,
                f"collides with {pname}",
            )

    print("\nconstants agree between app and schema")

    def dart_const(pattern: str) -> str:
        m = re.search(pattern, config)
        if not m:
            failures.append(f"missing constant {pattern}")
            return "?"
        return m.group(1)

    thr = dart_const(r"fixedThreshold\s*=\s*(\d+)")
    check(f"fixedThreshold={thr} matches SQL threshold",
          f"v_negatives >= {thr}" in sql, re.findall(r"v_negatives >= \d+", sql))

    lam = dart_const(r"decayLambda\s*=\s*([\d.]+)")
    check(f"decayLambda={lam} matches SQL decay",
          f"exp(-{lam}" in sql, re.findall(r"exp\(-[\d.]+", sql))

    rad = dart_const(r"dedupRadiusMeters\s*=\s*([\d.]+)")
    check(f"dedupRadiusMeters={rad} matches SQL default",
          f"default {rad}" in sql,
          re.findall(r"p_radius_m\s+double precision default [\d.]+", sql))

    stale = dart_const(r"staleAfterDays\s*=\s*(\d+)")
    check(f"staleAfterDays={stale} matches SQL interval",
          f"interval '{stale} days'" in sql)

    bucket = re.search(r"photoBucket\s*=\s*'([^']+)'", config)
    if bucket:
        check(f"storage bucket '{bucket.group(1)}' created in SQL",
              f"'{bucket.group(1)}'" in sql)

    print("\nRPCs called by Dart exist in SQL")
    called = sorted(set(re.findall(r"rpc\('(\w+)'", service)))
    for fn in called:
        check(fn, fn in declared, declared)

    print("\nSQL grants cover every RPC the app calls")
    for fn in called:
        # The argument list is optional in this pattern but present in practice:
        # grants are written `grant execute on function f(args) to anon` so they
        # stay unambiguous if an overload is ever added. Match either form, and
        # allow newlines inside the argument list.
        check(f"{fn} granted to anon",
              re.search(rf"grant execute on function\s+{fn}\s*(\([^)]*\))?\s+to[^;]*anon",
                        sql, re.I | re.S)
              is not None)

    print("\nresult keys read by Dart are produced by SQL")
    keys = sorted(set(re.findall(r"row\['(\w+)'\]", service)))
    keys += sorted(set(re.findall(r"r\['(\w+)'\]", service)))
    for key in sorted(set(keys)):
        check(key, key in sql)

    print(f"\nHazardReport.fromRpc keys are produced by at least one of "
          f"{', '.join(HAZARD_REPORT_RPCS)}")
    # Union rather than intersection: nearby_reports deliberately omits
    # photo_count (proximity checks don't need it), while all_reports and
    # device_reports omit distance_m (there's no reference point). A key only
    # needs a home somewhere, and HazardReport's own fields carry `??` fallbacks
    # for whichever RPC doesn't supply it.
    union_cols: set[str] = set()
    per_rpc: dict[str, set[str]] = {}
    for fn in HAZARD_REPORT_RPCS:
        cols = returns_table_columns(sql, fn)
        per_rpc[fn] = cols
        union_cols |= cols
    for fn in HAZARD_REPORT_RPCS:
        check(f"{fn}: returns table parsed", bool(per_rpc[fn]), "no columns found")
    for key in sorted(set(re.findall(r"row\['(\w+)'\]", model))):
        have = [fn for fn in HAZARD_REPORT_RPCS if key in per_rpc[fn]]
        check(f"{key} (in {', '.join(have) if have else 'none'})",
              key in union_cols, sorted(union_cols))

    print()
    if failures:
        print(f"{len(failures)} FAILED")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
