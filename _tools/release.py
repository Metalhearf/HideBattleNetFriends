#!/usr/bin/env python3
"""
HideBattleNetFriends Release Tool
Fetches latest WoW interface versions and updates the addon TOC files.
"""

import argparse
import sys
from pathlib import Path
from zipfile import ZipFile

import requests
from bs4 import BeautifulSoup

WIKI_URL = "https://warcraft.wiki.gg/wiki/Public_client_builds"
PROJECT_ROOT = Path(__file__).resolve().parent.parent
ADDON_NAME = "HideBattleNetFriends"
ADDON_DIR = PROJECT_ROOT / ADDON_NAME

# Each server type maps to a TOC file suffix (None = main .toc)
SERVER_TYPES = [
    {"key": "retail",       "suffix": None,      "match": lambda s: "retail" in s and "ptr" not in s},
    {"key": "classic",      "suffix": "Mists",   "match": lambda s: "classic" in s and "era" not in s and "ptr" not in s},
    {"key": "classic_era",  "suffix": "Classic",  "match": lambda s: "classic era" in s and "anniversary" not in s and "ptr" not in s},
    {"key": "classic_anniversary", "suffix": "TBC", "match": lambda s: "classic era" in s and "anniversary" in s and "ptr" not in s},
]

SKIP_KEYWORDS = {"alpha", "beta", "test"}


def version_to_interface(version: str) -> str:
    """'12.0.1' -> '120001', '5.5.3' -> '50503', '1.15.8' -> '11508'"""
    parts = version.split(".")
    if len(parts) == 3:
        return str(int(parts[0]) * 10000 + int(parts[1]) * 100 + int(parts[2]))
    return version


def interface_to_version(interface: str) -> str:
    """'120001' -> '12.0.1', '50503' -> '5.5.3'"""
    try:
        n = int(interface)
        return f"{n // 10000}.{(n % 10000) // 100}.{n % 100}"
    except ValueError:
        return interface


def toc_path(suffix: str | None) -> Path:
    if suffix:
        return ADDON_DIR / f"{ADDON_NAME}_{suffix}.toc"
    return ADDON_DIR / f"{ADDON_NAME}.toc"


def fetch_versions() -> dict[str, dict]:
    """Fetch latest interface versions from the wiki."""
    print(f"Fetching {WIKI_URL} ...")
    resp = requests.get(WIKI_URL, timeout=30)
    resp.raise_for_status()

    soup = BeautifulSoup(resp.text, "html.parser")

    rows = []
    for table in soup.find_all("table"):
        headers = [th.get_text(strip=True) for th in table.find_all("th")]
        if {"Server", "Version", "Interface"}.issubset(headers):
            for tr in table.find_all("tr")[1:]:
                tds = [td.get_text(strip=True) for td in tr.find_all("td")]
                if len(tds) >= 4:
                    rows.append({
                        "server": tds[0],
                        "version": tds[2],
                        "interface": tds[3],
                    })
            break

    if not rows:
        print("ERROR: Could not find version table on wiki page")
        sys.exit(1)

    result = {}
    for stype in SERVER_TYPES:
        for row in rows:
            name_lower = row["server"].lower()
            if any(kw in name_lower for kw in SKIP_KEYWORDS):
                continue
            if stype["match"](name_lower) and stype["key"] not in result:
                result[stype["key"]] = row
                break

    for key, info in result.items():
        raw = info["interface"]
        info["interface_numeric"] = version_to_interface(raw) if "." in raw else raw

    print(f"Found {len(result)} server versions:")
    for key, info in result.items():
        print(f"  {key}: {info['version']} (interface {info['interface_numeric']})")

    return result


def read_current_interfaces() -> tuple[dict[str, str], str]:
    """Read current interface from each TOC file.
    Returns ({server_key: interface}, addon_version).
    The addon version is taken from the retail TOC (canonical source).
    """
    interfaces = {}
    version = "1.0.0"

    for stype in SERVER_TYPES:
        path = toc_path(stype["suffix"])
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("## Interface:"):
                interfaces[stype["key"]] = line.split(":", 1)[1].strip()
            elif line.startswith("## Version:") and stype["key"] == "retail":
                version = line.split(":", 1)[1].strip()

    return interfaces, version


def bump_patch(version: str) -> str:
    parts = version.split(".")
    if len(parts) >= 3:
        parts[2] = str(int(parts[2]) + 1)
    return ".".join(parts)


def update_toc(path: Path, interface: str | None, version: str):
    """Update a single TOC file with a new version; rewrite interface only if provided."""
    content = path.read_text(encoding="utf-8")
    lines = content.splitlines()
    new_lines = []
    for line in lines:
        if line.startswith("## Interface:") and interface is not None:
            new_lines.append(f"## Interface: {interface}")
        elif line.startswith("## Version:"):
            new_lines.append(f"## Version: {version}")
        else:
            new_lines.append(line)
    path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")


def build_zip(version: str) -> Path:
    zip_path = PROJECT_ROOT / f"{ADDON_NAME}-{version}.zip"
    with ZipFile(zip_path, "w") as zf:
        for file in sorted(ADDON_DIR.rglob("*")):
            if file.is_file():
                arcname = f"{ADDON_NAME}/{file.relative_to(ADDON_DIR)}"
                zf.write(file, arcname)
    print(f"Zip created: {zip_path.name} ({zip_path.stat().st_size} bytes)")
    return zip_path


def run(apply: bool = False):
    web = fetch_versions()
    current, addon_version = read_current_interfaces()

    # Compare
    changes = []
    for stype in SERVER_TYPES:
        key = stype["key"]
        if key not in web:
            continue
        new_iface = web[key]["interface_numeric"]
        old_iface = current.get(key, "N/A")

        if old_iface != new_iface:
            old_display = f"{old_iface} ({interface_to_version(old_iface)})" if old_iface != "N/A" else "N/A"
            new_display = f"{new_iface} ({interface_to_version(new_iface)})"
            print(f"  {key}: {old_display} -> {new_display}")
            changes.append(stype)
        else:
            print(f"  {key}: {old_iface} (up to date)")

    if not changes:
        print("\nAlready up to date.")
        return

    if not apply:
        print(f"\n{len(changes)} change(s) detected. Use --apply to write.")
        return

    # Apply: bump version on every existing TOC, update interface only where the wiki gave us one
    new_version = bump_patch(addon_version)
    for stype in SERVER_TYPES:
        path = toc_path(stype["suffix"])
        if not path.exists():
            continue
        new_iface = web[stype["key"]]["interface_numeric"] if stype["key"] in web else None
        update_toc(path, new_iface, new_version)
        iface_note = new_iface if new_iface is not None else "unchanged"
        print(f"  Updated {path.name}: interface={iface_note}, version={new_version}")

    print(f"\nVersion bumped: v{addon_version} -> v{new_version}")
    build_zip(new_version)


def main():
    parser = argparse.ArgumentParser(description="Update HideBattleNetFriends TOC files with latest WoW interface versions")
    parser.add_argument("--apply", action="store_true", help="Write changes (default is dry-run)")
    args = parser.parse_args()
    run(apply=args.apply)


if __name__ == "__main__":
    main()
