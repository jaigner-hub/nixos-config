#!/usr/bin/env python3
"""Refresh XMLTV guides + Jellyfin M3U for the HDHomeRun tuner.

Pulls two epgshare01 feeds (US locals + national diginets), then queries the
HDHomeRun's lineup and emits an M3U whose tvg-id values point at the matching
XMLTV channel ids. Jellyfin auto-maps guide data when the M3U's tvg-id == an
XMLTV channel id, so this script replaces the manual per-channel mapping in
the Jellyfin UI.

All outputs are written via tmp -> atomic mv so Jellyfin never reads a
half-written file.
"""

import gzip
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

HDHOMERUN_URL = "http://10.0.0.205/lineup.json"
EPG_LOCALS_URL = "https://epgshare01.online/epgshare01/epg_ripper_US_LOCALS1.xml.gz"
EPG_US2_URL = "https://epgshare01.online/epgshare01/epg_ripper_US2.xml.gz"

OUT_DIR = Path("/mnt/storage/chill.institute/epg")
LOCALS_XML = OUT_DIR / "epg_ripper_US_LOCALS1.xml"
US2_XML = OUT_DIR / "epg_ripper_US2.xml"
M3U = OUT_DIR / "hdhomerun.m3u"

HTTP_TIMEOUT = 600

# Marketing name -> FCC callsign for Chicago .1 mains where HDHomeRun reports
# a brand instead of the callsign. Most stations report the callsign already.
CHICAGO_MAINS = {
    "CBS2":  "WBBM",
    "NBC5":  "WMAQ",
    "WGN":   "WGN",
    "The U": "WCIU",
    "ION":   "WCPX",
    "ESTV":  "WOCK",
}

# HDHomeRun GuideName -> XMLTV id in the US2 (diginets) feed. Built by
# inspecting epg_ripper_US2.xml. Unmapped diginets (None) appear in Jellyfin
# without guide data; map them by hand if needed.
SUBCHANNEL_MAP = {
    "StartTV":  "Start.TV.Network.us2",
    "DABL":     "Dabl.Network.LLC.us2",
    "365BLK":   "365BLK.us2",
    "Comet":    "Comet.us2",
    "COZI":     "COZI.TV.us2",
    "CRIMES":   "American.Crimes.us2",
    "OXYGEN":   "Oxygen.True.Crime.HD.us2",
    "CHARGE":   "CHARGE!.us2",
    "ANTENNA":  "Antenna.TV.us2",
    "GRIT":     "Grit.us2",
    "REWIND":   "Rewind.TV.us2",
    "TheNest":  "The.Nest.us2",
    "Create":   "Create.us2",
    "Kids":     "PBS.Kids.Stream.us2",
    "HEROES":   "Heroes.and.Icons.Network.SD.us2",
    "STORY":    "Story.us2",
    "CATCHY":   "Catchy.Comedy.us2",
    "TOONS":    "MeTV.Toons.us2",
    "Buzzr":    "BUZZR.Stream.us2",
    "ROAR":     "ROAR.TV.us2",
    "Bounce":   "Bounce.TV.us2",
    "CourtTV":  "Court.TV.us2",
    "Laff":     "Laff.us2",
    "BUSTED":   "Busted.TV.us2",
    "HSN":      "HSN.Home.Shopping.Network.HD.us2",
    "NHK":      "NHK.World.TV.us2",
    "ION MYS":  "ION.Mystery.us2",
    "Quest":    "Quest.us2",
    "QVC":      "QVC.HD.us2",
}


def http_get(url, timeout=HTTP_TIMEOUT):
    req = urllib.request.Request(url, headers={"User-Agent": "jellyfin-epg/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def atomic_write_bytes(path, data):
    tmp = path.with_suffix(path.suffix + ".new")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def atomic_write_text(path, text):
    tmp = path.with_suffix(path.suffix + ".new")
    tmp.write_text(text)
    os.replace(tmp, path)


def download_xmltv(url, dest):
    print(f"  Downloading {url}")
    gz = http_get(url)
    xml = gzip.decompress(gz)
    atomic_write_bytes(dest, xml)
    print(f"  Wrote {dest} ({len(xml) // (1024 * 1024)} MiB)")


def extract_channel_ids(xml_path):
    """Cheap streaming parse: pull every `id="..."` from <channel> open tags."""
    ids = set()
    pat = re.compile(rb'<channel\s+id="([^"]+)"')
    with xml_path.open("rb") as f:
        for line in f:
            m = pat.search(line)
            if m:
                ids.add(m.group(1).decode())
    return ids


def try_callsign(callsign, ids):
    for cand in (
        f"{callsign}-DT.us_locals1",
        f"{callsign}.us_locals1",
        f"{callsign}-TV.us_locals1",
        f"{callsign}-CD.us_locals1",
        f"{callsign}-LD.us_locals1",
        f"{callsign}-LP.us_locals1",
    ):
        if cand in ids:
            return cand
    return None


def normalize_main(name):
    n = re.sub(r"[-\s]?HD$", "", name.strip(), flags=re.IGNORECASE)
    return re.sub(r"[-\s]?DT$", "", n, flags=re.IGNORECASE)


def resolve(ch, locals_ids, us2_ids):
    name = ch["GuideName"]
    number = ch["GuideNumber"]
    if number.endswith(".1"):
        bare = normalize_main(name)
        first = bare.split()[0] if bare.split() else bare
        callsign = CHICAGO_MAINS.get(bare, CHICAGO_MAINS.get(first, bare))
        callsign = re.sub(r"-(DT|HD)$", "", callsign)
        match = try_callsign(callsign, locals_ids)
        if match:
            return match
        return try_callsign(first, locals_ids)

    target = SUBCHANNEL_MAP.get(name)
    if target and target in us2_ids:
        return target
    return None


def write_m3u(lineup, locals_ids, us2_ids):
    lines = ["#EXTM3U"]
    matched = 0
    unmatched = []
    for ch in lineup:
        num = ch["GuideNumber"]
        name = ch["GuideName"]
        url = ch["URL"]
        xmltv_id = resolve(ch, locals_ids, us2_ids)
        tvg_attr = ""
        if xmltv_id:
            matched += 1
            tvg_attr = f' tvg-id="{xmltv_id}"'
        else:
            unmatched.append(f"{num} {name}")
        lines.append(
            f'#EXTINF:-1 tvg-chno="{num}" tvg-name="{name}"{tvg_attr},{name}'
        )
        lines.append(url)
    atomic_write_text(M3U, "\n".join(lines) + "\n")
    print(f"Wrote {M3U}: {matched}/{len(lineup)} channels matched")
    if unmatched:
        print(f"Unmatched ({len(unmatched)}): {', '.join(unmatched)}")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print("Refreshing XMLTV feeds")
    download_xmltv(EPG_LOCALS_URL, LOCALS_XML)
    download_xmltv(EPG_US2_URL, US2_XML)

    print("Indexing channel ids")
    locals_ids = extract_channel_ids(LOCALS_XML)
    us2_ids = extract_channel_ids(US2_XML)
    print(f"  US_LOCALS1: {len(locals_ids)} channels")
    print(f"  US2:        {len(us2_ids)} channels")

    print(f"Fetching HDHomeRun lineup from {HDHOMERUN_URL}")
    lineup = json.loads(http_get(HDHOMERUN_URL, timeout=30))
    print(f"  {len(lineup)} channels on tuner")

    print("Generating M3U")
    write_m3u(lineup, locals_ids, us2_ids)


if __name__ == "__main__":
    main()
