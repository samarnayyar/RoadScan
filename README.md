# RoadScan

Crowd-sourced road hazard mapping for the Bidholi–Kandholi–Pondha corridor
around UPES Dehradun. Android, Flutter, on-device detection, 3D map.

Photograph a pothole → a YOLO model running **on the phone** finds it and scores
its severity → the report either creates a pin or merges into a nearby existing
one → other riders get warned when they approach it.

---

## Status

Phases 1–3 of the build plan are implemented (map, capture + on-device
detection, backend with dedup/decay/confirmation). Alerts are implemented
foreground-only. The risk model microservice (phase 5) is **not** built yet —
the pin sheet shows a clearly-labelled heuristic placeholder instead of
pretending to have a trained model behind it.

| Area | State |
|---|---|
| 3D tilted map, pitch slider, campus bounds | Implemented |
| Capture → on-device detection → severity | Implemented |
| PostGIS dedup, confidence decay, 3-device confirm | Implemented |
| Pin rendering, detail sheet, photo timeline | Implemented |
| Proximity alerts with photo thumbnail | Implemented, **foreground only** |
| Stats overlay | Implemented |
| Accident-risk model + SHAP | **Not built** — placeholder, clearly marked |
| My Reports screen | **Not built** |
| Trained pothole model | **You must train it** — see [ML](#ml) |

Nothing here has been run on a device yet: Flutter was not installed on the
machine this was written on. The pure logic (severity bands, crack discount,
decay curve) is covered by 18 tests / 48 assertions in `test/severity_test.dart`, whose
expected values were independently re-derived and checked; everything touching the map, camera or network needs a
real device to confirm.

---

## Setup

Full walkthrough, split by who has to do each step:
**[docs/SETUP_STEPS.md](docs/SETUP_STEPS.md)**.

### 1. Install Flutter

On this machine the toolchain is already installed under `D:\dev\`:

| | |
|---|---|
| Flutter SDK 3.47.4 | `D:\dev\flutter` |
| Android SDK (cmdline-tools, platform-tools, platform 36, build-tools 36.1) | `D:\dev\android-sdk` |

It went on `D:` because `C:` had only ~12 GB free and this needs ~15 GB.

**Android Studio is not required.** It is a wrapper around these same SDK
components plus an editor; installing the command-line SDK alone saves ~8 GB.
Install Studio later only if you want the visual emulator manager or layout
inspector — it will pick up the existing SDK.

To put it on PATH for your own terminals (current user only, no admin needed):

```
powershell -ExecutionPolicy Bypass -File tool\env_setup.ps1
```

Then open a **new** terminal and run `flutter doctor`.

### 2. Generate the Android scaffold

```
powershell -ExecutionPolicy Bypass -File tool\setup_android.ps1
```

This generates `android/` in a throwaway directory and copies it in, so it
cannot clobber the hand-written `lib/` or `pubspec.yaml`. It then adds the five
permissions the app needs, pins `minSdk` to 26 (LiteRT inference fails at
runtime below this), and runs `flutter pub get`.

### 3. Set up Supabase

1. Create a free project at <https://supabase.com>.
2. SQL Editor → paste all of `supabase/schema.sql` → Run. This enables PostGIS,
   creates the three tables, the RPC functions, the RLS policies, and the
   storage bucket.
3. Settings → API → copy the **Project URL** and the **anon public** key.

> **Free-tier gotcha:** a free Supabase project **pauses after 7 days of
> database inactivity**. Open the app or hit the dashboard the day before your
> demo so it is awake.

### 4. Run

Copy the template, paste your two values into it, and run:

```
copy supabase.example.json supabase.json
flutter run --dart-define-from-file=supabase.json
```

In VS Code just press **F5** — `.vscode/launch.json` already points at it, and
has a second "no backend" profile for map-only work.

> ### SECURITY — read before sharing this repo
>
> This repository is **private**, and by explicit choice it **commits
> `supabase.json`** rather than ignoring it, so the project is self-contained.
> That is a reasonable trade for a private student repo, but it has
> consequences:
>
> - **Before making this repo public, or adding a collaborator you do not
>   fully trust, rotate the Supabase key** (Dashboard → Project Settings → API
>   keys → Roll). Deleting the file later does **not** help: git keeps the old
>   value in history forever.
> - The key that is committed must only ever be the **publishable / anon**
>   key. It is constrained by the row-level security policies in
>   `supabase/schema.sql`.
> - **Never** commit the `service_role` / secret key. It bypasses RLS entirely
>   and would let anyone holding it read, alter or wipe the whole database.

Keys are injected at build time rather than committed. The anon key is safe in a
client binary — it only grants what the RLS policies allow. The `service_role`
key must never go in this app.

The app runs without Supabase credentials too: you get the 3D map with no pins,
which is enough to check the map work.

---

## ML

`assets/models/roadscan.tflite` is a build artifact and is not committed. Until
you produce it, the app falls back to a stock COCO model and says so on screen —
it will detect nothing, by design, rather than fake a working detector.

```
python -m venv .venv && .venv\Scripts\activate
pip install -r ml/requirements.txt

python ml/train_export.py prepare --rdd2022 <path>   # optional public base
python ml/train_export.py train --epochs 100
python ml/train_export.py export                     # -> assets/models/
python ml/train_export.py verify                     # checks class names
```

**RDD2022** is the best public starting point and includes an India split,
which is much closer to local road morphology than its Japan or Czech splits.
`prepare` collapses its four damage classes onto our two (D00/D10/D20 → crack,
D40 → pothole).

**You still need local images.** RDD2022 has no hill-terrain Uttarakhand data.
Budget time to photograph and label 100–300 real Bidholi/Kandholi/Pondha
potholes and fine-tune on top. This is the single highest-leverage thing you can
do for demo quality.

`verify` exists because of a specific failure mode: the app maps model class
*names* onto its hazard classes by substring, so a model trained with RDD's raw
`D40` labels would load fine and then detect nothing. `verify` catches that
before you are standing in front of an examiner.

---

## Architecture

```
Flutter (Android)
├── 3D map          MapLibre GL Native  ← OpenFreeMap vector tiles (no API key)
├── Detection       ultralytics_yolo    ← LiteRT .tflite, fully on-device
├── Severity        pure Dart, no network
└── Sync            supabase_flutter
                          │
                    Supabase (free tier)
                    ├── Postgres + PostGIS   dedup, decay, vote counting
                    └── Storage              hazard photos
```

Everything time-critical is local. The network is touched only to sync pins and
upload photos — detection, scoring and proximity alerting all work on-device.

### Design decisions worth defending in the viva

**MapLibre over Google Maps or Mapbox.** BSD-3 licensed, no API key, no user
cap. Mapbox is free only to 25,000 monthly active users; Google Maps bills per
load. "Free for all users" was a hard constraint, so a service with *any* cap
was the wrong shape.

**`maplibre_gl` 0.27.1 over the `maplibre` 0.3.x rewrite.** The rewrite is the
long-term future and has nicer internals (FFI/JNI), but it is at 0.3.x with
~13.6k weekly downloads against 106k for the mature package. The 3D map is the
demo centrepiece; that is not the place to take a dependency risk.

**OpenFreeMap over MapTiler.** MapTiler's free tier is generous but metered. A
quota that can be exhausted is a demo that can fail. OpenFreeMap has no API key
and no request cap.

**Supabase over Firebase.** The dedup rule ("is there a pin within 20m?") is a
genuine geospatial query. PostGIS answers it with one indexed `ST_DWithin`.
Firestore has no native radius query — you would hand-roll geohashing and still
get approximate results.

**Writes go through Postgres functions, not table inserts.** `submit_report`
does "find nearby, then merge or create" in one transaction. Doing it
client-side would race: two students photographing the same pothole
simultaneously would both see "no match" and create two pins metres apart.

**Confidence is derived on read, never stored pre-decayed.** The row stores
confidence at last confirmation plus a timestamp; `current_confidence()`
applies `e^(−0.05·days)` when queried. No cron job, and a pin read at any
instant is correct.

**Severity class is derived from the discounted score, not raw area.** A crack
at 8.5% frame area is "high" by area, but the 0.85 crack multiplier pulls the
score into the medium range. Classifying from area first would produce a pin
labelled *high* while carrying a *medium* score — badge and colour disagreeing.
Tested (`crack discount` group).

**Worst detection wins, rather than summing box areas.** Summing would let a
mesh of hairline cracks outscore one axle-breaking pothole, inverting what a
rider needs warning about.

**Device IDs, not accounts.** Requiring signup before someone can photograph a
pothole kills the report rate, and the report rate is the whole product. The ID
is a random UUID in SharedPreferences, *not* a hardware identifier — no personal
data is collected, and it resets on clear-data. That trade is worth stating in
the report's ethics section.

**One alert for the nearest hazard, not one per pin.** Firing per-pin would
produce four notifications on a bad stretch and train the user to dismiss them
unread.

---

## Known limitations

State these plainly in the report. Every one is a documented trade-off, not an
oversight.

1. **Severity is a geometric proxy.** No public dataset labels road damage by
   severity, and none exists for these roads at all, so there is nothing to
   regress against. Frame-area fraction stands in. Its weakness is scale: the
   same pothole shot from 1m and 5m yields different areas. Mitigations worth
   naming (not implemented): a reference object, accelerometer-derived camera
   height, or ARCore depth.

2. **Alerts are foreground-only.** Android restricts background location hard —
   the separate `ACCESS_BACKGROUND_LOCATION` grant, battery optimisation, and
   OEM process killers on Xiaomi/Oppo/Vivo. A background service that survives
   across vendors is its own project. The app does not request the background
   permission it does not use. Claim foreground alerting; do not overclaim.

3. **The risk model is not built.** The pin sheet shows a heuristic derived from
   severity and confirmation count, labelled as such on screen. When it is
   built, it will need synthetic or heuristic labels — no local accident dataset
   exists either.

4. **Anti-abuse is minimal.** With no accounts, a malicious client could forge
   device IDs and spam reports. Server-side functions enforce one vote per
   device per pin, but that is only as good as the ID. Proper mitigation needs
   anonymous auth or device attestation — out of scope for a campus demo.

5. **Free tiers are demo-scale.** Fine for dozens to low hundreds of users;
   real deployment would need paid upgrades. Supabase free tier: 500MB
   database, 1GB storage, 50,000 MAU.

6. **Plugin API verified against source, not against a running device.**
   `predict()` returns a map with a `detections` list (not a `List<YOLOResult>`
   as the pub.dev summary states), and `YOLOResult.normalizedBox` is already a
   0–1 `Rect`. This was read off the plugin's source. `normalizedBox` falls
   back to `Rect.zero` when the platform side omits it, so
   `DetectionService._normalisedRect` falls back to the pixel box divided by
   the real image size and drops the detection rather than scoring a zero-area
   box as harmless.

7. **The bounding box is a draft.** `AppConfig.campusBounds` came from the
   brief, not a survey. Pan to the edges once tiles render and tighten it.

---

## Layout

```
lib/
  config/     app_config.dart     every tunable number, with its rationale
              map_layers.dart     3D extrusion + pin layer styling
  models/     detection.dart      hazard/severity classes, normalised boxes
              hazard_report.dart  a pin, as returned by the backend
  services/   severity.dart       scoring + decay  (pure, fully tested)
              detection_service.dart  on-device YOLO
              supabase_service.dart   all backend access
              proximity_alerts.dart   the headline alert feature
              location_service.dart, device_identity.dart
  screens/    map_home_screen.dart, capture_screen.dart
  widgets/    pin_detail_sheet.dart, detection_overlay.dart,
              pitch_control.dart, stats_overlay.dart
supabase/schema.sql      tables, PostGIS index, RPC functions, RLS
ml/train_export.py       dataset prep, training, LiteRT export, verification
test/severity_test.dart  18 tests over the scoring and decay logic
tool/setup_android.ps1   one-time platform scaffold + manifest patching
tool/check_schema.py     static app/schema consistency check (see below)
```

## Tests

```
flutter test
```

Covers the logic you will be questioned on: band boundaries, monotonicity,
saturation, the crack discount and its interaction with classification,
worst-detection selection, the decay curve at documented checkpoints, and label
matching for the class-name spellings a dataset is likely to use.

```
python tool/check_schema.py
```

Catches the app and the database drifting apart without needing a live
Postgres: a renamed RPC, a constant tuned in `app_config.dart` but not in the
schema (or vice versa), a result key the Dart reads that the SQL never
produces, a missing `grant`, or an OUT parameter that would shadow a table or
column inside PL/pgSQL. Run it after editing either side.
