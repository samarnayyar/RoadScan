-- ============================================================================
-- Migration 003 -- close the `rls_disabled_in_public` advisor finding
--
-- Run this in the Supabase SQL Editor. Safe to re-run.
--
-- What the alert is actually about
-- --------------------------------
-- Not one of RoadScan's own tables. hazard_reports, report_photos and
-- confirmations all have RLS enabled with read-only policies (see schema.sql),
-- and every write goes through a security-definer function. Verified against
-- the live project.
--
-- The flagged table is `public.spatial_ref_sys`: the EPSG coordinate-system
-- catalogue that the PostGIS extension creates when it is installed into the
-- `public` schema, which is Supabase's default. It is owned by the extension,
-- not by us, so it never passed through schema.sql and never got RLS.
--
-- Measured on the live project with the publishable key alone:
--
--   GET    /rest/v1/spatial_ref_sys   -> 200, 8,500 rows readable
--   PATCH  /rest/v1/spatial_ref_sys   -> 204, accepted
--   DELETE /rest/v1/spatial_ref_sys   -> 204, accepted
--
-- (The write probes used filters that match no row, so nothing was modified.)
--
-- Why this matters more than "it is only reference data"
-- ------------------------------------------------------
-- Reading it leaks nothing -- it is the public EPSG registry, byte-identical
-- in every PostGIS install on earth. The danger is the WRITE grant.
--
-- hazard_reports.location is `geography(Point, 4326)`. SRID 4326 is a row in
-- this table. Anyone who extracts the publishable key from the shipped APK --
-- which takes minutes, and which is expected, since that key is designed to be
-- public -- can issue one DELETE and take out the spatial reference the column
-- depends on. Inserts and proximity queries then fail and the map backend
-- stops working. That is an availability attack with no recovery short of
-- reinstalling PostGIS, and it needs no credentials anyone is not meant to
-- have.
--
-- RLS is the only boundary in this design, because there are no user accounts:
-- every client is `anon` by deliberate choice.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Remove the write grants. This is the part that closes the real hole.
--
-- SELECT is deliberately left in place. PostGIS reads this table internally
-- for coordinate work, and revoking it risks breaking spatial operations for
-- no security gain, given the contents are public knowledge.
-- ---------------------------------------------------------------------------
revoke insert, update, delete, truncate
  on table public.spatial_ref_sys
  from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Enable RLS as well, if we are allowed to.
--
-- Wrapped in a DO block because ALTER TABLE requires ownership, and this table
-- belongs to the PostGIS extension. On a managed Supabase project the SQL
-- Editor often cannot take ownership of it, in which case this raises
-- `must be owner of table spatial_ref_sys`.
--
-- That failure is tolerable and is NOT left unhandled: step 1 has already
-- removed the ability to write, so the exploitable part is gone either way.
-- What remains without RLS is a linter finding about a readable public table,
-- not an exposure.
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'alter table public.spatial_ref_sys enable row level security';

  -- With RLS on and no policy, even SELECT would be denied, which would break
  -- PostGIS. Add the read-everyone policy back explicitly.
  execute 'drop policy if exists spatial_ref_sys_read on public.spatial_ref_sys';
  execute 'create policy spatial_ref_sys_read on public.spatial_ref_sys '
          'for select to anon, authenticated using (true)';

  raise notice 'RLS enabled on spatial_ref_sys with a read-only policy';
exception
  when insufficient_privilege or others then
    raise notice
      'Could not enable RLS on spatial_ref_sys (%). This is expected on '
      'managed Supabase: the table is owned by the PostGIS extension. The '
      'write grants revoked above are the substantive fix; the advisor may '
      'still show the finding.', sqlerrm;
end
$$;

-- ---------------------------------------------------------------------------
-- 3. Verify.
--
-- Expect: has_write = false for anon and authenticated on spatial_ref_sys,
-- and rls_enabled = true for all three RoadScan tables.
-- ---------------------------------------------------------------------------
select
  r.rolname                                                as role,
  has_table_privilege(r.rolname, 'public.spatial_ref_sys', 'select') as can_read,
  (has_table_privilege(r.rolname, 'public.spatial_ref_sys', 'insert')
   or has_table_privilege(r.rolname, 'public.spatial_ref_sys', 'update')
   or has_table_privilege(r.rolname, 'public.spatial_ref_sys', 'delete'))
                                                           as has_write
from pg_roles r
where r.rolname in ('anon', 'authenticated');

select
  c.relname   as table_name,
  c.relrowsecurity as rls_enabled,
  (select count(*) from pg_policies p
    where p.schemaname = 'public' and p.tablename = c.relname) as policies
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind = 'r'
  and c.relname in ('hazard_reports', 'report_photos', 'confirmations',
                    'spatial_ref_sys')
order by c.relname;
