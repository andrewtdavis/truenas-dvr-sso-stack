#!/usr/bin/env python3
#
# Synopsis:
#   Reconcile Organizr tabs with the new proxied topology: set hosts and ping
#   URLs for proxied apps, and switch non-proxied apps to open in a new window.
#
# Description:
#   Classifies each tab by a normalized name token into one of three groups and
#   applies the matching changes:
#     - Subfolder-proxied: url, url_local, and ping_url are set to the proxy
#       base plus the app subfolder, and the tab is set to iframe.
#     - Subdomain-pending: url, url_local, and ping_url are set to the app's
#       planned subdomain, and the tab is set to new window (the subdomain proxy
#       is built separately; new window avoids cross-origin iframe issues).
#     - External new window: the tab is switched to new window and its existing
#       url and ping are left intact (the app is still reachable at its host).
#   Tabs matching no group are left untouched and reported as SKIP.
#
#   Organizr pings server-side from its own container, which is not on the
#   internal network, so proxied pings target the proxy URL (a redirect still
#   registers as reachable) rather than an internal container name.
#
#   Read-only by default; --apply writes after backing up the database. Tab type
#   values: 1 = iframe, 2 = new window.
#
# Parameters:
#   --root DIR       Config root to search for the database. Default below.
#   --db FILE        Explicit database path (skips discovery).
#   --base-url URL   Proxy base, no trailing slash. Default below.
#   --apply          Persist changes. Without it, only report.
#   --no-backup      Skip the pre-write backup (not recommended).
#   --debug          Verbose tracing to stderr.
#
# Examples:
#   ./fix-organizr-tabs.py
#   ./fix-organizr-tabs.py --apply
#

import argparse
import csv
import os
import re
import shutil
import sqlite3
import sys
import time

DEFAULT_CONFIG_ROOT = "/mnt/tank/app-volumes/organizr"
DEFAULT_BASE_URL = "https://dvr.example.com"

TYPE_IFRAME = 1
TYPE_NEW_WINDOW = 2

# Token (normalized) to subfolder path. Set iframe.
PROXIED_SUBFOLDER_MAP = {
    "sonarr": "/sonarr",
    "radarr": "/radarr",
    "lidarr": "/lidarr",
    "prowlarr": "/prowlarr",
    "tautulli": "/tautulli",
    "bazarr": "/bazarr",
    "cleanuparr": "/cleanuparr",
}

# Sabnzbd is proxied at /sabnzbd but frame-busts on its settings pages, so it
# opens in a new window. Its proxied URL is set; only the tab type differs.
PROXIED_NEWWINDOW_MAP = {
    "sabnzbd": "/sabnzbd",
}

# Token (normalized) to full subdomain URL. Set new window for now.
PROXIED_SUBDOMAIN_MAP = {
    "overseerr": "https://overseerr.example.com",
    "requestrr": "https://requestrr.example.com",
}

# Tokens (normalized) for not-migrated apps: switch to new window, keep URL.
NEW_WINDOW_TOKENS = [
    "plex", "tdarr", "transmission", "openspeedtest", "truenas",
    "edgeswitch", "ipmi", "homebridge", "pihole", "diskover",
    "speedtesttracker", "changedetection",
]


def normalize_name(raw_name):
    return re.sub(r"[^a-z0-9]", "", (raw_name or "").lower())


def emit_debug(debug_enabled, message_text):
    if debug_enabled:
        print("DEBUG: %s" % message_text, file=sys.stderr)


def discover_database(search_root, debug_enabled):
    for walk_dir, _, file_names in os.walk(search_root):
        for found_file in file_names:
            if not found_file.endswith(".db"):
                continue
            candidate_path = os.path.join(walk_dir, found_file)
            try:
                probe_conn = sqlite3.connect("file:%s?mode=ro" % candidate_path, uri=True)
                table_names = [row_item[0] for row_item in probe_conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'")]
                probe_conn.close()
                if "tabs" in table_names:
                    emit_debug(debug_enabled, "Selected database %s" % candidate_path)
                    return candidate_path
            except sqlite3.Error:
                continue
    return None


def classify_tab(normalized_name, base_url_clean):
    for subfolder_token, subfolder_path in PROXIED_SUBFOLDER_MAP.items():
        if subfolder_token in normalized_name:
            return ("SUBFOLDER", base_url_clean + subfolder_path, TYPE_IFRAME, True)
    for newwindow_token, newwindow_path in PROXIED_NEWWINDOW_MAP.items():
        if newwindow_token in normalized_name:
            return ("PROXY-NEWWINDOW", base_url_clean + newwindow_path, TYPE_NEW_WINDOW, True)
    for subdomain_token, subdomain_url in PROXIED_SUBDOMAIN_MAP.items():
        if subdomain_token in normalized_name:
            return ("SUBDOMAIN", subdomain_url, TYPE_NEW_WINDOW, True)
    for window_token in NEW_WINDOW_TOKENS:
        if window_token in normalized_name:
            return ("NEWWINDOW", None, TYPE_NEW_WINDOW, False)
    return ("SKIP", None, None, False)


def main():
    arg_parser = argparse.ArgumentParser(add_help=True)
    arg_parser.add_argument("--root", dest="config_root", default=DEFAULT_CONFIG_ROOT)
    arg_parser.add_argument("--db", dest="database_path", default=None)
    arg_parser.add_argument("--base-url", dest="base_url", default=DEFAULT_BASE_URL)
    arg_parser.add_argument("--apply", dest="apply_changes", action="store_true")
    arg_parser.add_argument("--no-backup", dest="skip_backup", action="store_true")
    arg_parser.add_argument("--debug", dest="debug_enabled", action="store_true")
    parsed_args = arg_parser.parse_args()

    base_url_clean = parsed_args.base_url.rstrip("/")

    resolved_db_path = parsed_args.database_path or discover_database(
        parsed_args.config_root, parsed_args.debug_enabled)
    if not resolved_db_path or not os.path.isfile(resolved_db_path):
        print("ERROR: Could not locate an Organizr database with a 'tabs' table.", file=sys.stderr)
        return 2
    print("# database: %s" % resolved_db_path, file=sys.stderr)

    if parsed_args.apply_changes and not parsed_args.skip_backup:
        backup_path = "%s.bak.%s" % (resolved_db_path, time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(resolved_db_path, backup_path)
        print("# backup: %s" % backup_path, file=sys.stderr)

    open_mode = "rw" if parsed_args.apply_changes else "ro"
    db_conn = sqlite3.connect("file:%s?mode=%s" % (resolved_db_path, open_mode), uri=True, timeout=15)
    db_conn.execute("PRAGMA busy_timeout = 15000")

    present_columns = {col_row[1] for col_row in db_conn.execute("PRAGMA table_info(tabs)")}
    has_url_local = "url_local" in present_columns
    has_ping_url = "ping_url" in present_columns
    has_type = "type" in present_columns

    report_writer = csv.writer(sys.stdout, delimiter="\t")
    report_writer.writerow(["id", "name", "group", "action", "type", "url"])

    pending_updates = []
    for tab_row in db_conn.execute("SELECT id, name, url, type FROM tabs ORDER BY id"):
        tab_id, tab_name, tab_url, tab_type = tab_row
        group_label, target_url, target_type, update_urls = classify_tab(
            normalize_name(tab_name), base_url_clean)

        if group_label == "SKIP":
            report_writer.writerow([tab_id, tab_name, "-", "SKIP", tab_type, tab_url])
            continue

        set_clauses = []
        set_values = []
        if update_urls and target_url is not None:
            set_clauses.append("url = ?")
            set_values.append(target_url)
            if has_url_local:
                set_clauses.append("url_local = ?")
                set_values.append(target_url)
            if has_ping_url:
                set_clauses.append("ping_url = ?")
                set_values.append(target_url)
        if has_type and target_type is not None and tab_type != target_type:
            set_clauses.append("type = ?")
            set_values.append(target_type)

        if not set_clauses:
            report_writer.writerow([tab_id, tab_name, group_label, "NOCHANGE", tab_type, tab_url])
            continue

        action_label = "UPDATE" if parsed_args.apply_changes else "WOULD-UPDATE"
        report_writer.writerow([tab_id, tab_name, group_label, action_label,
                                target_type if target_type is not None else tab_type,
                                target_url if target_url is not None else tab_url])
        pending_updates.append((set_clauses, set_values, tab_id))

    if parsed_args.apply_changes and pending_updates:
        for set_clauses, set_values, update_id in pending_updates:
            db_conn.execute("UPDATE tabs SET %s WHERE id = ?" % ", ".join(set_clauses),
                            set_values + [update_id])
        db_conn.commit()
        print("# committed %d tab update(s)" % len(pending_updates), file=sys.stderr)
    elif not parsed_args.apply_changes:
        print("# dry run - re-run with --apply to persist %d change(s)" % len(pending_updates),
              file=sys.stderr)

    db_conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
