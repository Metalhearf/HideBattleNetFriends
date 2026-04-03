#!/usr/bin/env python3
"""
HideBattleNetFriends TOC Updater
Fetches latest WoW interface versions and updates the addon TOC file.
"""

import argparse
import sys
from pathlib import Path
from zipfile import ZipFile

import requests
from bs4 import BeautifulSoup

WIKI_URL = "https://warcraft.wiki.gg/wiki/Public_client_builds"
PROJECT_ROOT = Path(__file__).resolve().parent.parent
ADDON_DIR = PROJECT_ROOT / "HideBattleNetFriends"
TOC_PATH = ADDON_DIR / "HideBattleNetFriends.toc"
ADDON_NAME = "HideBattleNetFriends"

# Server types we care about, in TOC order
SERVER_TYPES = [
    {"key": "retail",    "match": lambda s: "retail" in s and "ptr" not in s},
    {"key": "classic",   "match": lambda s: "classic" in s and "era" not in s and "ptr" not in s},
    {"key": "classic_era", "match": lambda s: "classic era" in s and "anniversary" not in s and "ptr" not in s},
    {"key": "classic_anniversary_ptr", "match": lambda s: "classic era" in s and "anniversary" in s and "ptr" in s},
]

SKIP_KEYWORDS = {"alpha", "beta", "test"}


def version_to_interface(version: str) -> str:
    """Convert dotted version to WoW numeric interface format.
    '12.0.1' -> '120001', '5.5.3' -> '50503', '1.15.8' -> '11508'
    """
    parts = version.split(".")
    if len(parts) == 3:
        return str(int(parts[0]) * 10000 + int(parts[1]) * 100 + int(parts[2]))
    return version


def interface_to_version(interface: str) -> str:
    """Convert WoW numeric interface format to dotted version.
    '120001' -> '12.0.1', '50503' -> '5.5.3', '11508' -> '1.15.8'
    """
    try:
        n = int(interface)
        return f"{n // 10000}.{(n % 10000) // 100}.{n % 100}"
    except ValueError:
        return interface


def fetch_versions() -> dict[str, dict]:
    """Fetch latest interface versions from the wiki.
    Returns {server_key: {"server": name, "version": str, "interface": str}}.
    """
    print(f"Fetching {WIKI_URL} ...")
    resp = requests.get(WIKI_URL, timeout=30)
    resp.raise_for_status()

    soup = BeautifulSoup(resp.text, "html.parser")

    # Find the table with the right headers
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

    # Classify rows into server types (first match wins per type)
    result = {}
    for stype in SERVER_TYPES:
        for row in rows:
            name_lower = row["server"].lower()
            if any(kw in name_lower for kw in SKIP_KEYWORDS):
                continue
            if stype["match"](name_lower) and stype["key"] not in result:
                result[stype["key"]] = row
                break

    # Normalize interface to numeric TOC format
    for key, info in result.items():
        raw = info["interface"]
        info["interface_numeric"] = version_to_interface(raw) if "." in raw else raw

    print(f"Found {len(result)} server versions:")
    for key, info in result.items():
        print(f"  {key}: {info['version']} (interface {info['interface_numeric']})")

    return result


def read_toc() -> tuple[list[str], str]:
    """Read current TOC file.
    Returns (current_interfaces: list[str], addon_version: str).
    """
    if not TOC_PATH.exists():
        print(f"ERROR: TOC not found at {TOC_PATH}")
        sys.exit(1)

    content = TOC_PATH.read_text(encoding="utf-8")
    interfaces = []
    version = "1.0.0"

    for line in content.splitlines():
        if line.startswith("## Interface:"):
            interfaces = [i.strip() for i in line.split(":", 1)[1].split(",")]
        elif line.startswith("## Version:"):
            version = line.split(":", 1)[1].strip()

    return interfaces, version


def bump_patch(version: str) -> str:
    """1.2.3 -> 1.2.4"""
    parts = version.split(".")
    if len(parts) >= 3:
        parts[2] = str(int(parts[2]) + 1)
    return ".".join(parts)


def build_zip(version: str) -> Path:
    """Create the addon zip. Returns the zip path."""
    zip_path = PROJECT_ROOT / f"{ADDON_NAME}-{version}.zip"
    with ZipFile(zip_path, "w") as zf:
        for file in sorted(ADDON_DIR.rglob("*")):
            if file.is_file():
                arcname = f"{ADDON_NAME}/{file.relative_to(ADDON_DIR)}"
                zf.write(file, arcname)
    print(f"Zip created: {zip_path.name} ({zip_path.stat().st_size} bytes)")
    return zip_path


def run(include_ptr: bool = True, apply: bool = False):
    web = fetch_versions()
    current_interfaces, addon_version = read_toc()

    # Build the new interface list from web data, in SERVER_TYPES order
    # Only include types that were already in the TOC or are non-PTR
    new_interfaces = []
    changes = []

    for stype in SERVER_TYPES:
        key = stype["key"]
        if key not in web:
            continue
        if key == "classic_anniversary_ptr" and not include_ptr:
            continue

        new_iface = web[key]["interface_numeric"]
        new_interfaces.append(new_iface)

    # Compare
    print(f"\nCurrent interfaces: {', '.join(current_interfaces)}")
    print(f"Latest  interfaces: {', '.join(new_interfaces)}")

    if current_interfaces == new_interfaces:
        print("\nAlready up to date.")
        return

    # Show what changed
    print("\nChanges detected:")
    idx = 0
    for stype in SERVER_TYPES:
        key = stype["key"]
        if key not in web:
            continue
        if key == "classic_anniversary_ptr" and not include_ptr:
            continue

        new_iface = web[key]["interface_numeric"]
        old_iface = current_interfaces[idx] if idx < len(current_interfaces) else "N/A"
        idx += 1

        if old_iface != new_iface:
            old_display = f"{old_iface} ({interface_to_version(old_iface)})"
            new_display = f"{new_iface} ({interface_to_version(new_iface)})"
            print(f"  {key}: {old_display} -> {new_display}")
            changes.append(key)

    if not apply:
        print("\nDry run. Use --apply to write changes.")
        return

    # Apply changes
    new_version = bump_patch(addon_version)
    content = TOC_PATH.read_text(encoding="utf-8")
    lines = content.splitlines()
    new_lines = []

    for line in lines:
        if line.startswith("## Interface:"):
            new_lines.append(f"## Interface: {', '.join(new_interfaces)}")
        elif line.startswith("## Version:"):
            new_lines.append(f"## Version: {new_version}")
        else:
            new_lines.append(line)

    TOC_PATH.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
    print(f"\nTOC updated: v{addon_version} -> v{new_version}")
    print(f"Interfaces: {', '.join(new_interfaces)}")

    build_zip(new_version)


def main():
    parser = argparse.ArgumentParser(description="Update HideBattleNetFriends TOC with latest WoW interface versions")
    parser.add_argument("--no-ptr", action="store_true", help="Exclude PTR/Anniversary PTR versions")
    parser.add_argument("--apply", action="store_true", help="Write changes to TOC (default is dry-run)")
    args = parser.parse_args()

    run(include_ptr=not args.no_ptr, apply=args.apply)


if __name__ == "__main__":
    main()
