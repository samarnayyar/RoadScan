#!/usr/bin/env python3
"""
Validate a prepared YOLO dataset before spending GPU time on it.

    python tool/check_dataset.py ml/dataset

Applies the same rules Ultralytics enforces at the start of training, but
without importing it -- so a broken local install cannot stop you checking
the data, and every image is checked rather than whatever a smoke run happens
to sample.

What it catches, all of which fail silently or confusingly at train time:

  * an image with no label file          -> silently treated as background,
                                            so real damage teaches the model
                                            that damage is background
  * a label file with no image           -> ignored, and your counts lie
  * a class id outside 0..nc-1           -> hard crash mid-epoch
  * a coordinate outside 0..1            -> box lands off-frame or wraps
  * zero-area boxes                      -> NaN loss
  * duplicate rows                       -> double-weights one object
  * an unreadable or zero-byte image     -> crash at the first batch touching it

Empty label files are NOT errors. They are negatives -- images deliberately
marked as containing nothing to detect -- and this reports their share,
because that share is what makes the app's "we found nothing, so we reject
this upload" rule trustworthy.
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path

IMG_EXT = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def read_names(yaml_path: Path) -> list[str]:
    """Pull `names` out of the dataset yaml without a yaml dependency."""
    if not yaml_path.exists():
        return []
    lines = yaml_path.read_text(encoding="utf-8").splitlines()
    names: list[str] = []
    for i, raw in enumerate(lines):
        if not raw.strip().startswith("names:"):
            continue
        rest = raw.strip()[len("names:"):].strip()
        if rest.startswith("["):
            return [n.strip().strip("'\"")
                    for n in rest.strip("[]").split(",") if n.strip()]
        for follow in lines[i + 1:]:
            s = follow.strip()
            if not s or not (s.startswith("-") or ":" in s):
                break
            names.append(s.split(":", 1)[1].strip().strip("'\"")
                         if not s.startswith("-")
                         else s[1:].strip().strip("'\""))
        break
    return names


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?", default="ml/dataset")
    ap.add_argument("--splits", default="train,val")
    args = ap.parse_args()

    root = Path(args.root)
    if not root.exists():
        sys.exit(f"not found: {root}")

    names = read_names(root / "roadscan.yaml")
    nc = len(names)
    print(f"dataset: {root}")
    print(f"classes: {names or '(no yaml found)'}")

    try:
        from PIL import Image
    except ImportError:
        Image = None
        print("NOTE: Pillow missing, images will not be opened")

    errors: list[str] = []
    warn: list[str] = []
    totals = Counter()
    per_class = Counter()
    imgs_with = Counter()
    box_area = []

    for split in args.splits.split(","):
        img_dir = root / "images" / split
        lbl_dir = root / "labels" / split
        if not img_dir.exists():
            errors.append(f"missing directory: {img_dir}")
            continue

        imgs = [p for p in sorted(img_dir.iterdir())
                if p.suffix.lower() in IMG_EXT]
        stems = {p.stem for p in imgs}
        lbls = {p.stem for p in lbl_dir.glob("*.txt")} if lbl_dir.exists() \
            else set()

        for orphan in sorted(lbls - stems)[:10]:
            warn.append(f"{split}: label with no image: {orphan}.txt")
        totals[f"{split}_orphan_labels"] = len(lbls - stems)

        empties = 0
        for p in imgs:
            totals[f"{split}_images"] += 1

            if Image is not None:
                try:
                    with Image.open(p) as im:
                        w, h = im.size
                    if w < 2 or h < 2:
                        errors.append(f"{split}: degenerate image {p.name} "
                                      f"({w}x{h})")
                except Exception as e:  # noqa: BLE001
                    errors.append(f"{split}: unreadable image {p.name}: {e}")
                    continue

            t = lbl_dir / f"{p.stem}.txt"
            if not t.exists():
                errors.append(f"{split}: image with NO label file: {p.name}")
                continue

            rows = [ln.strip() for ln in
                    t.read_text(encoding="utf-8").splitlines() if ln.strip()]
            if not rows:
                empties += 1
                continue

            seen = set()
            classes_here = set()
            for ln in rows:
                parts = ln.split()
                if len(parts) != 5:
                    errors.append(f"{split}: {t.name}: expected 5 fields, "
                                  f"got {len(parts)}: {ln!r}")
                    continue
                try:
                    cid = int(parts[0])
                    cx, cy, bw, bh = (float(v) for v in parts[1:])
                except ValueError:
                    errors.append(f"{split}: {t.name}: unparseable row {ln!r}")
                    continue

                if nc and not (0 <= cid < nc):
                    errors.append(f"{split}: {t.name}: class id {cid} outside "
                                  f"0..{nc - 1}")
                for label, v in (("cx", cx), ("cy", cy), ("w", bw), ("h", bh)):
                    if not (0.0 <= v <= 1.0):
                        errors.append(f"{split}: {t.name}: {label}={v} "
                                      f"outside 0..1")
                if bw <= 0 or bh <= 0:
                    errors.append(f"{split}: {t.name}: zero-area box {ln!r}")
                if ln in seen:
                    warn.append(f"{split}: {t.name}: duplicate row {ln!r}")
                seen.add(ln)

                per_class[cid] += 1
                classes_here.add(cid)
                box_area.append(bw * bh)

            for c in classes_here:
                imgs_with[c] += 1

        totals[f"{split}_negatives"] = empties

    # ---- report -----------------------------------------------------------
    print()
    for split in args.splits.split(","):
        n = totals[f"{split}_images"]
        neg = totals[f"{split}_negatives"]
        if not n:
            continue
        print(f"{split:6s} images={n:6d}  negatives={neg:5d} "
              f"({neg / n * 100:4.1f}%)  orphan-labels="
              f"{totals[f'{split}_orphan_labels']}")

    print("\nboxes per class:")
    for cid, cnt in sorted(per_class.items()):
        nm = names[cid] if cid < len(names) else f"id {cid}"
        print(f"    {nm:10s} {cnt:7,d} boxes in {imgs_with[cid]:6,d} images")

    if box_area:
        box_area.sort()
        def pct(q):
            return box_area[int(len(box_area) * q)]
        tiny = sum(1 for a in box_area if a < 0.01)
        print(f"\nbox area as a fraction of the frame: "
              f"p10={pct(.10):.5f}  p50={pct(.50):.5f}  p90={pct(.90):.5f}")
        print(f"    under 1% of frame: {tiny:,} ({tiny / len(box_area):.1%}) "
              f"-- these are what a smaller input size would destroy")

    if warn:
        print(f"\n{len(warn)} warning(s); first few:")
        for w in warn[:8]:
            print(f"    {w}")

    if errors:
        print(f"\n{len(errors)} ERROR(S); first few:")
        for e in errors[:15]:
            print(f"    {e}")
        print("\nFAILED -- fix these before training.")
        return 1

    print("\nOK -- no errors. Safe to train.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
