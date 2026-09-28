-- ============================================================================
-- Migration 006 -- recovery snapshot for spatial_ref_sys
--
-- Run this in the Supabase SQL Editor. Safe to re-run.
--
-- Why a snapshot instead of a fix
-- -------------------------------
-- The write grants on public.spatial_ref_sys cannot be revoked from this
-- project. Established by elimination, not assumption:
--
--   1. `alter table ... enable row level security` -> must be owner. The
--      table belongs to the PostGIS extension, not to us.
--   2. `revoke ... from anon, authenticated`       -> ran without error and
--      changed nothing. REVOKE only removes grants made BY the role running
--      it, and Postgres does not complain when there is nothing of yours to
--      remove. This is the trap: it looks like it worked.
--   3. `revoke ... granted by supabase_admin`      -> ERROR 0A000, "grantor
--      must be current user". Only supabase_admin can revoke its own grants,
--      and that role is not reachable from the SQL Editor.
--
--   Confirmed against the live API throughout: DELETE and PATCH on
--   spatial_ref_sys are still accepted with the publishable key alone.
--
-- The only real fixes are moving PostGIS out of `public` (the "Extension in
-- Public" advisor finding) or asking Supabase support to revoke it. Both are
-- out of scope for a deadline, and relocating an extension that owns the type
-- behind hazard_reports.location risks breaking a working backend.
--
-- So: accept the risk, and make recovery cheap.
--
-- What the exposure actually is
-- -----------------------------
-- Availability, not confidentiality. Nobody can read or alter a hazard report
-- through this. What they can do is delete rows from the EPSG catalogue --
-- notably SRID 4326, which hazard_reports.location depends on -- and thereby
-- break inserts and proximity queries until it is restored.
--
-- Restoring it is the whole problem, and this removes it. spatial_ref_sys is
-- static public reference data, identical in every PostGIS install, so a copy
-- is a complete and permanently valid backup.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The snapshot, in a table we DO own.
--
-- Ownership is the point: this table is created by us, so unlike
-- spatial_ref_sys itself we can lock it down.
-- ---------------------------------------------------------------------------
create table if not exists spatial_ref_sys_backup (like public.spatial_ref_sys);

-- Refresh rather than append, so re-running is idempotent and always captures
-- the current truth.
truncate spatial_ref_sys_backup;
insert into spatial_ref_sys_backup select * from public.spatial_ref_sys;

-- ---------------------------------------------------------------------------
-- 2. Lock the backup down.
--
-- RLS on with NO policy denies every client role outright -- there is no
-- policy to satisfy. That is exactly what is wanted here: nothing in the app
-- reads this table, so the safest posture is total denial to anon. Without
-- this, the backup would sit in `public` and be as deletable as the thing it
-- is backing up, which would make it worthless.
-- ---------------------------------------------------------------------------
alter table spatial_ref_sys_backup enable row level security;
revoke all on table spatial_ref_sys_backup from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Restore, if it is ever needed.
--
-- Run this block by hand from the SQL Editor after an incident:
--
--   insert into public.spatial_ref_sys
--   select * from spatial_ref_sys_backup b
--   where not exists (
--     select 1 from public.spatial_ref_sys s where s.srid = b.srid
--   );
--
-- Deliberately additive: it puts back what is missing and leaves anything
-- still present alone, so it is safe to run when you are unsure how much was
-- damaged. A blunt truncate-and-reload would fail against any FK-ish
-- dependency mid-incident.
--
-- Not wrapped in a function on purpose. A restore should be a conscious act
-- by someone who has looked at the damage, not something callable.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 4. Verify: counts should match, and the backup must be unreadable by anon.
-- ---------------------------------------------------------------------------
select
  (select count(*) from public.spatial_ref_sys)  as live_rows,
  (select count(*) from spatial_ref_sys_backup)  as backup_rows,
  (select count(*) from spatial_ref_sys_backup where srid = 4326)
                                                 as has_srid_4326,
  (select relrowsecurity from pg_class
    where relname = 'spatial_ref_sys_backup')    as backup_rls_on;
