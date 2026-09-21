-- ============================================================================
-- Remove the self-test rows written while verifying the backend.
--
-- Run this in the Supabase SQL Editor. Safe to run more than once.
--
-- Why this file exists: the dedup, merge and confirmation rules had never been
-- executed against a real PostGIS instance, only reasoned about. Verifying them
-- meant writing real rows. The client role deliberately has no DELETE policy
-- (see the RLS section of schema.sql), so the cleanup has to run here, with
-- your dashboard privileges, rather than from the app.
--
-- Every test row is tagged by a device_id starting 'claude-', so the cleanup
-- can be exact rather than "delete everything".
-- ============================================================================

-- Pins whose ONLY confirmations came from test devices. The NOT EXISTS guard
-- matters: if you have since reported a real hazard that merged into one of
-- these pins, this leaves it alone instead of deleting your real data.
-- report_photos and confirmations clear themselves via ON DELETE CASCADE.
delete from hazard_reports hr
where exists (
        select 1 from confirmations c
        where c.hazard_report_id = hr.id
          and c.device_id like 'claude-%'
      )
  and not exists (
        select 1 from confirmations c
        where c.hazard_report_id = hr.id
          and c.device_id not like 'claude-%'
      );

-- Any stray test votes left on pins that survived the check above.
delete from confirmations where device_id like 'claude-%';

-- Confirm the table is clear (expect 0 unless you have real reports).
select count(*) as remaining_reports from hazard_reports;

-- The test runs referenced storage paths under selftest/ but never uploaded
-- any bytes, so there is nothing to remove from the hazard-photos bucket.
