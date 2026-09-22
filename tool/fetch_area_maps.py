#!/usr/bin/env python3
"""
Bake a real map thumbnail for each launch-screen area into assets/area_maps/.

    python tool/fetch_area_maps.py

Why bundle instead of fetching at runtime
-----------------------------------------
The area cards show the actual geography at each area's real coordinates, not
a procedural sketch. The obvious way to do that is to fetch tiles when the card
renders -- but OSM's public tile server is explicitly "light use only" and asks
apps not to send it traffic, and every keyed provider (MapTiler, Thunderforest,
Stadia) reintroduces the quota/API-key dependency this project deliberately
avoided for the main map (see README, "OpenFreeMap over MapTiler").

Fetching once here and shipping the results sidesteps both: users make zero
tile requests, the cards work offline and render instantly, and there is no key
to leak or quota to exhaust. The areas are fixed, so there is nothing dynamic
being thrown away.

Re-run this only if AppConfig.areas changes.

Attribution obligation: these are CARTO basemaps built on OpenStreetMap data.
The app must display "(c) OpenStreetMap contributors (c) CARTO" wherever they
are shown -- see the caption on the area grid.
"""

from __future__ import annotations

import io
import math
import sys
import time
import urllib.request
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "assets" / "area_maps"

# Must match AppConfig.areas (lib/config/app_config.dart). Ground-truthed
# coordinates -- see the comment there about the earlier OSM-geocoded values
# being up to 1.2 km out.
AREAS = [
    ("upes-bidholi", 30.415671, 77.966007),
    ("kandholi", 30.383750, 77.969657),
    ("pondha", 30.375002, 77.977719),
    ("nanda-ki-chowki", 30.343468, 77.953149),
]

# OSM's standard raster layer. Keyless and genuinely free.
#
# NOT CARTO, which is the obvious choice for a dark basemap and was tried
# first: basemaps.cartocdn.com now returns tiles stamped "API KEY REQUIRED"
# across the image. They still return HTTP 200 at a plausible file size, so
# this only shows up if you actually look at the output -- worth knowing if
# anyone revisits this.
#
# OSM's tile policy is "light use only" and asks apps not to send it traffic.
# A one-time developer bake of 36 tiles is not app traffic and is well inside
# acceptable use; the whole point of doing it here is that shipped users make
# zero requests.
TILE_URL = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"

# OSM standard only comes in one (light) flavour, so the dark variant is
# derived locally -- see to_dark(). That is also why there is no second
# network fetch for it.
ZOOM = 16
TILE = 256
RETINA = ""             # OSM standard has no @2x; upscaled below instead.
OUT_PX = 560            # final square crop, centred on the exact coordinate

UA = "RoadScan/0.1 (+student project; one-time asset bake, 36 tiles total)"


def deg2tile(lat: float, lon: float, z: int) -> tuple[float, float]:
    """Fractional tile coordinates -- the fraction is what lets us centre the
    crop on the exact point rather than on the containing tile's corner."""
    n = 2.0 ** z
    x = (lon + 180.0) / 360.0 * n
    lat_rad = math.radians(lat)
    y = (1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n
    return x, y


def fetch(url: str, attempts: int = 4) -> Image.Image:
    """Retry with backoff. A single dropped tile leaves a black square in the
    middle of a card, which is far more obvious than it sounds -- worth a few
    retries rather than shipping a hole."""
    last: Exception | None = None
    for i in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=45) as r:
                return Image.open(io.BytesIO(r.read())).convert("RGB")
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(1.5 * (i + 1))
    raise RuntimeError(f"gave up after {attempts}: {last}")


def to_dark(img: Image.Image) -> Image.Image:
    """Derive a dark-mode basemap from OSM's light one.

    Not a luminance inversion: OSM draws pale roads on a pale background with
    thin dark casings, so inverting makes the roads BLACK and the casings
    bright -- the opposite of what a dark map should look like. Instead the
    whole tile is crushed toward the app's navy and the contrast pushed back
    up, which keeps roads reading as the lighter element while the ground goes
    dark.
    """
    from PIL import ImageEnhance

    img = ImageEnhance.Color(img).enhance(0.35)      # mute OSM's greens/yellows
    img = ImageEnhance.Brightness(img).enhance(0.34)
    img = ImageEnhance.Contrast(img).enhance(1.45)

    # Tint toward the app's background navy so the card doesn't read as a grey
    # photograph sitting on a blue screen.
    tint = Image.new("RGB", img.size, (16, 34, 52))
    return Image.blend(img, tint, 0.34)


def to_light(img: Image.Image) -> Image.Image:
    """Near-original, with a touch more contrast.

    An earlier version desaturated to 55% and lifted brightness, on the theory
    that the map should recede behind the label. In practice the card ALSO
    applies an accent wash and a scrim, so the thumbnail was being washed three
    times over -- the result was pale grey-green mush with sickly-looking
    forest areas. The card-side overlays were reduced instead, and the map is
    now left close to how OSM draws it.
    """
    from PIL import ImageEnhance

    img = ImageEnhance.Color(img).enhance(0.92)
    return ImageEnhance.Contrast(img).enhance(1.08)


def build(area_id: str, lat: float, lon: float) -> None:
    px_per_tile = TILE
    fx, fy = deg2tile(lat, lon, ZOOM)
    cx, cy = int(fx), int(fy)

    # 3x3 block guarantees the OUT_PX crop is fully covered whatever the
    # fractional offset within the centre tile happens to be.
    canvas = Image.new("RGB", (px_per_tile * 3, px_per_tile * 3))
    failed = 0
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            url = TILE_URL.format(z=ZOOM, x=cx + dx, y=cy + dy)
            try:
                tile = fetch(url)
            except Exception as e:  # noqa: BLE001
                print(f"    FAILED tile {cx+dx},{cy+dy}: {e}")
                failed += 1
                continue
            if tile.size != (px_per_tile, px_per_tile):
                tile = tile.resize((px_per_tile, px_per_tile), Image.LANCZOS)
            canvas.paste(tile, ((dx + 1) * px_per_tile, (dy + 1) * px_per_tile))
            time.sleep(0.12)  # be polite to a free service

    # Exact pixel of our coordinate inside the 3x3 canvas.
    px = (fx - cx + 1) * px_per_tile
    py = (fy - cy + 1) * px_per_tile
    half = OUT_PX // 2
    crop = canvas.crop((int(px - half), int(py - half), int(px + half), int(py + half)))

    if failed:
        # Refuse to overwrite a good asset with a holed one.
        print(f"    SKIPPED {area_id}: {failed} tile(s) missing")
        return

    # Upscale a little: OSM standard has no @2x, and the cards are ~420 logical
    # px wide on a 3x-density phone. LANCZOS softening beats visible tile
    # pixels at that size.
    crop = crop.resize((OUT_PX, OUT_PX), Image.LANCZOS)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for style_name, fn in (("dark", to_dark), ("light", to_light)):
        dst = OUT_DIR / f"{area_id}_{style_name}.jpg"
        # JPEG, not PNG: these are photographic-ish raster maps, and PNG kept
        # them around 700 KB each. At q82 they are tens of KB with no visible
        # difference at card size, which matters with eight in the APK.
        fn(crop).save(dst, "JPEG", quality=82, optimize=True)
        print(f"    {dst.relative_to(ROOT)}  ({dst.stat().st_size // 1024} KB)")


def main() -> int:
    for area_id, lat, lon in AREAS:
        print(f"{area_id}:")
        build(area_id, lat, lon)
    print("\nRemember: the UI must credit (c) OpenStreetMap contributors.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
