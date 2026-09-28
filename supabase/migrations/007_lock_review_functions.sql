-- ============================================================================
-- Migration 007 -- URGENT: take review_queue and review_decide away from anon
--
-- Run this in the Supabase SQL Editor immediately. Safe to re-run.
--
-- The bug
-- -------
-- Migration 004 created review_queue and review_decide with a comment saying
-- they were "deliberately NOT granted to anon". Not granting is not the same
-- as revoking: CREATE FUNCTION grants EXECUTE to PUBLIC automatically, and
-- every role is implicitly a member of PUBLIC. Both functions were therefore
-- callable by anyone holding the publishable key, which ships inside the APK.
--
-- Verified against the live project before this fix:
--
--   POST /rest/v1/rpc/review_queue   -> 200  (queue of unvetted photos)
--   POST /rest/v1/rpc/review_decide  -> 204  (approval accepted)
--
-- review_decide is the serious one. It sets review_state to 'approved', which
-- is exactly what makes a quarantined pin visible on the map. Anyone could
-- therefore submit a photo of anything, have it correctly rejected by the
-- detector, file it for review, then approve it themselves -- defeating the
-- entire gate 004 exists to provide, and doing it with no credentials beyond
-- the key the app is designed to publish.
--
-- review_queue is milder but still wrong: it hands out a list of photos and
-- coordinates that no human has yet looked at.
--
-- Note the contrast with 003. There, REVOKE was a silent no-op because the
-- grants belonged to supabase_admin and could not be touched. Here the
-- functions are ours, so the revoke genuinely takes effect -- which is why it
-- is worth checking the result rather than assuming either way.
-- ============================================================================

-- PUBLIC first: that is where the automatic grant lives. Revoking only from
-- anon and authenticated would leave the PUBLIC grant behind and change
-- nothing, which is the exact trap 003 fell into.
revoke all on function review_queue(integer)        from public;
revoke all on function review_decide(uuid, boolean) from public;

revoke all on function review_queue(integer)        from anon, authenticated;
revoke all on function review_decide(uuid, boolean) from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Verify.
--
-- Expect has_execute = false for anon and authenticated on BOTH functions.
-- has_function_privilege follows every path including PUBLIC, so it is the
-- honest check -- unlike reading the grant list, where an absent row does not
-- prove the privilege is gone.
-- ---------------------------------------------------------------------------
select
  r.rolname as role,
  has_function_privilege(r.rolname, 'public.review_queue(integer)', 'execute')
    as can_run_review_queue,
  has_function_privilege(r.rolname, 'public.review_decide(uuid, boolean)', 'execute')
    as can_run_review_decide
from pg_roles r
where r.rolname in ('anon', 'authenticated')
order by r.rolname;
