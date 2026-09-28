-- ============================================================================
-- Migration 009 -- push new hazards to every device, live
--
-- Run this in the Supabase SQL Editor. Safe to re-run.
--
-- Why
-- ---
-- Pins only appeared when a device happened to call nearby_reports: on opening
-- an area, on pull-to-refresh, or after that device's own submit. A hazard
-- reported by one rider was therefore invisible to everyone else until they
-- took an action that refetched -- which for a rider already moving down the
-- corridor is exactly when it is too late to matter.
--
-- Postgres logical replication publishes the change instead, and Supabase
-- Realtime relays it over a websocket to every subscribed client.
--
-- What this does NOT do
-- ---------------------
-- The payload is not trusted as the pin. A realtime event says "something
-- changed"; the client then re-runs nearby_reports and redraws from that.
--
-- That matters for correctness, not tidiness. The replicated row is the raw
-- hazard_reports record, which is not what the map draws: the map needs
-- current_confidence() decayed to now, derived_status(), the photo count and
-- the newest photo path, and -- since 004 -- it must exclude anything sitting
-- in review_state = 'pending'. A client that painted the raw row would show
-- unvetted reports and stale confidence. Treating the event purely as a
-- trigger keeps one definition of "what belongs on the map", in the RPC.
-- ============================================================================

-- The publication Supabase Realtime reads from. It exists on every project;
-- adding a table to it is what turns that table's changes into events.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'hazard_reports'
  ) then
    alter publication supabase_realtime add table hazard_reports;
    raise notice 'hazard_reports added to supabase_realtime';
  else
    raise notice 'hazard_reports already published';
  end if;
end
$$;

-- DELETE events carry only the primary key unless the table records a full
-- old row. Without this a deletion would arrive with no id the client could
-- act on. REPLICA IDENTITY FULL is cheap here: this table is small and its
-- rows are narrow.
alter table hazard_reports replica identity full;

-- ---------------------------------------------------------------------------
-- Verify. Expect one row: public / hazard_reports.
-- ---------------------------------------------------------------------------
select schemaname, tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
order by tablename;
