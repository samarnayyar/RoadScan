-- ============================================================================
-- Migration 008 -- stop anonymous enumeration of the photo bucket
--
-- Run this in the Supabase SQL Editor. Safe to re-run.
--
-- Closes the "Public Bucket Allows Listing" advisor finding on
-- storage.hazard-photos.
--
-- The distinction that matters
-- ----------------------------
-- Two different things get conflated as "the bucket is public":
--
--   FETCHING one object you already know the path of
--     GET /storage/v1/object/public/hazard-photos/<path>
--     Governed by the bucket's `public` flag. Bypasses RLS entirely. This is
--     what the app needs, and it is why the bucket is public: map thumbnails
--     resolve without minting a signed URL for every pin.
--
--   LISTING what is in the bucket
--     POST /storage/v1/object/list/hazard-photos
--     Governed by SELECT on storage.objects. NOT needed by the app, and this
--     is the hole.
--
-- schema.sql granted the second while intending only the first. Verified
-- against the live project before this fix: the list endpoint returned HTTP
-- 200 with object names, ids and timestamps, using the publishable key that
-- ships in the APK.
--
-- Why it is worth closing even though the photos are public anyway
-- ---------------------------------------------------------------
-- Knowing a path and being able to discover every path are different
-- exposures. Storage paths are keyed by device id, so an enumerable bucket
-- hands out the full set of uploads, their timestamps, and which device made
-- each one -- a movement record for every contributor, assembled from data
-- that is individually harmless. The app's own promise on the launch screen
-- is "Your location is never stored"; a listable bucket of geotagged uploads
-- undercuts that in spirit even though no coordinate is in the object name.
--
-- What the app actually calls, checked rather than assumed:
--   getPublicUrl()  -- builds a URL string client-side, no API call
--   uploadBinary()  -- INSERT, covered by hazard_photos_insert below
-- Nothing in lib/ lists the bucket, so removing SELECT costs nothing.
-- ============================================================================

-- The listing grant. Dropping the policy removes SELECT on storage.objects
-- for these roles; it does not touch the bucket's public flag, so direct
-- fetches by path keep working.
drop policy if exists hazard_photos_read on storage.objects;

-- Upload must survive. Recreated rather than left alone so this file is
-- self-contained and re-running it cannot leave the app unable to submit.
drop policy if exists hazard_photos_insert on storage.objects;
create policy hazard_photos_insert on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'hazard-photos');

-- ---------------------------------------------------------------------------
-- Verify.
--
-- Expect exactly one policy on storage.objects for this bucket, and it should
-- be the INSERT one. A SELECT policy here means listing is still open.
-- ---------------------------------------------------------------------------
select
  policyname,
  cmd        as applies_to,
  roles
from pg_policies
where schemaname = 'storage'
  and tablename = 'objects'
  and policyname like 'hazard_photos%'
order by policyname;
