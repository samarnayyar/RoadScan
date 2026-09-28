#!/usr/bin/env python3
"""
Fetch the drivable road network for the operating square from OSM.

    python tool/fetch_roads.py

Writes assets/roads.geojson -- every road a hazard could be reported on,
as plain LineStrings in lon/lat.

Why this exists
---------------
Hazard alert bands are drawn by snapping a report onto a road and walking
50m along it in both directions, so the band is only as good as the road
geometry underneath it. Two earlier sources were tried and both failed:

  * assets/corridor.geojson covers the main route only, so a pothole on any
    side street found no road within range and got no band at all -- which is
    most reports.
  * assets/area_roads.json (the launch screen's card artwork) covers side
    streets, but its coordinates are normalised fractions that run from -0.45
    to 2.99 because the cards simply clip the overflow. Extrapolated into real
    coordinates, the out-of-box parts land hundreds of metres from any road,
    which drew bands across open ground and at the wrong angle to the roads
    they meant to trace.

This is the real thing: actual OSM ways for the whole square, so the snap
works anywhere a report can be filed rather than near four sampled areas.

Filtering
---------
Only ways people drive or ride on. Footways, steps, cycleways and paths are
excluded -- a pothole report is about a carriageway, and including them would
let a band snap to a footpath running parallel to the road it belongs on.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "roads.geojson"

# Must match AppConfig.corridorSouthWest / corridorNorthEast.
SOUTH, WEST = 30.339146, 77.918581
NORTH, EAST = 30.419994, 78.012287

# Padded so a road just outside the square still has geometry to walk along
# when a band near the edge continues onto it.
PAD = 0.004

OVERPASS_MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]

DRIVABLE = (
    "motorway|trunk|primary|secondary|tertiary|unclassified|residential|"
    "service|living_street|track|road|"
    "motorway_link|trunk_link|primary_link|secondary_link|tertiary_link"
)

QUERY = f"""
[out:json][timeout:180];
way["highway"~"^({DRIVABLE})$"]
   ({SOUTH - PAD},{WEST - PAD},{NORTH + PAD},{EAST + PAD});
out geom;
"""


def overpass(query: str, attempts: int = 3) -> dict:
    last = None
    for attempt in range(attempts):
        for mirror in OVERPASS_MIRRORS:
            try:
                print(f"  querying {urllib.parse.urlparse(mirror).netloc} ...")
                req = urllib.request.Request(
                    mirror,
                    data=urllib.parse.urlencode({"data": query}).encode(),
                    headers={"User-Agent": "roadscan-tool/1.0"},
                )
                with urllib.request.urlopen(req, timeout=240) as r:
                    return json.load(r)
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                last = e
                print(f"    failed: {e}")
        if attempt < attempts - 1:
            wait = 5 * (attempt + 1)
            print(f"  all mirrors failed; retrying in {wait}s")
            time.sleep(wait)
    raise SystemExit(f"Overpass unreachable: {last}")


def main() -> int:
    print("fetching drivable roads for the operating square...")
    data = overpass(QUERY)

    features = []
    for el in data.get("elements", []):
        if el.get("type") != "way":
            continue
        geom = el.get("geometry") or []
        if len(geom) < 2:
            continue
        # Rounded to ~1cm. The band is a 50m advisory zone, so more precision
        # than that is bytes on the wire for nothing.
        coords = [[round(p["lon"], 7), round(p["lat"], 7)] for p in geom]
        features.append(
            {
                "type": "Feature",
                "properties": {"c": el.get("tags", {}).get("highway", "road")},
                "geometry": {"type": "LineString", "coordinates": coords},
            }
        )

    if not features:
        raise SystemExit("no roads returned -- refusing to write an empty file")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    # Compact separators: this ships in the APK.
    OUT.write_text(
        json.dumps(
            {"type": "FeatureCollection", "features": features},
            separators=(",", ":"),
        ),
        encoding="utf-8",
    )

    pts = sum(len(f["geometry"]["coordinates"]) for f in features)
    size = OUT.stat().st_size / 1024
    print(f"wrote {OUT.relative_to(ROOT)}: {len(features)} roads, "
          f"{pts} points, {size:.0f} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
