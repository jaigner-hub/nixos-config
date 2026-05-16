#!/usr/bin/env python3
"""Sync files from put.io to local NAS, tracking by file ID to handle local renames."""

import argparse
import json
import os
import subprocess
import sys
import time
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests

CONFIG_PATH = os.path.expanduser("~/.config/putio-sync/config.json")
DEFAULT_DEST = "/mnt/storage"
API_BASE = "https://api.put.io/v2"


def load_config(token_override=None):
    if token_override:
        return {"oauth_token": token_override}
    token = os.environ.get("PUTIO_TOKEN")
    if token:
        return {"oauth_token": token}
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH) as f:
            return json.load(f)
    print(f"No config found. Create {CONFIG_PATH} with {{\"oauth_token\": \"YOUR_TOKEN\"}}")
    print("Or set PUTIO_TOKEN env var, or use --token flag.")
    sys.exit(1)


def load_manifest(dest):
    path = os.path.join(dest, ".putio-sync-manifest.json")
    if os.path.exists(path):
        result = subprocess.run(
            ["sudo", "-u", "jellyfin", "cat", path],
            capture_output=True, text=True,
        )
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout)
    return {}


def save_manifest(dest, manifest):
    path = os.path.join(dest, ".putio-sync-manifest.json")
    data = json.dumps(manifest, indent=2)
    result = subprocess.run(
        ["sudo", "-u", "jellyfin", "tee", path],
        input=data, text=True, capture_output=True,
    )
    if result.returncode != 0:
        print(f"WARNING: Failed to save manifest: {result.stderr}")


def api_get(endpoint, token, params=None):
    if params is None:
        params = {}
    params["oauth_token"] = token
    resp = requests.get(f"{API_BASE}{endpoint}", params=params, timeout=30)
    resp.raise_for_status()
    return resp.json()


def list_files_recursive(token, parent_id=0, path_prefix=""):
    """Walk put.io folder tree in parallel, returning list of files."""
    results = []
    lock = threading.Lock()
    _list_folder(token, parent_id, path_prefix, results, lock, max_workers=8)
    return results


def _list_folder(token, parent_id, path_prefix, results, lock, max_workers=8):
    """Parallel BFS folder walk using a thread pool."""
    data = api_get("/files/list", token, {"parent_id": parent_id, "per_page": 1000})
    folders = []
    for item in data.get("files", []):
        rel_path = os.path.join(path_prefix, item["name"]) if path_prefix else item["name"]
        if item["file_type"] == "FOLDER":
            folders.append((item["id"], rel_path))
        else:
            item["_rel_path"] = rel_path
            with lock:
                results.append(item)

    if folders:
        with ThreadPoolExecutor(max_workers=max_workers) as pool:
            futures = {
                pool.submit(_list_folder, token, fid, fpath, results, lock, max_workers): fpath
                for fid, fpath in folders
            }
            for future in as_completed(futures):
                future.result()  # propagate exceptions


def get_download_url(file_id, token):
    data = api_get(f"/files/{file_id}/url", token)
    return data.get("url")


def download_file(url, local_path):
    """Download using curl with resume support, running as jellyfin user. Returns True on success."""
    subprocess.run(
        ["sudo", "-u", "jellyfin", "mkdir", "-p", os.path.dirname(local_path)],
        check=True,
    )
    result = subprocess.run(
        ["sudo", "-u", "jellyfin", "curl", "-C", "-", "-L", "--progress-bar", "-o", local_path, url],
        stdin=subprocess.DEVNULL,
    )
    return result.returncode == 0


def format_size(size_bytes):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(size_bytes) < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} PB"


def main():
    parser = argparse.ArgumentParser(description="Sync files from put.io to local storage")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be downloaded")
    parser.add_argument("--seed", action="store_true", help="Seed manifest by matching existing local files to put.io by size")
    parser.add_argument("--dest", default=DEFAULT_DEST, help=f"Download destination (default: {DEFAULT_DEST})")
    parser.add_argument("--token", help="OAuth token (overrides config file)")
    args = parser.parse_args()

    config = load_config(args.token)
    token = config["oauth_token"]

    # Verify API connection
    try:
        account = api_get("/account/info", token)
        username = account.get("info", {}).get("username", "unknown")
        print(f"Connected as: {username}")
    except requests.exceptions.HTTPError as e:
        print(f"API auth failed: {e}")
        sys.exit(1)

    manifest = load_manifest(args.dest)

    print("Scanning put.io files...")
    all_files = list_files_recursive(token)
    print(f"Found {len(all_files)} files on put.io")

    if args.seed:
        # Build map of local file sizes -> paths
        print(f"Scanning local files in {args.dest}...")
        local_by_size = {}
        # Use sudo -u jellyfin find to list files accessible by jellyfin
        result = subprocess.run(
            ["sudo", "-u", "jellyfin", "find", args.dest, "-type", "f", "-printf", "%s\\t%p\\n"],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            for line in result.stdout.strip().splitlines():
                if not line:
                    continue
                sz_str, fpath = line.split("\t", 1)
                if os.path.basename(fpath) == ".putio-sync-manifest.json":
                    continue
                try:
                    sz = int(sz_str)
                except ValueError:
                    continue
                local_by_size.setdefault(sz, []).append(fpath)

        seeded = 0
        ambiguous = 0
        for f in all_files:
            fid = str(f["id"])
            if fid in manifest:
                continue
            sz = f.get("size", 0)
            matches = local_by_size.get(sz, [])
            # Only match if exactly one local file has this size
            if len(matches) == 1:
                local_path = matches[0]
                rel = os.path.relpath(local_path, args.dest)
                manifest[fid] = {
                    "name": f["name"],
                    "size": sz,
                    "downloaded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "local_path": rel,
                    "seeded": True,
                }
                print(f"  Matched: {f['name']} ({format_size(sz)}) -> {rel}")
                seeded += 1
            elif len(matches) > 1:
                ambiguous += 1

        save_manifest(args.dest, manifest)
        print(f"\nSeeded {seeded} files into manifest. {ambiguous} skipped (ambiguous size match).")
        remaining = len([f for f in all_files if str(f["id"]) not in manifest])
        print(f"{remaining} files still unmatched (will download on next sync).")
        return

    new_files = [f for f in all_files if str(f["id"]) not in manifest]
    skipped = len(all_files) - len(new_files)
    print(f"New: {len(new_files)}, Already synced: {skipped}")

    if not new_files:
        print("Nothing to download.")
        return

    if args.dry_run:
        print("\n-- Dry run: would download --")
        total_size = 0
        for f in new_files:
            size = f.get("size", 0)
            total_size += size
            print(f"  {f['_rel_path']} ({format_size(size)})")
        print(f"\nTotal: {format_size(total_size)}")
        return

    downloaded = 0
    failed = 0
    for i, f in enumerate(new_files, 1):
        file_id = f["id"]
        rel_path = f["_rel_path"]
        size = f.get("size", 0)
        local_path = os.path.join(args.dest, rel_path)

        print(f"\n[{i}/{len(new_files)}] {rel_path} ({format_size(size)})")

        try:
            url = get_download_url(file_id, token)
            if not url:
                print(f"  SKIP: no download URL for {rel_path}")
                failed += 1
                continue
        except requests.exceptions.HTTPError as e:
            print(f"  ERROR getting URL: {e}")
            failed += 1
            continue

        if download_file(url, local_path):
            manifest[str(file_id)] = {
                "name": f["name"],
                "size": size,
                "downloaded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "local_path": rel_path,
            }
            save_manifest(args.dest, manifest)
            downloaded += 1
            print(f"  OK")
        else:
            print(f"  FAILED")
            failed += 1

    print(f"\nDone. Downloaded: {downloaded}, Failed: {failed}, Skipped: {skipped}")


if __name__ == "__main__":
    main()
