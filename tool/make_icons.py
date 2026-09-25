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
SRC = ROOT / "outside-logo.jpeg"
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
    """The app icon, lifted out of the supplied screenshot.

    The source is a phone screenshot of the artwork in a gallery viewer, not
    a bare image: a status bar and a Share bar top and bottom, black
    letterboxing around a white band, and the icon sitting inside that band.
    Feeding it to the resizers whole would produce a launcher icon that is
    mostly black letterbox with a tiny logo in the middle.

    So: find the white band first (the viewer's page background), then take
    the bounding box of everything inside it that is not that white. That
    lands exactly on the rounded-square icon regardless of where in the
    screenshot it sits or how tall the system bars are.
    """
    im = Image.open(SRC).convert("RGB")
    im.thumbnail((1400, 1400), Image.LANCZOS)
    w, h = im.size
    px = im.load()

    def near_white(p):
        return p[0] > 225 and p[1] > 225 and p[2] > 225

    # Rows belonging to the viewer's white page, sampled across the width.
    band = [y for y in range(h)
            if sum(near_white(px[x, y]) for x in range(0, w, 8))
            > (w // 8) * 0.55]
    if not band:
        raise SystemExit(
            "no white page found in the screenshot -- if the source is "
            "already a bare image, crop it by hand and re-run.")
    top, bottom = min(band), max(band)

    # Inside the band, find the icon BODY -- the dark pixels -- not merely
    # everything that is not the page.
    #
    # "Not white" also matches the soft drop shadow the viewer paints around
    # the icon, and that shadow extends well past the artwork. Cropping to it
    # left a white frame baked into every launcher icon. The body is a near
    # black rounded square, so thresholding on darkness lands on the artwork
    # itself and the shadow falls outside.
    def is_body(p):
        return max(p) < 110

    minx, miny, maxx, maxy = w, bottom, 0, top
    for y in range(top, bottom + 1):
        for x in range(0, w, 2):
            if is_body(px[x, y]):
                minx = min(minx, x)
                maxx = max(maxx, x)
                miny = min(miny, y)
                maxy = max(maxy, y)
    if minx >= maxx or miny >= maxy:
        raise SystemExit(
            "found the page but no dark artwork inside it -- if this logo is "
            "light on a dark ground, invert the is_body test.")

    cropped = im.crop((minx, miny, maxx + 1, maxy + 1))

    # Fill the four corner wedges left by the artwork's rounded corners.
    #
    # A rounded square's bounding box necessarily includes page-white at each
    # corner, which came through as a white frame around every launcher icon.
    # Flooding inward from the corners with the icon's own background colour
    # closes them; the white ROADSCAN lettering inside the icon is not
    # connected to any corner, so it is untouched.
    corner = im.getpixel(((minx + maxx) // 2, miny + 3))
    cw, ch = cropped.size
    for seed in ((0, 0), (cw - 1, 0), (0, ch - 1), (cw - 1, ch - 1)):
        ImageDraw.floodfill(cropped, seed, corner, thresh=60)

    cropped = cropped.convert("RGBA")

    # Square it by padding the short axis, so no later resize distorts it.
    # Padded with the artwork's own background colour rather than
    # transparency: this icon is a filled rounded square, so transparent
    # padding would show as notches along whichever edge was short.
    #
    # Sampled from the middle of the TOP EDGE, not from a corner. The artwork
    # has rounded corners, so the corner pixel of its bounding box is still
    # page-white -- sampling there gave a white plate behind a black icon.
    fill = corner + (255,)
    side = max(cropped.size)
    square = Image.new("RGBA", (side, side), fill)
    square.paste(cropped,
                 ((side - cropped.width) // 2, (side - cropped.height) // 2),
                 cropped)
    print(f"    page rows {top}-{bottom}; artwork "
          f"{cropped.width}x{cropped.height} -> squared to {side}px")
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

    # The adaptive background takes the artwork's OWN colour rather than a
    # hardcoded plate. This icon is a black rounded square; a cream
    # background behind it would show as a pale ring wherever the launcher's
    # mask is wider than the artwork.
    ground = mark.convert("RGB").getpixel((mark.width // 2, 3))

    BRAND.mkdir(parents=True, exist_ok=True)
    mark.resize((512, 512), Image.LANCZOS).save(BRAND / "logo.png")
    print(f"wrote {(BRAND / 'logo.png').relative_to(ROOT)}")

    # Legacy square icon: the artwork IS a finished icon, so it fills the
    # square edge to edge rather than being inset on a plate.
    for bucket, size in DENSITIES.items():
        d = RES / f"mipmap-{bucket}"
        d.mkdir(parents=True, exist_ok=True)
        mark.resize((size, size), Image.LANCZOS).convert("RGB").save(
            d / "ic_launcher.png")

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

    hexbg = "#%02X%02X%02X" % ground
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
