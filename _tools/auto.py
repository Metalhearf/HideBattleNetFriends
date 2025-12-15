import re
import requests
import zipfile
from bs4 import BeautifulSoup
from pathlib import Path

WIKI_URL = "https://warcraft.wiki.gg/wiki/Public_client_builds"
ADDON_DIR = Path("HideBattleNetFriends")
TOC_PATH = ADDON_DIR / "HideBattleNetFriends.toc"
ZIP_NAME = "HideBattleNetFriends.zip"

# Types live que l’on supporte (IMPORTANT: pas de PTR)
SUPPORTED_SERVERS = {
    "Retail": "Retail",
    "Classic": "Classic",
    "Classic Era": "Classic Era",
}

EXCLUDE_KEYWORDS = ["ptr", "beta", "alpha", "test"]

def fetch_html():
    r = requests.get(WIKI_URL)
    r.raise_for_status()
    return r.text

def version_key(v):
    return [int(x) for x in v.split(".")]

def parse_current_builds(html):
    soup = BeautifulSoup(html, "html.parser")
    for table in soup.find_all("table"):
        headers = [th.get_text(strip=True) for th in table.find_all("th")]
        if {"Server", "Version", "Interface"}.issubset(headers):
            rows = []
            for tr in table.find_all("tr")[1:]:
                tds = [td.get_text(strip=True) for td in tr.find_all("td")]
                if len(tds) < 5:
                    continue
                server, expansion, _, version, interface = tds[:5]
                rows.append({
                    "server": server,
                    "version": version,
                    "interface": interface,
                })
            return rows
    return []

def is_live(server_name):
    s = server_name.lower()
    return not any(k in s for k in EXCLUDE_KEYWORDS)

def bump_version(version):
    major, minor, patch = version.split(".")
    return f"{major}.{minor}.{int(patch) + 1}"

def update_toc(interfaces, game_versions):
    lines = TOC_PATH.read_text().splitlines()
    new_lines = []

    old_version = None
    new_version = None

    for line in lines:
        if line.startswith("## Interface:"):
            new_lines.append(f"## Interface: {', '.join(interfaces)}")
        elif line.startswith("## Version:"):
            old_version = line.split(":", 1)[1].strip()
            new_version = bump_version(old_version)
            new_lines.append(f"## Version: {new_version}")
        else:
            new_lines.append(line)

    TOC_PATH.write_text("\n".join(new_lines) + "\n")
    return old_version, new_version

def zip_addon():
    if Path(ZIP_NAME).exists():
        Path(ZIP_NAME).unlink()

    with zipfile.ZipFile(ZIP_NAME, "w", zipfile.ZIP_DEFLATED) as z:
        for file in ADDON_DIR.rglob("*"):
            z.write(file, file.relative_to(ADDON_DIR.parent))

def main():
    print("📥 Fetching wiki data…")
    html = fetch_html()
    builds = parse_current_builds(html)

    latest = {}
    for b in builds:
        for key, name in SUPPORTED_SERVERS.items():
            if b["server"].startswith(name) and is_live(b["server"]):
                if key not in latest or version_key(b["version"]) > version_key(latest[key]["version"]):
                    latest[key] = b

    interfaces = []
    game_versions = []

    print("\n✅ Selected LIVE versions:")
    for k, b in latest.items():
        print(f"- {k}: {b['version']} → {b['interface']}")
        interfaces.append(b["interface"])
        game_versions.append(b["version"])

    old_v, new_v = update_toc(interfaces, game_versions)
    zip_addon()

    print("\n🎉 Done!\n")
    print("➡ Upload here:")
    print("https://authors.curseforge.com/#/projects/490332/files/create\n")
    print("Game Versions:")
    for v in game_versions:
        print(f"- {v}")
    print("\nDisplay Name:")
    print(new_v)
    print("\nRelease Type:")
    print("Release")
    print("\nChangelog:")
    print("Version bump.")

if __name__ == "__main__":
    main()
