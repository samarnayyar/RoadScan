# RoadScan — step-by-step setup

Split by who has to do it.

| Step | Who | Time |
|---|---|---|
| 1. Flutter + Android SDK | Claude (running now) | ~30–60 min |
| 2. Supabase project | **You** — needs your login | ~10 min |
| 3. `flutter test` | Claude | ~2 min |
| 4. Run on a phone | **You** — needs a physical device | ~10 min |
| 5. Train the model | **You + Colab** — this machine has no GPU | ~2–4 h |
| 6. Collect local photos | **You** — physical world | a weekend |

---

## Step 1 — Flutter + Android SDK

Being done for you. Installing to `D:\dev\` because `C:` only has 12.5 GB free
and this needs about 15 GB.

- Flutter SDK 3.47.4 → `D:\dev\flutter`
- Android SDK (command-line tools, platform-tools, build-tools, API 35) →
  `D:\dev\android-sdk`

**You do not need Android Studio.** It is only a convenience wrapper around
these same SDK components plus an editor. Skipping it saves ~8 GB. If you
later want the visual emulator manager and layout inspector, install it then —
it will detect the existing SDK.

Once it finishes you will need to **open a new terminal** for the PATH change
to apply.

---

## Step 2 — Supabase (you must do this)

I cannot do this one: it needs your email, a browser login, and email
verification.

1. Go to <https://supabase.com> → **Start your project** → sign in with GitHub
   or email.
2. **New project**:
   - Name: `roadscan`
   - Database password: generate one and **save it somewhere** — you cannot
     retrieve it later, only reset it.
   - Region: **South Asia (Mumbai)** — nearest to Dehradun, so lowest latency.
   - Plan: Free
3. Wait ~2 minutes for provisioning.
4. Left sidebar → **SQL Editor** → **New query**.
5. Open `supabase/schema.sql` in this repo, copy **the entire file**, paste,
   and press **Run**.
   - Expect `Success. No rows returned.`
   - If you see `extension "postgis" is not available`, you are on a very old
     project template — create a fresh project.
6. Verify it worked. New query, run this:

   ```sql
   select proname from pg_proc
   where proname in ('submit_report','confirm_report','nearby_reports','report_timeline')
   order by proname;
   ```

   You should get exactly four rows. If you get fewer, the paste was truncated
   — re-copy the whole file.

7. Left sidebar → **Storage**. Confirm a bucket named `hazard-photos` exists
   and is marked **Public**. The schema creates it; if it is missing, create it
   manually with that exact name and public read.

8. Left sidebar → **Project Settings** → **API keys** (older dashboards:
   **Settings → API**). Copy two values:
   - **Project URL** — looks like `https://abcdefgh.supabase.co`
   - The **client key**. Supabase renamed this, so you will see one of:
     - **Publishable key** — `sb_publishable_...` (newer projects)
     - **anon / public** — a long `eyJ...` string (older projects)

     Either is fine. They are the same thing to the app, and it accepts both.

   Send me both, or put them in `supabase.json`. This key is **safe to share
   with me and safe to ship in the app** — it only grants what the RLS policies
   in the schema allow.

   > **Never** share the `service_role` / **secret** key. It bypasses all
   > row-level security. It must not go in the app or in git.

### The one free-tier trap

A free Supabase project **pauses itself after 7 days with no database
activity**. A paused project returns connection errors and the app shows no
pins.

Open the dashboard (or just run the app) **the day before your demo or viva**.
Un-pausing takes a minute or two, which is fine the day before and a disaster
five minutes before.

---

## Step 3 — `flutter test`

I will run this once Flutter is installed. It exercises the severity bands,
the crack discount, worst-detection selection, the decay curve and label
matching — 18 tests, no device or network needed.

I already verified every expected value in these tests against an independent
implementation, so they should pass. If they do not, that is a real bug and I
will fix it.

---

## Step 4 — Run it on a phone (you)

An emulator will technically run the app, but it is close to useless here: it
has no real GPS movement and a fake camera. Use a real phone.

1. On the phone: **Settings → About phone** → tap **Build number** seven times
   to unlock Developer options.
2. **Settings → Developer options** → enable **USB debugging**.
3. Plug it into the PC with a cable that carries data (many charge-only cables
   will not work — if the phone charges but never appears, that is the cable).
4. Accept the **Allow USB debugging?** prompt on the phone.
5. Check it is seen:

   ```
   flutter devices
   ```

6. Put your two Supabase values in a config file (done once), then run:

   ```
   copy supabase.example.json supabase.json
   ```

   Open `supabase.json`, paste in your Project URL and anon key, save. Then:

   ```
   flutter run --dart-define-from-file=supabase.json
   ```

   `supabase.json` is gitignored, so your keys never reach the repo.

   In VS Code you can just press **F5** instead — `.vscode/launch.json` is
   already wired to that file. It has two profiles: **RoadScan (device)** uses
   the backend, **RoadScan (no backend)** skips it so you can work on the map
   without Supabase being up.

**What you should see:** a tilted 3D map over Bidholi, buildings extruded, a
pitch slider on the left, a blue dot at your location, and a **Scan** button.
No pins yet — nothing has been reported.

---

## Step 5 — Train the model

### This machine cannot do it

The GPU here is **Intel UHD Graphics**. Ultralytics training needs CUDA, which
means NVIDIA. On CPU, 100 epochs on a few thousand images would take **days**,
not hours.

**Use Google Colab instead — it is free and gives you a real GPU.**

1. Go to <https://colab.research.google.com> → **New notebook**.
2. **Runtime → Change runtime type → T4 GPU** → Save. (Free tier includes this.)
3. Confirm you actually got the GPU:

   ```python
   !nvidia-smi
   ```

   If this errors, the runtime is still CPU — redo step 2.

4. Install and train:

   ```python
   !pip install ultralytics
   from google.colab import drive
   drive.mount('/content/drive')
   ```

5. Upload your labelled dataset to Google Drive, then train. The training call
   mirrors `ml/train_export.py`:

   ```python
   from ultralytics import YOLO
   model = YOLO('yolo26n.pt')
   model.train(
       data='/content/drive/MyDrive/roadscan/roadscan.yaml',
       epochs=100, imgsz=640, batch=16,
       hsv_v=0.4, degrees=8.0, scale=0.4, fliplr=0.5, flipud=0.0,
       patience=25,
   )
   ```

6. Export to LiteRT and download:

   ```python
   model.export(format='litert', imgsz=640, int8=True,
                data='/content/drive/MyDrive/roadscan/roadscan.yaml')
   ```

   Download the resulting `.tflite`, rename it to `roadscan.tflite`, and drop
   it in `assets/models/`. Then:

   ```
   python ml/train_export.py verify
   ```

   This checks the class names will actually be recognised by the app — a
   model trained with raw RDD labels like `D40` loads fine and then detects
   nothing, which is a horrible thing to discover during a viva.

> Colab free tier disconnects after roughly 90 minutes idle and caps daily GPU
> hours. Save checkpoints to Drive so a disconnect does not cost you the run.

### Getting a dataset

**RDD2022** is the best public base. It is multi-country and includes an India
split. Search "RDD2022 Road Damage Detection dataset" — it is distributed as a
university-hosted archive, and Roboflow Universe usually has YOLO-format
mirrors, which saves you converting PASCAL VOC XML by hand.

Once you have it in YOLO format:

```
python ml/train_export.py prepare --rdd2022 <path-to-extracted-RDD2022>
```

That collapses its four damage classes onto our two (D00/D10/D20 → crack,
D40 → pothole) and drops the non-damage classes.

---

## Step 6 — Local photos (you, and this matters most)

RDD2022 contains **no hill-terrain Uttarakhand data**. A model trained only on
it will underperform on exactly the roads you are demoing.

Take **100–300 photos** along Bidholi–Kandholi–Pondha:

- Hold the phone roughly **1–1.5 m up, angled down** at the damage — the same
  way a user reporting a pothole naturally would. Training on drone-style or
  ground-level shots teaches the wrong viewpoint.
- Vary the conditions deliberately: **morning, midday, evening**; dry and wet;
  shaded and full sun. Hill roads are heavily shadowed and that is where a
  naively-trained model falls apart.
- Include **negatives** — intact road with no damage. Without them the model
  learns "tarmac ⇒ pothole" and fires constantly.
- Get the boring cases too: small cracks, patched repairs, gravel edges.

Label them with **Roboflow** (easiest — web-based, exports YOLO format
directly), or labelImg / CVAT locally. Use exactly two class names:
`pothole` and `crack`.

This is the single highest-leverage thing you can do for demo quality. A
mediocre model on local data will demo far better than a good model on
foreign data.

---

## Quick reference

```
flutter test                      # logic tests, no device
python tool/check_schema.py       # app/database consistency
python ml/train_export.py verify  # model class-name contract
flutter run --dart-define=...     # on a connected phone
```
