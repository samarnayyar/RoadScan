#!/usr/bin/env python3
"""
Bake the road network around each launch-screen area into
assets/area_roads.json.

    python tool/fetch_area_roads.py

Why vector instead of the raster thumbnails
-------------------------------------------
The cards originally showed baked OSM raster tiles. That looked fine but made
the roads un-styleable: in OSM's standard rendering the carriageway is white
and the background is a near-white beige, so the two cannot be separated by
luminance after the fact. Recolouring roads -- bright in dark mode, near-black
in light mode -- is impossible once it is a JPEG.

Fetching the geometry instead gives full control at draw time, is sharp at any
card size, and is far smaller than eight JPEGs.

Output shape, kept deliberately compact because it ships in the APK:

    {
      "<area id>": {
        "c": [lon, lat],               # centre, for normalising
        "s": <span in degrees>,        # half-extent used when baking
        "r": [                         # roads
          {"w": <weight 0-2>, "p": [[x, y], ...]}   # x,y normalised 0..1
        ]
      }
    }

Weight buckets the OSM class into three tiers so the card can draw a hierarchy
(trunk roads thicker than lanes) without shipping the class strings.
"""

from __future__ import annotations

import json
import math
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "area_roads.json"

# Must match AppConfig.areas.
AREAS = [
    ("upes-bidholi", 30.415671, 77.966007),
    ("kandholi", 30.383750, 77.969657),
    ("pondha", 30.375002, 77.977719),
    ("nanda-ki-chowki", 30.343468, 77.953149),
]

# Half-extent of the window baked per card, in degrees of latitude.
# ~0.009 deg is roughly 1 km, which at card size shows a legible neighbourhood
# rather than either a single junction or an unreadable tangle.
SPAN = 0.009

# Thickness tiers. Anything not listed is dropped -- footpaths and tracks add
# clutter at this scale without adding information.
WEIGHTS = {
    "motorway": 2, "trunk": 2, "primary": 2,
    "secondary": 1, "tertiary": 1,
    "residential": 0, "unclassified": 0, "service": 0, "living_street": 0,
}

MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]

UA = "RoadScan/0.1 (+student project; one-time asset bake)"


def ask(query: str, attempts: int = 3) -> dict:
    last: Exception | None = None
    for attempt in range(attempts):
        for mirror in MIRRORS:
            try:
                data = urllib.parse.urlencode({"data": query}).encode()
                req = urllib.request.Request(
                    mirror, data=data, headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=120) as r:
                    return json.load(r)
            except Exception as e:  # noqa: BLE001
                last = e
                print(f"    {mirror.split('/')[2]}: {e}")
                time.sleep(2)
        time.sleep(4 * (attempt + 1))
    raise RuntimeError(f"all mirrors failed: {last}")


def build(area_id: str, lat: float, lon: float) -> dict:
    # Longitude span is widened by 1/cos(lat) so the window is square on the
    # ground rather than square in degrees.
    lon_span = SPAN / math.cos(math.radians(lat))
    s, w = lat - SPAN, lon - lon_span
    n, e = lat + SPAN, lon + lon_span

    q = (f'[out:json][timeout:90];'
         f'way["highway"]({s},{w},{n},{e});'
         f'out geom;')
    data = ask(q)

    roads = []
    for el in data.get("elements", []):
        cls = el.get("tags", {}).get("highway")
        if cls not in WEIGHTS:
            continue
        geom = el.get("geometry") or []
        if len(geom) < 2:
            continue

        pts = []
        for p in geom:
            # Normalise into 0..1 across the window, y flipped so 0 is top --
            # matching how a canvas is addressed, so the card painter needs no
            # extra transform.
            x = (p["lon"] - w) / (e - w)
            y = 1.0 - (p["lat"] - s) / (n - s)
            pts.append([round(x, 4), round(y, 4)])

        roads.append({"w": WEIGHTS[cls], "p": pts})

    print(f"    {len(roads)} roads")
    return {"c": [round(lon, 6), round(lat, 6)], "s": round(SPAN, 6), "r": roads}


def main() -> int:
    out: dict = {}
    for area_id, lat, lon in AREAS:
        print(f"{area_id}:")
        out[area_id] = build(area_id, lat, lon)
        time.sleep(1.5)  # be polite between queries

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, separators=(",", ":")), encoding="utf-8")
    kb = OUT.stat().st_size / 1024
    total = sum(len(v["r"]) for v in out.values())
    print(f"\nwrote {OUT.relative_to(ROOT)}  ({kb:.0f} KB, {total} roads)")
    print("Credit required: road geometry (c) OpenStreetMap contributors, ODbL.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
