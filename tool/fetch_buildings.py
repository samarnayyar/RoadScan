#!/usr/bin/env python3
"""
Bake real building footprints for the corridor into assets/buildings.geojson.

    python tool/fetch_buildings.py

The problem this solves
-----------------------
OpenStreetMap has almost no building data for Bidholi. Measured, not guessed --
inside the app's 9 km operating square, Overpass returns:

    151 building ways over 81 km^2
      0 with an explicit `height` tag
     13 with `building:levels`
    138 with neither, so every one falls back to our nominal 6 m
      8 that are triangles (3 corners), which is what produced the odd
        wedge-shaped blocks visible on the map

So the 3D map looked deserted because it *was* deserted: a rendering layer
working perfectly over almost no data. See PROJECT_LOG.txt 8.1.

The fix
-------
Microsoft's Global ML Building Footprints (ODbL, no API key) is a machine
-learning extraction from satellite imagery that covers India densely. This
script pulls the one z9 quadkey tile covering the corridor, clips it to the
operating square, and writes a GeoJSON the map extrudes directly.

Bundled rather than fetched at runtime, for the same reasons as the area map
thumbnails: no key, no quota, works offline, instant.

Heights
-------
These footprints carry no height, and neither does the OSM data. Rather than
extrude everything to one flat slab, each building is assigned an ESTIMATED
height from its footprint area (see estimate_height). This is a presentation
heuristic and is NOT survey data -- say so plainly in the report. The
alternative was a uniform 6 m, which is equally invented and looks worse.

Attribution: the output must be credited to Microsoft (ODbL). The app shows
this alongside the OpenStreetMap credit.
"""

from __future__ import annotations

import csv
import gzip
import io
import json
import math
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "buildings.geojson"

# Must match AppConfig.corridorSouthWest / corridorNorthEast.
SOUTH, WEST = 30.339146, 77.918581
NORTH, EAST = 30.419994, 78.012287

LINKS = "https://minedbuildings.z5.web.core.windows.net/global-buildings/dataset-links.csv"
UA = "RoadScan/0.1 (+student project; one-time asset bake)"

# Coordinates are rounded to this many decimals. 6dp is ~0.11 m at this
# latitude -- far finer than an ML-derived footprint is actually accurate to,
# and it roughly halves the file size versus the raw 15dp floats.
PRECISION = 6


def fetch(url: str, attempts: int = 5) -> bytes:
    last: Exception | None = None
    for i in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=300) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001
            last = e
            print(f"    attempt {i+1} failed ({e}); retrying")
            time.sleep(3 * (i + 1))
    raise RuntimeError(f"gave up on {url}: {last}")


def deg2tile(lat: float, lon: float, z: int) -> tuple[int, int]:
    n = 2 ** z
    x = int((lon + 180.0) / 360.0 * n)
    y = int((1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n)
    return x, y


def quadkey(x: int, y: int, z: int) -> str:
    qk = ""
    for i in range(z, 0, -1):
        d, mask = 0, 1 << (i - 1)
        if x & mask:
            d += 1
        if y & mask:
            d += 2
        qk += str(d)
    return qk


def ring_area_m2(ring: list[list[float]], lat0: float) -> float:
    """Shoelace on a local equirectangular projection. Good enough for a size
    bucket; these are ~10-50 m buildings, not survey parcels."""
    mx = 111320.0 * math.cos(math.radians(lat0))
    my = 110540.0
    pts = [(p[0] * mx, p[1] * my) for p in ring]
    s = 0.0
    for i in range(len(pts) - 1):
        s += pts[i][0] * pts[i + 1][1] - pts[i + 1][0] * pts[i][1]
    return abs(s) / 2.0


def estimate_height(area: float) -> float:
    """ESTIMATED storey height from footprint area.

    Not survey data. The bands mirror what this corridor actually looks like:
    mostly single- and two-storey homes and shops, with the larger footprints
    (campus blocks, warehouses, institutional buildings) running taller. The
    point is to break up a uniform slab skyline, not to claim accuracy.
    """
    if area < 60:
        return 3.5          # shed, outbuilding
    if area < 150:
        return 6.0          # single home
    if area < 400:
        return 9.0          # two to three storeys
    if area < 1200:
        return 13.0         # apartment / small institutional
    return 18.0             # campus block, warehouse


def main() -> int:
    print("resolving dataset links ...")
    txt = fetch(LINKS).decode("utf-8", "replace")
    rows = list(csv.DictReader(io.StringIO(txt)))

    x, y = deg2tile((SOUTH + NORTH) / 2, (WEST + EAST) / 2, 9)
    qk = quadkey(x, y, 9)
    hits = [r for r in rows if r.get("QuadKey") == qk]
    if not hits:
        sys.exit(f"no Microsoft tile for quadkey {qk}")
    url = hits[0]["Url"]
    print(f"  quadkey {qk} -> {hits[0].get('Location')}")

    print("downloading footprints (this tile is large) ...")
    raw = fetch(url)
    print(f"  {len(raw)/1_000_000:.1f} MB")
    try:
        raw = gzip.decompress(raw)
        print(f"  decompressed -> {len(raw)/1_000_000:.1f} MB")
    except Exception:
        pass

    print("clipping to the operating square ...")
    features = []
    total = 0
    for line in raw.decode("utf-8", "replace").splitlines():
        if not line.strip():
            continue
        total += 1
        try:
            f = json.loads(line)
            ring = f["geometry"]["coordinates"][0]
        except Exception:  # noqa: BLE001
            continue

        lons = [c[0] for c in ring]
        lats = [c[1] for c in ring]
        clat = sum(lats) / len(lats)
        clon = sum(lons) / len(lons)
        if not (SOUTH <= clat <= NORTH and WEST <= clon <= EAST):
            continue

        ring = [[round(c[0], PRECISION), round(c[1], PRECISION)] for c in ring]
        h = estimate_height(ring_area_m2(ring, clat))
        features.append({
            "type": "Feature",
            # Only the height survives: every other Microsoft property is
            # irrelevant to rendering and would inflate the asset.
            "properties": {"h": h},
            "geometry": {"type": "Polygon", "coordinates": [ring]},
        })

    print(f"  scanned {total} footprints in tile, kept {len(features)}")
    if not features:
        sys.exit("nothing inside the square -- check the bounds")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    # separators= strips the spaces json.dump would otherwise put after every
    # comma and colon; across ~10^4 polygons that is a real fraction of the
    # asset size.
    OUT.write_text(
        json.dumps({"type": "FeatureCollection", "features": features},
                   separators=(",", ":")),
        encoding="utf-8",
    )
    kb = OUT.stat().st_size / 1024
    print(f"\nwrote {OUT.relative_to(ROOT)}  ({kb:.0f} KB, {len(features)} buildings)")
    print("Credit required: building footprints (c) Microsoft, ODbL.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
