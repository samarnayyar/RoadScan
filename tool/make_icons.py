#!/usr/bin/env python3
"""
Generate the app icons and the in-app logo asset from logo.jpg.

    python tool/make_icons.py

Writes:
    assets/brand/logo.png                     in-app mark (launch screen)
    android/app/src/main/res/mipmap-*/ic_launcher.png
    android/app/src/main/res/mipmap-*/ic_launcher_foreground.png
    android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml
    android/app/src/main/res/values/ic_launcher_background.xml

Why not flutter_launcher_icons
------------------------------
It would be one more dev dependency and a build step, for something that runs
once. This also does the two things the generic tool gets wrong for this
particular artwork:

  * The source is a wide JPEG (3936x3590) with the tyre sitting off-centre and
    a cream background baked in. Cropping to the tyre's actual bounding box
    first is what stops the icon rendering as a small wheel adrift in a pale
    square.
  * Android 8+ masks adaptive icons to a circle, squircle or whatever the
    launcher chooses, and only the middle ~66% is guaranteed visible. The
    foreground layer is therefore scaled to sit inside that safe zone -- a
    straight resize would have the tyre's edges clipped on every round-icon
    launcher.
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    print("Pillow is required:  pip install Pillow")
    raise SystemExit(1)

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "logo-nobg.png"
WORDMARK_SRC = ROOT / "roadscan-nobg.png"

# The wordmark ships as white "ROAD" + green "SCAN" on transparency, which is
# built for a dark ground. Dropped on the light theme the white half simply
# disappears, so a second variant recolours only the neutral pixels to dark
# ink and leaves the green alone.
LIGHT_INK = (14, 26, 38)
RES = ROOT / "android" / "app" / "src" / "main" / "res"
BRAND = ROOT / "assets" / "brand"

# Launcher icon sizes per density bucket.
DENSITIES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

# Adaptive icons are authored on a 108dp canvas of which the middle 72dp is
# the guaranteed-visible safe zone. Anything outside can be masked away.
ADAPTIVE_DP = 108
SAFE_DP = 66  # a little tighter than 72 so the tyre never kisses the mask edge

# Sampled from the artwork's own background.
BACKGROUND = (247, 245, 240)


def load_trimmed() -> Image.Image:
    """The artwork cropped to the tyre, with the paper background removed.

    The background is knocked out by flood-filling inward from the corners,
    NOT by matching the background colour everywhere. The difference matters:
    the lane markings, the tyre's inner ring and the sun are all near-white
    too, and a global colour match punches holes straight through them. A
    flood only removes background that is actually connected to the edge.
    """
    im = Image.open(SRC).convert("RGBA")

    # Work at a reduced size: the largest output is the 432px adaptive
    # foreground, so 1400px is already oversampled, and the flood fill is
    # pure-Python and scales with pixel count.
    im.thumbnail((1400, 1400), Image.LANCZOS)
    w, h = im.size

    # Only knock out the background when there is one. A source that already
    # carries alpha (logo-nobg.png) is left alone -- flood-filling it would
    # start from an already-transparent corner and eat into the artwork.
    if im.split()[-1].getextrema()[0] == 255:
        print("    opaque source; flood-filling the background")
        for seed in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
            ImageDraw.floodfill(im, seed, (0, 0, 0, 0), thresh=42)
    else:
        print("    source already has alpha; using it as-is")

    box = im.getbbox()
    if box is None:
        raise SystemExit("could not find the mark against the background")

    pad = int(max(box[2] - box[0], box[3] - box[1]) * 0.02)
    box = (max(0, box[0] - pad), max(0, box[1] - pad),
           min(w, box[2] + pad), min(h, box[3] + pad))
    cropped = im.crop(box)

    # Square it by padding the short axis, so no later resize distorts it.
    side = max(cropped.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(cropped,
                 ((side - cropped.width) // 2, (side - cropped.height) // 2))
    print(f"    cropped {im.size} -> {cropped.size}, squared to {side}px")
    return square


def flatten(mark: Image.Image, size: int, scale: float) -> Image.Image:
    """The mark centred on the brand background, at `size` px."""
    out = Image.new("RGBA", (size, size), BACKGROUND + (255,))
    inner = max(1, int(size * scale))
    scaled = mark.resize((inner, inner), Image.LANCZOS)
    out.paste(scaled, ((size - inner) // 2, (size - inner) // 2), scaled)
    return out


def build_wordmarks() -> None:
    """Writes the wordmark in a dark-ground and a light-ground variant."""
    if not WORDMARK_SRC.exists():
        print(f"skipping wordmark: {WORDMARK_SRC.name} not found")
        return

    im = Image.open(WORDMARK_SRC).convert("RGBA")
    box = im.getbbox()
    if box:
        im = im.crop(box)

    BRAND.mkdir(parents=True, exist_ok=True)
    im.save(BRAND / "wordmark.png")

    # Recolour ONLY the neutral pixels. Testing for low saturation rather than
    # for "is it white" is what keeps the green half intact while still
    # catching the anti-aliased greys along every letter edge -- a plain
    # white-to-ink swap leaves those grey fringes behind and the type ends up
    # looking haloed on the light background.
    light = im.copy()
    px = light.load()
    w, h = light.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            hi, lo = max(r, g, b), min(r, g, b)
            if hi - lo <= 30:  # neutral: white, grey, black
                # Keep the pixel's own lightness as a blend factor so the
                # anti-aliasing survives the swap.
                t = hi / 255.0
                px[x, y] = (
                    round(LIGHT_INK[0] * t + 255 * (1 - t) * 0),
                    round(LIGHT_INK[1] * t + 255 * (1 - t) * 0),
                    round(LIGHT_INK[2] * t + 255 * (1 - t) * 0),
                    round(a * t) if t < 1.0 else a,
                )
    light.save(BRAND / "wordmark-light.png")
    print(f"wrote wordmark.png + wordmark-light.png ({im.width}x{im.height})")


def main() -> int:
    # The launcher icons and the wordmark come from different source files and
    # are regenerated independently: whichever source is present gets rebuilt.
    # Without this, dropping the tyre artwork would block the wordmark build
    # even though the icons already on disk are perfectly current.
    if not SRC.exists():
        print(f"skipping launcher icons: {SRC.name} not found "
              f"(existing icons under android/ are left as they are)")
        build_wordmarks()
        return 0

    print("trimming artwork...")
    mark = load_trimmed()

    # In-app asset: transparent, so it sits on any of the three themes.
    BRAND.mkdir(parents=True, exist_ok=True)
    mark.resize((512, 512), Image.LANCZOS).save(BRAND / "logo.png")
    print(f"wrote {(BRAND / 'logo.png').relative_to(ROOT)}")

    # Legacy square icon: the mark nearly fills it.
    for bucket, size in DENSITIES.items():
        d = RES / f"mipmap-{bucket}"
        d.mkdir(parents=True, exist_ok=True)
        flatten(mark, size, 0.92).convert("RGB").save(d / "ic_launcher.png")

        # Adaptive foreground: same mark, but shrunk into the safe zone and
        # left transparent so the background layer shows through the mask.
        # The launcher icon is 48dp, so `size` px per 48dp gives the density
        # scale; the adaptive canvas is 108dp at that same scale.
        fg_size = round(size * ADAPTIVE_DP / 48)
        fg = Image.new("RGBA", (fg_size, fg_size), (0, 0, 0, 0))
        inner = round(fg_size * SAFE_DP / ADAPTIVE_DP)
        scaled = mark.resize((inner, inner), Image.LANCZOS)
        fg.paste(scaled, ((fg_size - inner) // 2, (fg_size - inner) // 2), scaled)
        fg.save(d / "ic_launcher_foreground.png")
    print(f"wrote ic_launcher.png + ic_launcher_foreground.png "
          f"for {len(DENSITIES)} densities")

    anydpi = RES / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '</adaptive-icon>\n',
        encoding="utf-8")

    hexbg = "#%02X%02X%02X" % BACKGROUND
    (RES / "values" / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<resources>\n'
        f'    <color name="ic_launcher_background">{hexbg}</color>\n'
        '</resources>\n',
        encoding="utf-8")
    print(f"wrote adaptive-icon xml (background {hexbg})")

    build_wordmarks()
    return 0


if __name__ == "__main__":
    sys.exit(main())
