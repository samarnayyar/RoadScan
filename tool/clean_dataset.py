#!/usr/bin/env python3
"""
De-duplicate a Roboflow YOLO export in place and re-split it cleanly.

    python tool/clean_dataset.py photos            # report only
    python tool/clean_dataset.py photos --apply    # actually rewrite it

What is wrong with the export as downloaded
-------------------------------------------
Measured on smartathon/new-pothole-detection v2:

    9,181 files  ->  7,054 distinct pictures   (2,127 redundant copies)
    1,068 of the 3,090 valid/test files are the same photograph as
    something in train -- 35% of the evaluation set

Both are fatal to honest evaluation. Duplicates inside train just waste time,
but a picture that is in train AND in valid means validation mAP is partly the
model recognising images it was fitted on, so the number is inflated and
checkpoint selection is biased toward whatever overfits hardest.

Identity is decided by PIXELS, not filenames. Roboflow renames every file to
`<original>.rf.<32-hex>.<ext>` and re-encodes it, so neither the name nor the
bytes identify a picture. Filenames are actively misleading here: base names
like "100" collide across different source folders, so name-matching alone
would both miss real duplicates and invent fake ones.

The re-split is keyed on the image hash, which is what makes the result
leak-proof by construction rather than by luck: every copy of a picture
necessarily lands in the same split, and a re-run reproduces the same
assignment.
"""

from __future__ import annotations

import argparse
import shutil
import sys
from collections import defaultdict
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    sys.exit("Pillow is required:  pip install Pillow")

IMG_EXT = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}
SPLITS = ("train", "valid", "test")

# Roughly the export's own proportions (66/23/11), rounded to something
# easier to reason about.
TRAIN_PCT, VALID_PCT = 70, 90  # <70 train, <90 valid, else test


def dhash(path: Path, size: int = 8) -> int:
    """Perceptual hash: survives Roboflow's re-encode, separates real photos."""
    im = Image.open(path).convert("L").resize((size + 1, size), Image.LANCZOS)
    px = im.load()
    bits = 0
    for y in range(size):
        for x in range(size):
            bits = (bits << 1) | (1 if px[x, y] < px[x + 1, y] else 0)
    return bits


def box_count(lbl: Path | None) -> int:
    if lbl is None or not lbl.exists():
        return 0
    return sum(1 for line in lbl.read_text(encoding="utf-8").splitlines()
               if line.strip())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("root", help="the unzipped Roboflow export directory")
    ap.add_argument("--apply", action="store_true",
                    help="rewrite the dataset; without this, only report")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    if not root.exists():
        sys.exit(f"not found: {root}")

    # ---- scan -------------------------------------------------------------
    records = []          # (hash, img, lbl_or_None, split)
    orphan_labels = []
    unreadable = []
    for split in SPLITS:
        img_dir, lbl_dir = root / split / "images", root / split / "labels"
        if not img_dir.exists():
            continue
        stems = set()
        for img in sorted(img_dir.iterdir()):
            if img.suffix.lower() not in IMG_EXT:
                continue
            stems.add(img.stem)
            lbl = lbl_dir / f"{img.stem}.txt"
            try:
                h = dhash(img)
            except Exception as e:  # noqa: BLE001
                unreadable.append((img, e))
                continue
            records.append((h, img, lbl if lbl.exists() else None, split))
        if lbl_dir.exists():
            orphan_labels += [t for t in lbl_dir.glob("*.txt")
                              if t.stem not in stems]

    if not records:
        sys.exit(f"no images found under {root}/<split>/images")

    groups: dict[int, list] = defaultdict(list)
    for rec in records:
        groups[rec[0]].append(rec)

    n_files, n_pics = len(records), len(groups)
    cross = sum(1 for g in groups.values() if len({r[3] for r in g}) > 1)
    leaked_eval = sum(
        sum(1 for r in g if r[3] in ("valid", "test"))
        for g in groups.values()
        if "train" in {r[3] for r in g} and ({"valid", "test"} & {r[3] for r in g})
    )

    print(f"scanned {root}")
    print(f"    files on disk            {n_files}")
    print(f"    distinct pictures        {n_pics}")
    print(f"    redundant copies         {n_files - n_pics}")
    print(f"    pictures spanning splits {cross}")
    print(f"    valid/test files whose picture is also in train: {leaked_eval}")
    if orphan_labels:
        print(f"    orphan label files (no image): {len(orphan_labels)}")
    if unreadable:
        print(f"    unreadable images: {len(unreadable)}")

    # ---- plan -------------------------------------------------------------
    plan = []             # (keeper_img, keeper_lbl, target_split)
    drop = []
    for h, g in groups.items():
        # Keep the best-annotated copy, then the shortest name, so the choice
        # is deterministic rather than filesystem-order dependent.
        g_sorted = sorted(g, key=lambda r: (-box_count(r[2]), len(r[1].name),
                                            r[1].name))
        keeper = g_sorted[0]
        drop += [r for r in g_sorted[1:]]
        pct = h % 100
        target = ("train" if pct < TRAIN_PCT
                  else "valid" if pct < VALID_PCT else "test")
        plan.append((keeper[1], keeper[2], target))

    counts = {s: sum(1 for p in plan if p[2] == s) for s in SPLITS}
    print(f"\nafter cleaning: {n_pics} pictures  ->  "
          + ", ".join(f"{counts[s]} {s}" for s in SPLITS))
    print(f"    files to delete: {len(drop)} duplicates"
          + (f" + {len(orphan_labels)} orphan labels" if orphan_labels else ""))

    if not args.apply:
        print("\nreport only. Re-run with --apply to rewrite the dataset.")
        print("The source is re-downloadable from the URL in "
              "README.roboflow.txt if you want to start over.")
        return 0

    # ---- apply ------------------------------------------------------------
    # Staged through a temp directory rather than moved in place: a file can
    # be moving from train to valid while another moves the other way, and
    # doing that directly risks clobbering a name that has not moved yet.
    stage = root / "_clean_tmp"
    if stage.exists():
        shutil.rmtree(stage)
    for s in SPLITS:
        (stage / s / "images").mkdir(parents=True, exist_ok=True)
        (stage / s / "labels").mkdir(parents=True, exist_ok=True)

    for img, lbl, target in plan:
        shutil.copy2(img, stage / target / "images" / img.name)
        out = stage / target / "labels" / f"{img.stem}.txt"
        # Every image gets a label file, empty if it has no boxes: that is
        # how a YOLO dataset spells "this image is a negative", and a missing
        # file is easy to mistake for an oversight later.
        out.write_text(lbl.read_text(encoding="utf-8") if lbl else "",
                       encoding="utf-8")

    for s in SPLITS:
        for sub in ("images", "labels"):
            d = root / s / sub
            if d.exists():
                shutil.rmtree(d)
        (root / s).mkdir(exist_ok=True)
        shutil.move(str(stage / s / "images"), str(root / s / "images"))
        shutil.move(str(stage / s / "labels"), str(root / s / "labels"))
    shutil.rmtree(stage)

    print("\nrewritten.")
    for s in SPLITS:
        n = len(list((root / s / "images").iterdir()))
        print(f"    {s:6s} {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
