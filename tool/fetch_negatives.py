#!/usr/bin/env python3
"""
Collect candidate NEGATIVE images -- pictures with no road damage in them.

    python tool/fetch_negatives.py --coco 250
    python tool/fetch_negatives.py --bdd 700

Writes into negatives/<group>/ ready for:

    python ml/train_export.py prepare --negatives negatives

Why negatives matter here
-------------------------
Every pothole dataset is ~100% damage-present. A detector trained only on
those has never seen a good road, never mind a photo of a ceiling, and will
put boxes on both. The app's whole rejection rule is "no detection means we
did not see road damage, so we will not accept this upload" -- which is only
trustworthy if the model has been explicitly taught what not-damage looks
like. In YOLO that teaching is an image with an EMPTY label file.

Sources
-------
COCO val2017 (--coco)
    5,000 everyday photos, 1 GB, no registration, direct download. This is
    the "wrong upload" case: people, rooms, food, screenshots. Easy for a
    model to learn, so a couple of hundred is plenty.

BDD100K via Hugging Face (--bdd)
    Berkeley dashcam frames, mostly intact road, plus exactly the things that
    cause false positives: manholes, tar patches, wet patches, hard shadows,
    lane markings.

    CAUTION, and this is the important part: BDD100K frames DO sometimes
    contain real potholes and broken surface. An image filed here with an
    empty label teaches the model to MISS potholes, which is worse than not
    adding it at all. Everything this pulls is a CANDIDATE and has to be
    triaged before it is ingested -- see --triage-help.

Neither source is a substitute for photographs of the actual corridor: both
are foreign road surfaces shot from a windscreen, and neither matches the
phone-held-down viewpoint the capture screen actually produces.
"""

from __future__ import annotations

import argparse
import io
import random
import sys
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "negatives"
UA = "RoadScan/0.1 (+student project; negative-example collection)"

COCO_VAL_URL = "http://images.cocodataset.org/zips/val2017.zip"
BDD_REPO = "dgural/bdd100k"

TRIAGE_HELP = """\
Triaging the BDD100K candidates
-------------------------------
These frames are NOT safe to ingest unseen. Some contain real potholes and
broken surface, and filing those as negatives actively trains the model to
miss damage.

Two ways to filter, cheapest first.

1. Active learning (recommended, almost no manual work)
   Train a first model on the damage data alone, then run it over the
   candidates:

       yolo predict model=ml/runs/roadscan/weights/best.pt \\
            source=negatives/road-candidates conf=0.25 save_txt=True

   Frames it finds nothing in are safe negatives -- move them to
   negatives/road-ok/. Only the handful it did fire on need your eyes, and
   those are the most informative images in the batch either way: either the
   model is wrong (a true negative, and a valuable hard one) or it is right
   and the frame does contain damage (so it must not be a negative).

2. Visual sweep with FiftyOne
       pip install -U fiftyone
       import fiftyone as fo
       ds = fo.Dataset.from_images_dir("negatives/road-candidates")
       fo.launch_app(ds)

   The grid view makes a few hundred images quick to skim. Slower than (1),
   but it needs no trained model, so it is the option before you have one.
"""


def http_get(url: str, timeout: int = 300) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def fetch_coco(n: int) -> None:
    """A random sample of COCO val2017, for the not-a-road case."""
    dest = OUT / "not-road"
    dest.mkdir(parents=True, exist_ok=True)
    have = len(list(dest.glob("*.jpg")))
    if have >= n:
        print(f"not-road already has {have} images; nothing to do")
        return

    print(f"downloading COCO val2017 index ({COCO_VAL_URL}) ...")
    print("  (1 GB; only the sampled images are written to disk)")
    # Streamed into memory then read as a zip: val2017 is one flat folder, so
    # there is no cheaper way to get a random sample than having the archive.
    blob = http_get(COCO_VAL_URL, timeout=1800)
    print(f"  got {len(blob) / 2**20:.0f} MiB")

    with zipfile.ZipFile(io.BytesIO(blob)) as zf:
        names = [x for x in zf.namelist() if x.lower().endswith(".jpg")]
        random.seed(11)
        pick = random.sample(names, min(n, len(names)))
        for name in pick:
            out = dest / Path(name).name
            out.write_bytes(zf.read(name))
    print(f"wrote {len(pick)} images to {dest.relative_to(ROOT)}")


def fetch_bdd(n: int) -> None:
    """Dashcam frames from BDD100K, as CANDIDATE negatives (needs triage)."""
    try:
        from datasets import load_dataset
    except ImportError:
        sys.exit("this needs the HF datasets library:\n"
                 "  pip install -U datasets\n"
                 "(or use FiftyOne, see --triage-help)")

    # Deliberately NOT negatives/road-ok: these are unverified. Naming the
    # directory 'candidates' is what stops them being ingested by accident,
    # since prepare --negatives takes whatever it is pointed at.
    dest = OUT / "road-candidates"
    dest.mkdir(parents=True, exist_ok=True)

    print(f"streaming {BDD_REPO} from the Hugging Face hub ...")
    # streaming=True pulls only the shards needed for `n` samples rather than
    # the whole repo.
    ds = load_dataset(BDD_REPO, split="train", streaming=True)

    written = 0
    for i, row in enumerate(ds):
        if written >= n:
            break
        img = row.get("image")
        if img is None:
            continue
        try:
            img.convert("RGB").save(dest / f"bdd_{i:06d}.jpg", quality=92)
        except Exception:  # noqa: BLE001
            continue
        written += 1
        if written % 100 == 0:
            print(f"  {written}/{n}", flush=True)

    print(f"wrote {written} CANDIDATE images to {dest.relative_to(ROOT)}")
    print("\nThese are NOT ready to ingest. Run with --triage-help.")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--coco", type=int, metavar="N",
                    help="sample N images from COCO val2017 into not-road/")
    ap.add_argument("--bdd", type=int, metavar="N",
                    help="pull N dashcam frames into road-candidates/")
    ap.add_argument("--triage-help", action="store_true",
                    help="explain how to filter the BDD candidates")
    args = ap.parse_args()

    if args.triage_help:
        print(TRIAGE_HELP)
        return 0
    if not args.coco and not args.bdd:
        ap.print_help()
        return 1

    OUT.mkdir(parents=True, exist_ok=True)
    # Documented here rather than only in the README so the layout is
    # discoverable from the directory itself.
    (OUT / "README.txt").write_text(
        "Negative examples: images with NO road damage.\n\n"
        "  road-ok/          intact road surface, verified\n"
        "  road-lookalike/   manholes, tar patches, puddles, shadows\n"
        "  not-road/         wrong uploads: people, rooms, screenshots\n"
        "  road-candidates/  UNVERIFIED dashcam frames -- triage before use\n\n"
        "Ingest the verified ones only:\n"
        "  python ml/train_export.py prepare --negatives negatives\n"
        "and keep road-candidates/ out of that until it has been checked.\n",
        encoding="utf-8")

    if args.coco:
        fetch_coco(args.coco)
    if args.bdd:
        fetch_bdd(args.bdd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
