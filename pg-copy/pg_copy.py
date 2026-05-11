#!/usr/bin/env python3
"""
pg-copy — interactive row-level copy from one PostgreSQL DB to another.

Setup: run setup.bat (Windows) or setup.sh (Linux/Mac), then start.bat / start.sh.
"""

import sys
from pathlib import Path

try:
    import psycopg2
    import psycopg2.extras
    from prompt_toolkit import prompt
    from prompt_toolkit.completion import WordCompleter, FuzzyCompleter
except ImportError:
    print("Missing dependencies — run setup.bat (or setup.sh) first.")
    sys.exit(1)

ENV_FILE = Path(__file__).parent / ".env"

# Teach psycopg2 to serialize dict/list (JSONB columns) on write
psycopg2.extensions.register_adapter(dict, psycopg2.extras.Json)
psycopg2.extensions.register_adapter(list, psycopg2.extras.Json)

NUMERIC_TYPES = {
    "integer", "bigint", "smallint", "serial", "bigserial",
    "numeric", "real", "double precision",
}


def load_env():
    if not ENV_FILE.exists():
        print("No .env file found — run setup.bat (or setup.sh) first.")
        sys.exit(1)
    env = {}
    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def connect(env, prefix):
    return psycopg2.connect(
        host=env.get(f"{prefix}_HOST", "localhost"),
        port=int(env.get(f"{prefix}_PORT", 5432)),
        dbname=env[f"{prefix}_DBNAME"],
        user=env[f"{prefix}_USER"],
        password=env.get(f"{prefix}_PASSWORD", ""),
    )


def q(conn, sql, params=()):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def get_schemas(conn):
    return [r[0] for r in q(conn, """
        SELECT schema_name FROM information_schema.schemata
        WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
        ORDER BY schema_name
    """)]


def get_tables(conn, schema):
    return [r[0] for r in q(conn, """
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = %s AND table_type = 'BASE TABLE'
        ORDER BY table_name
    """, (schema,))]


def get_columns(conn, schema, table):
    return q(conn, """
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_schema = %s AND table_name = %s
        ORDER BY ordinal_position
    """, (schema, table))


def get_pks(conn, schema, table):
    return [r[0] for r in q(conn, """
        SELECT kcu.column_name
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
          ON tc.constraint_name = kcu.constraint_name
         AND tc.table_schema    = kcu.table_schema
        WHERE tc.constraint_type = 'PRIMARY KEY'
          AND tc.table_schema = %s AND tc.table_name = %s
        ORDER BY kcu.ordinal_position
    """, (schema, table))]


def get_indexed_cols(conn, schema, table):
    return [r[0] for r in q(conn, """
        SELECT DISTINCT a.attname
        FROM pg_index     i
        JOIN pg_class     c ON c.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(i.indkey)
        WHERE n.nspname = %s AND c.relname = %s
          AND NOT i.indisprimary
        ORDER BY a.attname
    """, (schema, table))]


def cast_val(val, dtype):
    """Cast string user input to the right Python type for psycopg2."""
    if val is None or val == "":
        return None
    if dtype in {"integer", "bigint", "smallint", "serial", "bigserial"}:
        return int(val)
    if dtype in {"numeric", "real", "double precision"}:
        return float(val)
    return val


def fetch_rows(conn, schema, table, col_names, sort_col,
               filter_col=None, from_val=None, to_val=None, last_n=20):
    cols = ", ".join(f'"{c}"' for c in col_names)

    if filter_col and (from_val is not None or to_val is not None):
        conds, params = [], []
        if from_val is not None:
            conds.append(f'"{filter_col}" >= %s')
            params.append(from_val)
        if to_val is not None:
            conds.append(f'"{filter_col}" <= %s')
            params.append(to_val)
        sql = f'SELECT {cols} FROM "{schema}"."{table}" WHERE {" AND ".join(conds)}'
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall()
    else:
        order = f'"{sort_col}" DESC' if sort_col else "ctid DESC"
        with conn.cursor() as cur:
            cur.execute(
                f'SELECT {cols} FROM "{schema}"."{table}" ORDER BY {order} LIMIT %s',
                (last_n,),
            )
            return cur.fetchall()


def build_upsert(schema, table, col_names, pk_cols):
    cols = ", ".join(f'"{c}"' for c in col_names)
    vals = ", ".join(["%s"] * len(col_names))
    non_pk = [c for c in col_names if c not in pk_cols]
    conflict_target = ", ".join(f'"{c}"' for c in pk_cols)

    if non_pk:
        updates = ", ".join(f'"{c}" = EXCLUDED."{c}"' for c in non_pk)
        on_conflict = f"ON CONFLICT ({conflict_target}) DO UPDATE SET {updates}"
    else:
        on_conflict = f"ON CONFLICT ({conflict_target}) DO NOTHING"

    return f'INSERT INTO "{schema}"."{table}" ({cols}) VALUES ({vals}) {on_conflict}'


def fuzzy(options):
    return FuzzyCompleter(WordCompleter([str(o) for o in options], sentence=True))


def ask(question, options=None, default=""):
    c = fuzzy(options) if options else None
    val = prompt(question, completer=c).strip()
    return val if val else default


def print_preview(rows, col_names, max_rows=5, max_cols=5):
    preview_cols = col_names[:max_cols]
    preview_idx = [col_names.index(c) for c in preview_cols]
    col_w = 22

    header = "  " + " | ".join(f"{c:<{col_w}}" for c in preview_cols)
    sep = "  " + "-+-".join("-" * col_w for _ in preview_cols)
    print(header)
    print(sep)
    for row in rows[:max_rows]:
        print("  " + " | ".join(f"{str(row[i]):<{col_w}}" for i in preview_idx))
    if len(rows) > max_rows:
        print(f"  ... ({len(rows) - max_rows} more row(s) not shown)")


def main():
    env = load_env()

    print("\n  pg-copy  |  stage -> local\n")

    try:
        src = connect(env, "STAGE")
        dst = connect(env, "LOCAL")
    except Exception as e:
        print(f"Connection error: {e}")
        sys.exit(1)

    src_label = f"{env['STAGE_DBNAME']}@{env.get('STAGE_HOST', 'localhost')}"
    dst_label = f"{env['LOCAL_DBNAME']}@{env.get('LOCAL_HOST', 'localhost')}"
    print(f"  source  :  {src_label}")
    print(f"  target  :  {dst_label}\n")

    # --- Schema ---
    schemas = get_schemas(src)
    schema = ask("Schema [public]: ", schemas, default="public")

    # --- Table ---
    tables = get_tables(src, schema)
    if not tables:
        print(f"No tables found in schema '{schema}'.")
        sys.exit(1)

    table = ask("Table: ", tables)
    if table not in tables:
        print(f"Table '{table}' not found in schema '{schema}'.")
        sys.exit(1)

    # --- Introspect ---
    columns = get_columns(src, schema, table)
    col_names = [c[0] for c in columns]
    col_types = {c[0]: c[1] for c in columns}
    pk_cols     = get_pks(src, schema, table)   # source — used for filter candidates
    dst_pk_cols = get_pks(dst, schema, table)   # target — used for ON CONFLICT
    indexed = get_indexed_cols(src, schema, table)

    print(f"\n  columns      :  {', '.join(col_names)}")
    print(f"  primary keys :  {', '.join(pk_cols) if pk_cols else '(none)'}")
    if dst_pk_cols != pk_cols:
        print(f"  local PKs    :  {', '.join(dst_pk_cols) if dst_pk_cols else '(none)'}  (differs from stage)")
    print(f"  indexed      :  {', '.join(indexed) if indexed else '(none)'}\n")

    # Best sort column for "last N": prefer numeric PK, then any numeric, then first col
    sort_col = next(
        (c for c in pk_cols if col_types.get(c) in NUMERIC_TYPES),
        next(
            (c for c in col_names if col_types.get(c) in NUMERIC_TYPES),
            col_names[0] if col_names else None,
        ),
    )

    # --- Filter ---
    filter_candidates = pk_cols + [c for c in indexed if c not in pk_cols]

    print("  Filter options:")
    print("    0)  Last N rows  (default)")
    for i, col in enumerate(filter_candidates, 1):
        dtype = col_types.get(col, "")
        print(f"    {i})  {col}  ({dtype})")

    choice_str = ask("\nFilter choice [0]: ", list(range(len(filter_candidates) + 1)), default="0")
    try:
        choice = int(choice_str)
    except ValueError:
        choice = 0

    filter_col = from_val = to_val = None
    last_n = 20

    if 1 <= choice <= len(filter_candidates):
        filter_col = filter_candidates[choice - 1]
        dtype = col_types.get(filter_col, "")
        raw_from = ask(f"  {filter_col} FROM  (blank = no lower bound): ")
        raw_to   = ask(f"  {filter_col} TO    (blank = no upper bound): ")
        from_val = cast_val(raw_from, dtype)
        to_val   = cast_val(raw_to,   dtype)

        if from_val is None and to_val is None:
            print("  No bounds given — falling back to last 20 rows.")
            filter_col = None
    else:
        n_str = ask("Last N rows [20]: ", default="20")
        last_n = int(n_str) if n_str.isdigit() else 20

    # --- Fetch ---
    print("\nFetching from stage... ", end="", flush=True)
    try:
        rows = fetch_rows(src, schema, table, col_names, sort_col,
                          filter_col, from_val, to_val, last_n)
    except Exception as e:
        print(f"\nFetch error: {e}")
        sys.exit(1)

    print(f"{len(rows)} row(s).\n")

    if not rows:
        print("Nothing to copy.")
        sys.exit(0)

    print_preview(rows, col_names)
    print()

    # --- Confirm ---
    confirm = ask(f"Upsert {len(rows)} row(s) into local '{table}'? [y/N]: ", default="N").lower()
    if confirm != "y":
        print("Aborted.")
        sys.exit(0)

    # --- Write ---
    if dst_pk_cols:
        sql = build_upsert(schema, table, col_names, dst_pk_cols)
    else:
        print("Warning: no primary key on local table — using plain INSERT (duplicates possible).")
        cols = ", ".join(f'"{c}"' for c in col_names)
        vals = ", ".join(["%s"] * len(col_names))
        sql = f'INSERT INTO "{schema}"."{table}" ({cols}) VALUES ({vals})'

    try:
        with dst.cursor() as cur:
            psycopg2.extras.execute_batch(cur, sql, rows)
        dst.commit()
        print(f"\nDone. {len(rows)} row(s) upserted into local '{schema}'.'{table}'.")
    except Exception as e:
        dst.rollback()
        print(f"\nWrite error: {e}")
        sys.exit(1)
    finally:
        src.close()
        dst.close()


if __name__ == "__main__":
    main()
