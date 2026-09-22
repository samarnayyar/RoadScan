#!/usr/bin/env python3
"""
Bake the two map overlays that are not in the basemap:

    assets/rivers.geojson    -- waterways and water bodies
    assets/corridor.geojson  -- the main road linking the four areas

    python tool/fetch_overlays.py

Why bake these instead of styling the basemap
---------------------------------------------
OpenFreeMap's styles do carry water, but they draw it as a barely-there fill
that reads as "slightly different black" on the dark basemap -- on the phone
the river through Nanda Ki Chowki is indistinguishable from unlit ground. And
there is no corridor concept in OSM at all: the route linking the four areas is
a dozen separate ways with different names and classes, so it cannot be
selected with a style filter.

Baking both as small GeoJSON assets lets the app draw them in fixed colours
that survive a theme change, which is the whole point -- the river and the
corridor are orientation landmarks, so they must look the same in dark, light
and neon.

Sources
-------
Waterways: OpenStreetMap via Overpass, ODbL.
Corridor:  OSRM routed over OSM data, ODbL.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RIVERS_OUT = ROOT / "assets" / "rivers.geojson"
CORRIDOR_OUT = ROOT / "assets" / "corridor.geojson"

# Must match AppConfig.campusBounds.
SOUTH, WEST = 30.339146, 77.918581
NORTH, EAST = 30.419994, 78.012287

# Padded slightly so a river does not stop dead at the edge of the square --
# the mask hides the overflow anyway, and a clipped river looks like a bug.
PAD = 0.012

# Routing waypoints for the corridor, south to north.
#
# Kandholi is deliberately NOT forced as a waypoint, even though it is one of
# the four areas. Its centre sits a few hundred metres off the main road, on a
# side lane, so pinning the route to it made OSRM leave the corridor, double
# back west and rejoin -- a visible zigzag that is not the road anyone drives.
# Ground-truthed against the user's own markup and against Google's preferred
# 9.5 km route, both of which run straight down from Bidholi to Pondha.
#
# The route passes close by Kandholi regardless; main() prints the actual
# clearance so this stays honest if the geometry ever changes.
CORRIDOR_STOPS = [
    ("nanda-ki-chowki", 30.343468, 77.953149),
    ("pondha", 30.375002, 77.977719),
    ("upes-bidholi", 30.415671, 77.966007),
]

# Checked against the finished route, not routed through. Must match
# AppConfig.areas.
NEAR_CHECK = [
    ("upes-bidholi", 30.415671, 77.966007),
    ("kandholi", 30.383750, 77.969657),
    ("pondha", 30.375002, 77.977719),
    ("nanda-ki-chowki", 30.343468, 77.953149),
]

OVERPASS_MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]

OSRM = "https://router.project-osrm.org/route/v1/driving/"

UA = "RoadScan/0.1 (+student project; one-time asset bake)"


def overpass(query: str, attempts: int = 3) -> dict:
    last: Exception | None = None
    for attempt in range(attempts):
        for mirror in OVERPASS_MIRRORS:
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
    raise RuntimeError(f"all Overpass mirrors failed: {last}")


def get_json(url: str, attempts: int = 3) -> dict:
    last: Exception | None = None
    for attempt in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.load(r)
        except Exception as e:  # noqa: BLE001
            last = e
            print(f"    {e}")
            time.sleep(3 * (attempt + 1))
    raise RuntimeError(f"request failed: {last}")


# ---------------------------------------------------------------------------
# Rivers
# ---------------------------------------------------------------------------

# Rank drives width at draw time. A named river must stand out from a drainage
# ditch, or "highlight the water" just turns the whole map blue.
WATERWAY_RANK = {"river": 2, "canal": 1, "stream": 0}


def fetch_rivers() -> dict:
    s, w = SOUTH - PAD, WEST - PAD
    n, e = NORTH + PAD, EAST + PAD
    bbox = f"({s},{w},{n},{e})"

    q = (
        "[out:json][timeout:120];"
        "("
        f'way["waterway"~"^(river|canal|stream)$"]{bbox};'
        f'way["natural"="water"]{bbox};'
        f'relation["natural"="water"]{bbox};'
        ");"
        "out geom;"
    )
    print("rivers: querying Overpass...")
    data = overpass(q)

    features = []
    lines = polys = 0

    for el in data.get("elements", []):
        tags = el.get("tags", {})
        waterway = tags.get("waterway")
        name = tags.get("name", "")

        if waterway in WATERWAY_RANK:
            geom = el.get("geometry") or []
            if len(geom) < 2:
                continue
            coords = [[round(p["lon"], 6), round(p["lat"], 6)] for p in geom]
            features.append({
                "type": "Feature",
                "properties": {
                    "k": waterway,
                    "r": WATERWAY_RANK[waterway],
                    "name": name,
                },
                "geometry": {"type": "LineString", "coordinates": coords},
            })
            lines += 1
            continue

        if tags.get("natural") == "water":
            # Ways carry geometry directly; relation members each carry their
            # own ring, and for a lake outline the outer rings are enough.
            rings = []
            if el.get("type") == "way":
                geom = el.get("geometry") or []
                if len(geom) >= 4:
                    rings.append(geom)
            else:
                for m in el.get("members", []):
                    if m.get("role") == "outer" and len(m.get("geometry") or []) >= 4:
                        rings.append(m["geometry"])

            for ring in rings:
                coords = [[round(p["lon"], 6), round(p["lat"], 6)] for p in ring]
                if coords[0] != coords[-1]:
                    coords.append(coords[0])
                features.append({
                    "type": "Feature",
                    "properties": {"k": "water", "r": 2, "name": name},
                    "geometry": {"type": "Polygon", "coordinates": [coords]},
                })
                polys += 1

    named = sorted({f["properties"]["name"]
                    for f in features if f["properties"]["name"]})
    print(f"    {lines} waterway lines, {polys} water polygons")
    if named:
        print(f"    named: {', '.join(named)}")

    return {"type": "FeatureCollection", "features": features}


# ---------------------------------------------------------------------------
# Corridor
# ---------------------------------------------------------------------------

def fetch_corridor() -> dict:
    # OSRM takes lon,lat. Routing through all four stops in order keeps the
    # line on the road people actually drive rather than a straight hop.
    pts = ";".join(f"{lon},{lat}" for _, lat, lon in CORRIDOR_STOPS)
    url = (f"{OSRM}{pts}"
           "?overview=full&geometries=geojson&continue_straight=false")
    print("corridor: routing via OSRM...")
    data = get_json(url)

    if data.get("code") != "Ok" or not data.get("routes"):
        raise RuntimeError(f"OSRM returned {data.get('code')}: "
                           f"{data.get('message', 'no route')}")

    route = data["routes"][0]
    coords = [[round(x, 6), round(y, 6)]
              for x, y in route["geometry"]["coordinates"]]
    km = route["distance"] / 1000.0
    mins = route["duration"] / 60.0
    print(f"    {len(coords)} points, {km:.1f} km, ~{mins:.0f} min driving")

    # Leg boundaries let the app label or segment the corridor per hop later
    # without re-routing.
    legs = []
    for leg, (a, b) in zip(route.get("legs", []),
                           zip(CORRIDOR_STOPS, CORRIDOR_STOPS[1:])):
        legs.append({
            "from": a[0],
            "to": b[0],
            "km": round(leg["distance"] / 1000.0, 2),
            "min": round(leg["duration"] / 60.0, 1),
        })

    main = {
        "type": "Feature",
        "properties": {
            "k": "main",
            "name": "Main corridor",
            "km": round(km, 2),
            "min": round(mins, 1),
            "legs": legs,
        },
        "geometry": {"type": "LineString", "coordinates": coords},
    }

    return {"type": "FeatureCollection",
            "features": [main] + spurs(coords)}


# Kandholi, must match AppConfig.areas.
KANDHOLI = (30.383750, 77.969657)

# A branch point this close to the main line counts as the junction.
JOIN_TOL_M = 30.0


def _metres(a: list, b: list) -> float:
    import math
    return math.hypot((a[1] - b[1]) * 111_320,
                      (a[0] - b[0]) * 111_320 * math.cos(math.radians(b[1])))


def _clip_at_junction(coords: list, corridor: list) -> list:
    """Cut a branch where it first meets the main corridor.

    OSRM routes all the way to the destination, so a branch aimed at Pondha
    arrives by running the last few hundred metres ALONG the corridor. Drawn
    unclipped that doubles the line and the dashes show through the solid
    corridor underneath, which looks like a rendering fault.
    """
    out = []
    for p in coords:
        out.append(p)
        if len(out) > 1 and min(_metres(p, q) for q in corridor) <= JOIN_TOL_M:
            break
    return out


def spurs(corridor: list) -> list:
    """The two branches that link Kandholi to the main corridor.

    Kandholi is one of the four areas but sits ~380 m off the through route,
    so forcing the corridor to touch it bent the whole line out of shape (see
    CORRIDOR_STOPS). Instead it gets its own branches, drawn dashed so they
    read as spurs off the corridor rather than part of it.

    There are genuinely two ways in, which is why both are drawn:

      north  -- the short hop to the nearest point on the corridor.
      south  -- a separate road running south-east to Pondha. Confirmed
                distinct, not a re-tracing of the corridor: OSRM returns it as
                an alternative with 102 of its 110 points more than 30 m off
                the main line.

    Both are clipped at the junction so neither overlaps the corridor.
    """
    lat, lon = KANDHOLI
    here = [lon, lat]
    out = []

    # North: to the nearest point on the finished corridor, so the junction
    # lands exactly where the two actually meet rather than at a named place.
    join = min(corridor, key=lambda p: _metres(p, here))
    print("spur (north): routing Kandholi to the corridor...")
    data = get_json(f"{OSRM}{lon},{lat};{join[0]},{join[1]}"
                    "?overview=full&geometries=geojson")
    if data.get("code") != "Ok" or not data.get("routes"):
        raise RuntimeError(f"OSRM returned {data.get('code')} for the north spur")
    out.append(_feature(data["routes"][0], corridor, "Kandholi link (north)"))

    # South: the direct road to Pondha. `alternatives` is what surfaces it --
    # OSRM's default answer here is the north spur plus a run down the
    # corridor, so the shortest route is NOT the separate road we want.
    plat, plon = 30.375002, 77.977719  # pondha
    print("spur (south): routing Kandholi to Pondha...")
    data = get_json(f"{OSRM}{lon},{lat};{plon},{plat}"
                    "?overview=full&geometries=geojson&alternatives=3")
    if data.get("code") != "Ok" or not data.get("routes"):
        raise RuntimeError(f"OSRM returned {data.get('code')} for the south spur")

    # Pick the candidate that shares least with the corridor: that is the road
    # in its own right, not a detour onto the through route.
    def offness(r):
        return sum(1 for p in r["geometry"]["coordinates"]
                   if min(_metres(list(p), q) for q in corridor) > JOIN_TOL_M)

    best = max(data["routes"], key=offness)
    out.append(_feature(best, corridor, "Kandholi link (south)"))
    return out


def _feature(route: dict, corridor: list, name: str) -> dict:
    coords = [[round(x, 6), round(y, 6)]
              for x, y in route["geometry"]["coordinates"]]
    clipped = _clip_at_junction(coords, corridor)
    # Distance is recomputed over the clipped line; the routed total would
    # include the stretch that was trimmed off.
    km = sum(_metres(a, b)
             for a, b in zip(clipped, clipped[1:])) / 1000.0
    print(f"    {len(clipped)} points (of {len(coords)} routed), {km:.2f} km")
    return {
        "type": "Feature",
        "properties": {"k": "spur", "name": name, "km": round(km, 2)},
        "geometry": {"type": "LineString", "coordinates": clipped},
    }


def write(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, separators=(",", ":")), encoding="utf-8")
    kb = path.stat().st_size / 1024
    print(f"wrote {path.relative_to(ROOT)}  ({kb:.0f} KB)")


def report_clearance(corridor: dict) -> None:
    """How close the finished route passes to each area centre.

    Printed rather than asserted: an area sitting a few hundred metres off the
    corridor is expected (Kandholi does), but a kilometre would mean the route
    has wandered and the bake should not be shipped.
    """
    import math

    # Both features count: Kandholi is served by the spur, not the main line.
    coords = [p for f in corridor["features"]
              for p in f["geometry"]["coordinates"]]
    print("\nclearance from corridor (incl. spur) to each area centre:")
    for name, lat, lon in NEAR_CHECK:
        d = min(math.hypot((p[1] - lat) * 111_320,
                           (p[0] - lon) * 111_320 * math.cos(math.radians(lat)))
                for p in coords)
        flag = "" if d < 700 else "   <-- CHECK, route may have wandered"
        print(f"    {name:<16} {d:6.0f} m{flag}")


def main() -> int:
    rivers = fetch_rivers()
    write(RIVERS_OUT, rivers)
    print()
    time.sleep(1.5)
    corridor = fetch_corridor()
    write(CORRIDOR_OUT, corridor)
    report_clearance(corridor)
    print("\nCredit required: (c) OpenStreetMap contributors, ODbL.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
