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

# Each server type maps to a TOC file suffix (None = main .toc).
# "match" receives the lowercased Server and Expansion columns of the wiki table.
# "prerelease" lets a type match a row SKIP_KEYWORDS would otherwise drop, for a
# client that only exists as a test/beta cluster so far.
SERVER_TYPES = [
    {"key": "retail",       "suffix": None,      "match": lambda s, e: "retail" in s and "ptr" not in s},
    {"key": "classic",      "suffix": "Mists",   "match": lambda s, e: "classic" in s and "era" not in s and "anniversary" not in s and "ptr" not in s and "forever" not in e},
    {"key": "classic_era",  "suffix": "Classic",  "match": lambda s, e: "classic era" in s and "anniversary" not in s and "ptr" not in s},
    # The wiki names this row "Classic Anniversary", not "Classic Era / Anniversary":
    # matching on "classic era" never fired. "era" still excludes the
    # "Classic Era / Anniversary Edition PTR" row, which "ptr" also covers.
    {"key": "classic_anniversary", "suffix": "TBC", "match": lambda s, e: "anniversary" in s and "era" not in s and "ptr" not in s},
    # Until it releases on 2026-11-04, Forever (codename Camelot) only runs on the
    # Classic Beta cluster, so it is matched on its expansion, not its server name.
    {"key": "forever",      "suffix": "Camelot", "match": lambda s, e: "forever" in e, "prerelease": True},
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
            expansion_lower = row["version"].lower()
            if not stype["match"](name_lower, expansion_lower):
                continue
            if any(kw in name_lower for kw in SKIP_KEYWORDS) and not stype.get("prerelease"):
                continue
            if stype["key"] not in result:
                result[stype["key"]] = row
                break

    for key, info in result.items():
        raw = info["interface"]
        info["interface_numeric"] = version_to_interface(raw) if "." in raw else raw

    print(f"Found {len(result)}/{len(SERVER_TYPES)} server versions:")
    for stype in SERVER_TYPES:
        key = stype["key"]
        if key in result:
            info = result[key]
            print(f"  {key}: {info['version']} (interface {info['interface_numeric']})")
        else:
            print(f"  {key}: NOT FOUND -> {toc_path(stype['suffix']).name} would stay frozen")

    return result


def read_current_interfaces() -> tuple[dict[str, str], str, dict[str, str]]:
    """Read current interface from each TOC file.
    Returns ({server_key: interface}, addon_version, {toc_filename: version}).
    The addon version is taken from the retail TOC (canonical source); the per-file
    versions let the caller prove every shipped TOC carries the same number.
    """
    interfaces = {}
    versions = {}
    version = "1.0.0"

    for stype in SERVER_TYPES:
        path = toc_path(stype["suffix"])
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("## Interface:"):
                interfaces[stype["key"]] = line.split(":", 1)[1].strip()
            elif line.startswith("## Version:"):
                versions[path.name] = line.split(":", 1)[1].strip()
                if stype["key"] == "retail":
                    version = line.split(":", 1)[1].strip()

    return interfaces, version, versions


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


def verify_declarations(web: dict[str, dict], toc_versions: dict[str, str]):
    """Refuse to release on a declaration that no longer lines up.

    A release tool that looks for five things, finds four and stays quiet freezes a
    shipped file for as long as nobody happens to look. Each check below is a way a
    TOC silently stops being maintained, so each one stops the run instead of
    warning: a red job is fixed in one line, a frozen TOC is found months later.
    """
    problems = []

    for stype in SERVER_TYPES:
        if stype["key"] not in web:
            problems.append(
                f"no wiki row matched server type '{stype['key']}' -> "
                f"{toc_path(stype['suffix']).name} can never be updated. "
                f"The wiki most likely renamed the row; fix its 'match' in SERVER_TYPES."
            )

    known_tocs = {toc_path(st["suffix"]).name for st in SERVER_TYPES}
    for orphan in sorted(t.name for t in ADDON_DIR.glob("*.toc") if t.name not in known_tocs):
        problems.append(
            f"{orphan} is shipped but no SERVER_TYPES entry drives it -> "
            f"it will never be updated. Add a server type for it, or delete the file."
        )

    if len(set(toc_versions.values())) > 1:
        detail = ", ".join(f"{name}={ver}" for name, ver in sorted(toc_versions.items()))
        problems.append(f"TOC versions disagree, the release would be inconsistent: {detail}")

    if problems:
        print("\nERROR: declarations are out of sync, refusing to release:")
        for problem in problems:
            print(f"  - {problem}")
        sys.exit(1)


def run(apply: bool = False):
    web = fetch_versions()
    current, addon_version, toc_versions = read_current_interfaces()
    verify_declarations(web, toc_versions)

    # Compare
    changes = []
    for stype in SERVER_TYPES:
        key = stype["key"]
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

    # Apply: verify_declarations guarantees the wiki gave us every type, so every
    # existing TOC gets both the fresh interface and the one new version.
    new_version = bump_patch(addon_version)
    for stype in SERVER_TYPES:
        path = toc_path(stype["suffix"])
        if not path.exists():
            continue
        new_iface = web[stype["key"]]["interface_numeric"]
        update_toc(path, new_iface, new_version)
        print(f"  Updated {path.name}: interface={new_iface}, version={new_version}")

    print(f"\nVersion bumped: v{addon_version} -> v{new_version}")
    build_zip(new_version)


def main():
    parser = argparse.ArgumentParser(description="Update HideBattleNetFriends TOC files with latest WoW interface versions")
    parser.add_argument("--apply", action="store_true", help="Write changes (default is dry-run)")
    args = parser.parse_args()
    run(apply=args.apply)


if __name__ == "__main__":
    main()
