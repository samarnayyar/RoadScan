#!/usr/bin/env python3
"""
Download ONE country out of RDD2022 without fetching the 12.35 GB archive.

    python tool/fetch_rdd.py --country India
    python tool/fetch_rdd.py --list

Why this exists
---------------
RDD2022 is published as a single 12.35 GB zip on figshare and the challenge
site's own per-country links are dead, which normally leaves you downloading
all six countries to use one.

Two facts make that unnecessary:

  * figshare's S3 backend honours HTTP range requests (verified: a ranged GET
    returns 206 Partial Content), so the archive can be read at arbitrary
    offsets without transferring it.
  * the outer archive is not a flat pile of images -- it contains exactly
    seven entries, one nested zip per country, each STORED rather than
    deflated. Stored means the bytes inside the outer archive ARE the inner
    zip file, so the right byte range can be written straight to disk with no
    decompression at all.

India is 502 MiB of the 12.35 GB. Norway alone is 10.6 GB, which is where the
bulk of the archive actually goes.

One wrinkle worth knowing if you adapt this: figshare's download endpoint
302s to a presigned S3 URL with `X-Amz-Expires=10`. Caching that URL fails
almost immediately, so every range request has to go through the figshare
endpoint again and pick up a fresh signature.
"""

from __future__ import annotations

import argparse
import io
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARCHIVE_URL = "https://ndownloader.figshare.com/files/38030910"
UA = "RoadScan/0.1 (+student project; single-country extract)"

# Read this much per HTTP request. Large enough that the per-request redirect
# and TLS handshake are noise, small enough that one failure is cheap to retry.
CHUNK = 8 << 20


class HttpFile(io.RawIOBase):
    """Seekable file-like object backed by HTTP range requests."""

    def __init__(self, url: str):
        self.url = url
        self._pos = 0
        self._size = self._probe_size()
        self.requests = 0
        self.bytes = 0

    def _get(self, start: int, end: int) -> bytes:
        req = urllib.request.Request(
            self.url,
            headers={"User-Agent": UA, "Range": f"bytes={start}-{end}"},
        )
        last: Exception | None = None
        for attempt in range(5):
            try:
                with urllib.request.urlopen(req, timeout=180) as r:
                    return r.read()
            except Exception as e:  # noqa: BLE001
                last = e
                time.sleep(2 * (attempt + 1))
        raise RuntimeError(f"range {start}-{end} failed: {last}")

    def _probe_size(self) -> int:
        req = urllib.request.Request(
            self.url, headers={"User-Agent": UA, "Range": "bytes=0-0"})
        with urllib.request.urlopen(req, timeout=60) as r:
            cr = r.headers.get("Content-Range", "")
            if "/" not in cr:
                sys.exit("server did not honour a range request; "
                         "cannot extract a single country this way")
            return int(cr.split("/")[-1])

    # -- file protocol ------------------------------------------------------
    def seek(self, off, whence=0):
        self._pos = (off if whence == 0
                     else self._pos + off if whence == 1
                     else self._size + off)
        return self._pos

    def tell(self):
        return self._pos

    def seekable(self):
        return True

    def readable(self):
        return True

    def read(self, n=-1):
        if n is None or n < 0:
            n = self._size - self._pos
        if n <= 0 or self._pos >= self._size:
            return b""
        end = min(self._pos + n, self._size) - 1
        data = self._get(self._pos, end)
        self.requests += 1
        self.bytes += len(data)
        self._pos += len(data)
        return data


def human(n: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GiB"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--country", default="India",
                    help="country zip to pull, e.g. India, Japan, Czech")
    ap.add_argument("--list", action="store_true",
                    help="list the country zips and their sizes, then exit")
    ap.add_argument("--out", default=str(ROOT / "rdd2022"),
                    help="directory to write into")
    ap.add_argument("--extract", action="store_true",
                    help="unzip the country archive after downloading")
    args = ap.parse_args()

    print("reading the remote archive index...")
    hf = HttpFile(ARCHIVE_URL)
    zf = zipfile.ZipFile(hf)
    entries = zf.infolist()
    print(f"archive is {human(hf._size)} with {len(entries)} entries "
          f"(index cost {hf.requests} requests, {human(hf.bytes)})")

    if args.list:
        print()
        for i in sorted(entries, key=lambda e: e.file_size):
            print(f"    {i.filename:36s} {human(i.file_size):>10s}")
        return 0

    want = f"RDD2022/{args.country}.zip"
    match = next((i for i in entries if i.filename.lower() == want.lower()),
                 None)
    if match is None:
        print(f"\nno entry named {want!r}. Available:")
        for i in entries:
            print(f"    {i.filename}")
        return 1

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    dest = out_dir / f"{args.country}.zip"

    if dest.exists() and dest.stat().st_size == match.file_size:
        print(f"{dest.name} already present and the right size; skipping "
              f"download")
    else:
        print(f"\nfetching {match.filename}  ({human(match.file_size)} of "
              f"{human(hf._size)} -- "
              f"{match.file_size / hf._size * 100:.1f}% of the archive)")
        t0 = time.time()
        done = 0
        with zf.open(match) as src, open(dest, "wb") as out:
            while True:
                chunk = src.read(CHUNK)
                if not chunk:
                    break
                out.write(chunk)
                done += len(chunk)
                pct = done / match.file_size * 100
                rate = done / max(time.time() - t0, 0.001) / 2**20
                print(f"\r    {human(done)} / {human(match.file_size)}  "
                      f"{pct:5.1f}%   {rate:.1f} MiB/s", end="", flush=True)
        print()
        got = dest.stat().st_size
        if got != match.file_size:
            sys.exit(f"\nsize mismatch: got {got}, expected {match.file_size}")
        print(f"wrote {dest}  in {time.time() - t0:.0f}s")

    # The nested archive is a normal zip; verify it before anyone builds on it.
    with zipfile.ZipFile(dest) as inner:
        bad = inner.testzip()
        if bad is not None:
            sys.exit(f"inner archive is corrupt at {bad}")
        names = inner.namelist()
        jpg = sum(1 for n in names if n.lower().endswith(".jpg"))
        xml = sum(1 for n in names if n.lower().endswith(".xml"))
        print(f"verified: {len(names):,} entries -- {jpg:,} .jpg, {xml:,} .xml")

        if args.extract:
            target = out_dir / args.country
            print(f"extracting to {target} ...")
            inner.extractall(target)
            print("done")

    if not args.extract:
        print(f"\nre-run with --extract to unzip, or unzip {dest} yourself.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
