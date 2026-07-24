#!/usr/bin/env python3
"""
Interactive Database Sync Tool: Mobile App SQLite <-> Server PostgreSQL

Allows selecting sync direction, source/target databases, and specific tables via an
interactive menu with checkboxes. Syncs data on demand in either direction.
"""

import argparse
import json
import os
import sqlite3
import sys
from pathlib import Path

# Try importing psycopg2 for Postgres connection
try:
    import psycopg2
    from psycopg2.extras import RealDictCursor
    HAS_PSYCOPG2 = True
except ImportError:
    HAS_PSYCOPG2 = False

# Workspace base directories
REPO_ROOT = Path(__file__).resolve().parent.parent
DOTENV_PATH = REPO_ROOT / ".env"
FLUTTER_APP_PATH = Path("/Users/nbarrera/projects/Flutter_Apps/blablaragsandrigs")

# Supported sync tables with dependency order
SYNC_TABLES = [
    {"key": "categories", "label": "Taxonomy Categories (categories)", "deps": []},
    {"key": "category_tree", "label": "Taxonomy Tree (category_tree)", "deps": ["categories"]},
    {"key": "product_groups", "label": "Product Groups (product_groups)", "deps": []},
    {"key": "product_items", "label": "Product Items (product_items)", "deps": ["product_groups", "categories"]},
    {"key": "item_images", "label": "Item Images (item_images)", "deps": ["product_items"]},
    {"key": "user_profiles", "label": "User Profiles (user_profiles)", "deps": []},
    {"key": "user_addresses", "label": "User Addresses (user_addresses)", "deps": []},
    {"key": "user_payment_methods", "label": "User Payment Methods (user_payment_methods)", "deps": []},
    {"key": "user_personalization", "label": "User Personalization (user_personalization)", "deps": []},
    {"key": "user_notifications", "label": "User Notifications (user_notifications)", "deps": []},
    {"key": "user_privacy", "label": "User Privacy (user_privacy)", "deps": []},
    {"key": "user_pro_seller", "label": "User Pro Seller (user_pro_seller)", "deps": []},
    {"key": "user_friends", "label": "User Friends (user_friends)", "deps": []},
]


def load_env_file(env_path: Path) -> dict:
    """Parse .env file into key-value map."""
    env = {}
    if env_path.exists():
        for line in env_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip("'\"")
    return env


def parse_postgres_config() -> dict:
    """Read Postgres connection parameters from environment or default .env."""
    env = load_env_file(DOTENV_PATH)
    return {
        "host": os.getenv("DB_HOST", env.get("DB_HOST", "127.0.0.1")),
        "port": int(os.getenv("DB_PORT", env.get("DB_PORT", "5432"))),
        "user": os.getenv("POSTGRES_USER", env.get("POSTGRES_USER", "postgres")),
        "password": os.getenv("POSTGRES_PASSWORD", env.get("POSTGRES_PASSWORD", "postgres")),
        "database": os.getenv("POSTGRES_DB", env.get("POSTGRES_DB", "node_nginx_clean")),
    }


def find_sqlite_db_path() -> Path:
    """Locate SQLite database file."""
    candidates = [
        FLUTTER_APP_PATH / "blablarags.db",
        REPO_ROOT / "blablarags.db",
        Path.home() / "blablarags.db",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]


def interactive_checkbox_menu(items: list) -> list:
    """
    Render terminal checkbox selection menu.
    Allows toggling items by typing number or using all/none commands.
    """
    selected = set(item["key"] for item in items)  # Default all selected

    while True:
        print("\n=======================================================")
        print(" SELECT TABLES TO SYNC (Enter number to toggle, 'a'=all, 'n'=none, 'd'=done)")
        print("=======================================================")
        for idx, item in enumerate(items, 1):
            mark = "[X]" if item["key"] in selected else "[ ]"
            print(f" {idx:2d}. {mark} {item['label']}")
        print("-------------------------------------------------------")

        cmd = input("Choice [1-%d, a, n, d]: " % len(items)).strip().lower()
        if cmd == "d" or cmd == "":
            if not selected:
                print("Warning: No tables selected. Please select at least one table.")
                continue
            break
        elif cmd == "a":
            selected = set(item["key"] for item in items)
        elif cmd == "n":
            selected.clear()
        elif cmd.isdigit():
            num = int(cmd)
            if 1 <= num <= len(items):
                key = items[num - 1]["key"]
                if key in selected:
                    selected.remove(key)
                else:
                    selected.add(key)
            else:
                print("Invalid number.")
        else:
            print("Invalid selection.")

    return [item["key"] for item in items if item["key"] in selected]


def prompt_sync_direction() -> str:
    """Prompt user for sync direction."""
    print("\n=======================================================")
    print(" SELECT DIRECTION OF SYNCHRONIZATION")
    print("=======================================================")
    print(" 1. App SQLite (blablarags.db)  ---> Server PostgreSQL (Bootstrap Upstream)")
    print(" 2. Server PostgreSQL           ---> App SQLite (blablarags.db) (Downstream)")
    print("-------------------------------------------------------")

    while True:
        choice = input("Select direction [1 or 2]: ").strip()
        if choice == "1":
            return "APP_TO_SERVER"
        elif choice == "2":
            return "SERVER_TO_APP"
        print("Invalid choice. Enter 1 or 2.")


def connect_sqlite(sqlite_path: Path):
    """Establish SQLite connection with DictFactory."""
    conn = sqlite3.connect(sqlite_path)
    conn.row_factory = sqlite3.Row
    return conn


def connect_postgres(pg_cfg: dict):
    """Establish Postgres connection."""
    if not HAS_PSYCOPG2:
        print("Error: 'psycopg2' module not installed. Install via: pip install psycopg2-binary")
        sys.exit(1)
    return psycopg2.connect(
        host=pg_cfg["host"],
        port=pg_cfg["port"],
        user=pg_cfg["user"],
        password=pg_cfg["password"],
        dbname=pg_cfg["database"],
    )


def sync_app_to_server(sqlite_conn, pg_conn, tables: list, dry_run: bool = False):
    """Sync data upstream from App SQLite to Server Postgres."""
    print("\nStarting Upstream Sync: App (SQLite) ---> Server (Postgres)")
    pg_cur = pg_conn.cursor(cursor_factory=RealDictCursor)
    sq_cur = sqlite_conn.cursor()

    total_synced = 0

    for table in tables:
        print(f"\nProcessing table: {table}...")
        try:
            sq_cur.execute(f"SELECT * FROM {table}")
            rows = [dict(row) for row in sq_cur.fetchall()]
            if not rows:
                print(f"  No records found in SQLite for '{table}'. Skipping.")
                continue

            print(f"  Fetched {len(rows)} records from SQLite.")

            # Column mapping strategy for SQLite -> Postgres
            for row in rows:
                if table == "product_groups":
                    group_id = row.get("group_id")
                    scan_uuid = row.get("scan_session_uuid")
                    user_id = row.get("user_id") or 1
                    country = row.get("country_code", "DE")

                    if not dry_run:
                        pg_cur.execute(
                            """
                            INSERT INTO product_groups (account_id, scan_session_uuid, country_code, item_count)
                            VALUES (%s, %s, %s, %s)
                            ON CONFLICT (id) DO UPDATE SET
                                country_code = EXCLUDED.country_code
                            RETURNING id;
                            """,
                            (user_id, scan_uuid, country, 0),
                        )
                    total_synced += 1

                elif table == "product_items":
                    if not dry_run:
                        pg_cur.execute(
                            """
                            INSERT INTO product_items (
                                group_id, sort_order, item_status, name, condition_id, predicted_category_id,
                                prediction_confidence, dominant_color, gender, size, description, price,
                                currency, views_count, watchlist_count, blabla_friends_id, blabla_friends_status, source
                            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                            ON CONFLICT (id) DO NOTHING;
                            """,
                            (
                                row.get("group_id"),
                                row.get("sort_order", 0),
                                row.get("item_status", "active"),
                                row.get("name", "Garment Item"),
                                row.get("condition_id", "good"),
                                row.get("category_id") or 1,
                                row.get("prediction_confidence"),
                                row.get("prediction_dominant_color"),
                                "unspecified",
                                row.get("size", "M"),
                                row.get("description", ""),
                                row.get("price", 0.0),
                                row.get("currency", "EUR"),
                                row.get("views_count", 0),
                                row.get("watchlist_count", 0),
                                row.get("blabla_friends_id"),
                                row.get("blabla_friends_status", "unassigned"),
                                row.get("metadata_source", "manual_entry"),
                            ),
                        )
                    total_synced += 1

                elif table == "item_images":
                    if not dry_run:
                        pg_cur.execute(
                            """
                            INSERT INTO item_images (item_id, url, sort_order)
                            VALUES (%s, %s, %s)
                            ON CONFLICT (id) DO NOTHING;
                            """,
                            (row.get("item_id"), row.get("image_url", ""), row.get("sort_order", 0)),
                        )
                    total_synced += 1

                elif table == "categories":
                    if not dry_run:
                        pg_cur.execute(
                            """
                            INSERT INTO categories (id, parent_id, level, key, label)
                            VALUES (%s, %s, %s, %s, %s)
                            ON CONFLICT (id) DO NOTHING;
                            """,
                            (
                                row.get("id"),
                                row.get("parent_id"),
                                row.get("level", 0),
                                row.get("name", "category").lower(),
                                row.get("name", "Category"),
                            ),
                        )
                    total_synced += 1

                else:
                    # General insert for matching table structure
                    cols = list(row.keys())
                    vals = [row[c] for c in cols]
                    placeholders = ", ".join(["%s"] * len(cols))
                    col_names = ", ".join(cols)

                    sql = f"INSERT INTO {table} ({col_names}) VALUES ({placeholders}) ON CONFLICT DO NOTHING;"
                    if not dry_run:
                        pg_cur.execute(sql, vals)
                    total_synced += 1

            # Update sync_status in SQLite if table has sync_status column
            if table == "product_groups" and not dry_run:
                sqlite_conn.execute("UPDATE product_groups SET sync_status = 'synced'")
                sqlite_conn.commit()

            print(f"  Successfully synced {len(rows)} records for table '{table}'.")

        except Exception as e:
            print(f"  Error syncing table '{table}': {e}")
            pg_conn.rollback()
            raise

    if not dry_run:
        pg_conn.commit()

    print(f"\nUpstream Sync Complete! Total synced records: {total_synced}")


def sync_server_to_app(sqlite_conn, pg_conn, tables: list, dry_run: bool = False):
    """Sync data downstream from Server Postgres to App SQLite."""
    print("\nStarting Downstream Sync: Server (Postgres) ---> App (SQLite)")
    pg_cur = pg_conn.cursor(cursor_factory=RealDictCursor)

    total_synced = 0

    for table in tables:
        print(f"\nProcessing table: {table}...")
        try:
            pg_cur.execute(f"SELECT * FROM {table}")
            rows = pg_cur.fetchall()
            if not rows:
                print(f"  No records found in Postgres for '{table}'. Skipping.")
                continue

            print(f"  Fetched {len(rows)} records from Postgres.")

            for row in rows:
                if table == "product_groups":
                    sql = """
                        INSERT INTO product_groups (group_id, scan_session_uuid, user_id, country_code, created_at, sync_status)
                        VALUES (?, ?, ?, ?, ?, 'synced')
                        ON CONFLICT(group_id) DO UPDATE SET
                            country_code = excluded.country_code,
                            sync_status = 'synced';
                    """
                    vals = (
                        row["id"],
                        str(row.get("scan_session_uuid") or ""),
                        row.get("account_id") or 1,
                        row.get("country_code", "DE"),
                        str(row.get("created_at") or ""),
                    )
                    if not dry_run:
                        sqlite_conn.execute(sql, vals)
                    total_synced += 1

                elif table == "product_items":
                    sql = """
                        INSERT INTO product_items (
                            item_id, group_id, sort_order, item_status, category_id, name,
                            price, currency, image_url, size, condition_id, description,
                            views_count, watchlist_count, blabla_friends_id, blabla_friends_status
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(item_id) DO UPDATE SET
                            item_status = excluded.item_status,
                            price = excluded.price,
                            name = excluded.name,
                            condition_id = excluded.condition_id,
                            views_count = excluded.views_count,
                            watchlist_count = excluded.watchlist_count,
                            blabla_friends_status = excluded.blabla_friends_status;
                    """
                    vals = (
                        row["id"],
                        row.get("group_id"),
                        row.get("sort_order", 0),
                        row.get("item_status", "active"),
                        row.get("predicted_category_id") or 1,
                        row.get("name") or "Garment Item",
                        float(row.get("price") or 0.0),
                        row.get("currency", "EUR"),
                        "",
                        row.get("size", "M"),
                        row.get("condition_id", "good"),
                        row.get("description", ""),
                        row.get("views_count", 0),
                        row.get("watchlist_count", 0),
                        row.get("blabla_friends_id"),
                        row.get("blabla_friends_status", "unassigned"),
                    )
                    if not dry_run:
                        sqlite_conn.execute(sql, vals)
                    total_synced += 1

                elif table == "categories":
                    sql = """
                        INSERT INTO categories (id, parent_id, name, level, path_ids, breadcrumb)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO NOTHING;
                    """
                    vals = (
                        row["id"],
                        row.get("parent_id"),
                        row.get("label") or row.get("key"),
                        row.get("level", 0),
                        str(row["id"]),
                        row.get("label", ""),
                    )
                    if not dry_run:
                        sqlite_conn.execute(sql, vals)
                    total_synced += 1

                else:
                    cols = list(row.keys())
                    vals = [row[c] for c in cols]
                    placeholders = ", ".join(["?"] * len(cols))
                    col_names = ", ".join(cols)

                    sql = f"INSERT INTO {table} ({col_names}) VALUES ({placeholders}) ON CONFLICT DO NOTHING;"
                    if not dry_run:
                        sqlite_conn.execute(sql, vals)
                    total_synced += 1

            if not dry_run:
                sqlite_conn.commit()

            print(f"  Successfully synced {len(rows)} records for table '{table}'.")

        except Exception as e:
            print(f"  Error syncing table '{table}': {e}")
            sqlite_conn.rollback()
            raise

    print(f"\nDownstream Sync Complete! Total synced records: {total_synced}")


def main():
    parser = argparse.ArgumentParser(description="Interactive Mobile App <-> Server Database Sync")
    parser.add_argument("--sqlite-db", type=str, help="Path to SQLite database file")
    parser.add_argument("--dry-run", action="store_true", help="Perform sync analysis without writing changes")
    args = parser.parse_args()

    # Determine SQLite database path
    sqlite_path = Path(args.sqlite_db) if args.sqlite_db else find_sqlite_db_path()
    print("=======================================================")
    print(" DATABASE SYNCHRONIZATION TOOL")
    print("=======================================================")
    print(f" SQLite App DB:   {sqlite_path}")

    # Determine Postgres config
    pg_cfg = parse_postgres_config()
    print(f" Postgres Host:   {pg_cfg['host']}:{pg_cfg['port']} ({pg_cfg['database']})")

    # Select direction
    direction = prompt_sync_direction()

    # Select tables
    selected_tables = interactive_checkbox_menu(SYNC_TABLES)

    print("\n=======================================================")
    print(" CONFIRM SYNCHRONIZATION PARAMETERS")
    print("=======================================================")
    print(f" Direction:   {direction}")
    print(f" SQLite DB:   {sqlite_path}")
    print(f" Postgres DB: {pg_cfg['user']}@{pg_cfg['host']}:{pg_cfg['port']}/{pg_cfg['database']}")
    print(f" Tables ({len(selected_tables)}): {', '.join(selected_tables)}")
    print(f" Mode:        {'DRY-RUN (No writes)' if args.dry_run else 'LIVE EXECUTION'}")
    print("-------------------------------------------------------")

    confirm = input("Proceed with synchronization? [y/N]: ").strip().lower()
    if confirm != "y":
        print("Synchronization cancelled.")
        sys.exit(0)

    # Establish connections
    try:
        sqlite_conn = connect_sqlite(sqlite_path)
    except Exception as e:
        print(f"Failed to connect to SQLite at {sqlite_path}: {e}")
        sys.exit(1)

    try:
        pg_conn = connect_postgres(pg_cfg)
    except Exception as e:
        print(f"Failed to connect to Postgres ({pg_cfg['host']}:{pg_cfg['port']}): {e}")
        sqlite_conn.close()
        sys.exit(1)

    try:
        if direction == "APP_TO_SERVER":
            sync_app_to_server(sqlite_conn, pg_conn, selected_tables, dry_run=args.dry_run)
        else:
            sync_server_to_app(sqlite_conn, pg_conn, selected_tables, dry_run=args.dry_run)
    finally:
        sqlite_conn.close()
        pg_conn.close()


if __name__ == "__main__":
    main()
