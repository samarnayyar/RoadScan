-- ============================================================================
-- RoadScan -- Supabase / PostgreSQL schema
-- Run this in the Supabase SQL Editor (Dashboard -> SQL Editor -> New query).
--
-- Design notes:
--   * `location` is geography(Point,4326), NOT geometry. Geography makes
--     ST_DWithin take its radius in METRES directly, which is what the 15-20m
--     dedup rule needs. With geometry(4326) the radius would be in degrees and
--     the dedup distance would silently vary with latitude.
--   * Confidence is never stored pre-decayed. We store the confidence at the
--     moment of last confirmation plus the timestamp, and derive the current
--     value on read. This avoids needing a cron job to age rows, and means a
--     pin read at any instant is correct without a background worker.
-- ============================================================================

create extension if not exists postgis;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
do $enums$ begin
  create type severity_class as enum ('low', 'medium', 'high', 'critical');
exception when duplicate_object then null; end $enums$;

do $enums$ begin
  create type hazard_class as enum ('pothole', 'crack');
exception when duplicate_object then null; end $enums$;

do $enums$ begin
  create type report_status as enum ('active', 'stale', 'likely_fixed');
exception when duplicate_object then null; end $enums$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table if not exists hazard_reports (
  id                  uuid primary key default gen_random_uuid(),
  location            geography(Point, 4326) not null,
  severity_score      double precision not null check (severity_score between 0 and 1),
  severity            severity_class not null,
  hazard              hazard_class not null,

  -- Confidence as of `last_confirmed_at`. Decayed on read; see current_confidence().
  base_confidence     double precision not null default 1.0
                        check (base_confidence between 0 and 1),

  confirmation_count  integer not null default 1,
  negative_count      integer not null default 0,
  status              report_status not null default 'active',
  risk_level          text,

  created_at          timestamptz not null default now(),
  last_confirmed_at   timestamptz not null default now()
);

-- The dedup query (ST_DWithin) is the hottest path in the app: it runs on every
-- single report submission. Without this index it degrades to a full scan.
create index if not exists hazard_reports_location_idx
  on hazard_reports using gist (location);

create index if not exists hazard_reports_status_idx
  on hazard_reports (status, last_confirmed_at desc);

create table if not exists report_photos (
  id                uuid primary key default gen_random_uuid(),
  hazard_report_id  uuid not null references hazard_reports(id) on delete cascade,
  storage_path      text not null,
  captured_at       timestamptz not null default now(),
  is_original       boolean not null default false,
  severity_score    double precision,
  created_at        timestamptz not null default now()
);

create index if not exists report_photos_report_idx
  on report_photos (hazard_report_id, captured_at desc);

create table if not exists confirmations (
  id                uuid primary key default gen_random_uuid(),
  hazard_report_id  uuid not null references hazard_reports(id) on delete cascade,
  device_id         text not null,
  was_negative      boolean not null default false,
  confirmed_at      timestamptz not null default now()
);

-- One device gets one vote per pin per direction. Without this, a single user
-- could tap "Confirm" three times and trip the 3-device fixed threshold alone.
create unique index if not exists confirmations_unique_vote_idx
  on confirmations (hazard_report_id, device_id, was_negative);

-- ---------------------------------------------------------------------------
-- Confidence decay
--   confidence = base * e^(-lambda * days_since_last_confirmed),  lambda = 0.05
-- ---------------------------------------------------------------------------
create or replace function current_confidence(
  base double precision,
  last_confirmed timestamptz
) returns double precision
language sql immutable parallel safe as $fn$
  select greatest(0.0, least(1.0,
    base * exp(-0.05 * (extract(epoch from (now() - last_confirmed)) / 86400.0))
  ));
$fn$;

-- Status is derived, not hand-set: a pin becomes 'stale' once 30 days pass with
-- no re-confirmation. 'likely_fixed' is sticky and always wins.
create or replace function derived_status(
  current_status report_status,
  last_confirmed timestamptz
) returns report_status
language sql immutable parallel safe as $fn$
  select case
    when current_status = 'likely_fixed' then 'likely_fixed'::report_status
    when now() - last_confirmed > interval '30 days' then 'stale'::report_status
    else 'active'::report_status
  end;
$fn$;

-- ---------------------------------------------------------------------------
-- submit_report -- the dedup / merge entry point.
--
-- This is deliberately ONE round trip and ONE transaction. Doing the
-- "search nearby, then insert or update" dance from the client would race:
-- two students photographing the same pothole at the same moment would both
-- see "no match" and create two pins 3m apart.
--
-- Returns the pin the photo ended up attached to, and whether it was a fresh
-- pin or a re-confirmation of an existing one.
-- ---------------------------------------------------------------------------
create or replace function submit_report(
  p_lat            double precision,
  p_lon            double precision,
  p_severity_score double precision,
  p_severity       severity_class,
  p_hazard         hazard_class,
  p_device_id      text,
  p_storage_path   text,
  p_radius_m       double precision default 20.0
)
-- OUT parameters are prefixed `out_` throughout. In PL/pgSQL an OUT parameter
-- is a variable in scope over the whole body, so naming one `confirmations`
-- or `status` would shadow the table of that name and the hazard_reports
-- column of that name -- which surfaces as a confusing ambiguity error at call
-- time, not at creation time.
returns table (
  out_report_id     uuid,
  out_was_merged    boolean,
  out_confirmations integer
)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_point    geography := st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography;
  v_existing hazard_reports%rowtype;
begin
  -- Nearest existing pin of the SAME hazard class within the radius. Ordering
  -- by distance matters: with three pins in range we must merge into the
  -- closest one, not an arbitrary one.
  select * into v_existing
  from hazard_reports
  where status <> 'likely_fixed'
    and hazard = p_hazard
    and st_dwithin(location, v_point, p_radius_m)
  order by location <-> v_point
  limit 1;

  if found then
    -- Record the vote BEFORE recomputing the count, so this submission is
    -- included in it.
    insert into confirmations (hazard_report_id, device_id, was_negative)
    values (v_existing.id, p_device_id, false)
    on conflict (hazard_report_id, device_id, was_negative) do nothing;

    -- Re-confirmation: confidence resets to full and the new photo joins that
    -- pin's timeline rather than starting a new one. Severity takes the worst
    -- observation seen so far -- a pothole does not get better on its own, and
    -- a bad-angle photo should not be able to downgrade a critical pin.
    --
    -- confirmation_count is recomputed as DISTINCT confirming devices rather
    -- than incremented per photo. It has to mean the same thing here as it
    -- does in confirm_report(), or one function would count photos while the
    -- other counted devices and the badge would jump around depending on which
    -- path last touched the row.
    update hazard_reports
       set confirmation_count = (
             select greatest(count(distinct c.device_id), 1)
             from confirmations c
             where c.hazard_report_id = v_existing.id and not c.was_negative
           ),
           base_confidence    = 1.0,
           last_confirmed_at  = now(),
           severity           = case when p_severity_score > severity_score
                                     then p_severity else severity end,
           severity_score     = greatest(severity_score, p_severity_score),
           status             = 'active'
     where id = v_existing.id;

    insert into report_photos (hazard_report_id, storage_path, is_original, severity_score)
    values (v_existing.id, p_storage_path, false, p_severity_score);

    return query
      select hr.id, true, hr.confirmation_count
      from hazard_reports hr where hr.id = v_existing.id;
  else
    insert into hazard_reports (location, severity_score, severity, hazard)
    values (v_point, p_severity_score, p_severity, p_hazard)
    returning * into v_existing;

    insert into confirmations (hazard_report_id, device_id, was_negative)
    values (v_existing.id, p_device_id, false);

    insert into report_photos (hazard_report_id, storage_path, is_original, severity_score)
    values (v_existing.id, p_storage_path, true, p_severity_score);

    return query select v_existing.id, false, 1;
  end if;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- confirm_report -- explicit Confirm / Mark-Fixed votes from the detail sheet.
--
-- `p_negative = true` means "I was here and saw no hazard", which is evidence
-- toward repair. Three DISTINCT devices voting negative flip the pin to
-- likely_fixed. Counting distinct device_ids (not rows) is what makes the
-- 3-device rule actually mean three devices.
-- ---------------------------------------------------------------------------
create or replace function confirm_report(
  p_report_id uuid,
  p_device_id text,
  p_negative  boolean default false
) returns table (
  out_report_id     uuid,
  out_status        report_status,
  out_confirmations integer,
  out_negatives     integer
)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_negatives integer;
  v_positives integer;
begin
  insert into confirmations (hazard_report_id, device_id, was_negative)
  values (p_report_id, p_device_id, p_negative)
  on conflict (hazard_report_id, device_id, was_negative) do nothing;

  select count(distinct device_id) filter (where was_negative),
         count(distinct device_id) filter (where not was_negative)
    into v_negatives, v_positives
  from confirmations where hazard_report_id = p_report_id;

  -- Note on the status expression below: inside an UPDATE, every column
  -- reference in SET reads the OLD row. So calling
  -- derived_status(status, last_confirmed_at) on a positive vote would test the
  -- PREVIOUS timestamp -- and a pin that had gone stale would be recomputed as
  -- stale again, immediately undoing the confirmation that just arrived. Hence
  -- the explicit 'active' branch rather than deriving it.
  update hazard_reports
     set negative_count     = v_negatives,
         confirmation_count = greatest(v_positives, 1),
         base_confidence    = case when p_negative then base_confidence else 1.0 end,
         last_confirmed_at  = case when p_negative then last_confirmed_at else now() end,
         status             = case
                                when v_negatives >= 3 then 'likely_fixed'::report_status
                                when not p_negative   then 'active'::report_status
                                else derived_status(status, last_confirmed_at)
                              end
   where id = p_report_id;

  return query
    select hr.id, hr.status, hr.confirmation_count, hr.negative_count
    from hazard_reports hr where hr.id = p_report_id;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- nearby_reports -- what the map and the proximity alerts both read.
-- Returns live (decayed) confidence and derived status so the client never has
-- to reimplement the decay curve and drift out of sync with the server.
-- ---------------------------------------------------------------------------
create or replace function nearby_reports(
  p_lat      double precision,
  p_lon      double precision,
  p_radius_m double precision default 3000.0
) returns table (
  id                 uuid,
  lat                double precision,
  lon                double precision,
  severity_score     double precision,
  severity           severity_class,
  hazard             hazard_class,
  confidence         double precision,
  confirmation_count integer,
  status             report_status,
  risk_level         text,
  created_at         timestamptz,
  last_confirmed_at  timestamptz,
  distance_m         double precision,
  latest_photo       text
)
language sql stable as $fn$
  select
    hr.id,
    st_y(hr.location::geometry),
    st_x(hr.location::geometry),
    hr.severity_score,
    hr.severity,
    hr.hazard,
    current_confidence(hr.base_confidence, hr.last_confirmed_at),
    hr.confirmation_count,
    derived_status(hr.status, hr.last_confirmed_at),
    hr.risk_level,
    hr.created_at,
    hr.last_confirmed_at,
    st_distance(hr.location, st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography),
    (select rp.storage_path from report_photos rp
      where rp.hazard_report_id = hr.id
      order by rp.captured_at desc limit 1)
  from hazard_reports hr
  where st_dwithin(hr.location, st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography, p_radius_m)
  -- Nearest first. Written out rather than as "order by 13" so that inserting a
  -- column into the select list above cannot silently start sorting by the
  -- wrong thing.
  order by st_distance(
    hr.location, st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography);
$fn$;

-- ---------------------------------------------------------------------------
-- report_timeline -- every photo attached to one pin, oldest first.
-- Backs the "see how it changed over time" carousel in the detail sheet.
-- ---------------------------------------------------------------------------
create or replace function report_timeline(p_report_id uuid)
returns table (
  storage_path   text,
  captured_at    timestamptz,
  is_original    boolean,
  severity_score double precision
)
language sql stable as $fn$
  select rp.storage_path, rp.captured_at, rp.is_original, rp.severity_score
  from report_photos rp
  where rp.hazard_report_id = p_report_id
  order by rp.captured_at asc;
$fn$;

-- ---------------------------------------------------------------------------
-- Row Level Security
--
-- RoadScan has no per-user accounts by design (zero signup friction was an
-- explicit requirement), so every client is the `anon` role. These policies are
-- therefore permissive: anyone may read all pins, but NOBODY may insert,
-- update or delete a pin directly from the client. All writes go through the
-- security-definer functions above, which enforce the dedup, one-vote-per-
-- device, and 3-device-fixed rules.
--
-- Trade-off to state in the report: a malicious client could still spam
-- reports from forged device_ids. Mitigating that properly needs anonymous
-- auth or device attestation, which is out of scope for a campus demo.
-- ---------------------------------------------------------------------------
alter table hazard_reports enable row level security;
alter table report_photos  enable row level security;
alter table confirmations  enable row level security;

drop policy if exists hazard_reports_read on hazard_reports;
create policy hazard_reports_read on hazard_reports
  for select to anon, authenticated using (true);

drop policy if exists report_photos_read on report_photos;
create policy report_photos_read on report_photos
  for select to anon, authenticated using (true);

drop policy if exists confirmations_read on confirmations;
create policy confirmations_read on confirmations
  for select to anon, authenticated using (true);

-- Argument lists are spelled out. An unqualified `grant execute on function
-- <name>` only resolves while exactly one function carries that name, so it
-- fails with "42725: function name is not unique" the moment an overload
-- exists -- which is precisely what migration 002 introduced for
-- submit_report before it was corrected to drop the old signature.
grant execute on function submit_report(
  double precision, double precision, double precision,
  severity_class, hazard_class, text, text, double precision
) to anon, authenticated;
grant execute on function confirm_report(uuid, text, boolean)
  to anon, authenticated;
grant execute on function nearby_reports(double precision, double precision, double precision)
  to anon, authenticated;
grant execute on function report_timeline(uuid)
  to anon, authenticated;

-- NOTE: if you re-run this file on a database that already has migration 002
-- applied, it recreates the 8-argument submit_report that 002 deliberately
-- dropped, leaving the overload pair back in place. Re-run
-- migrations/002_captured_at.sql afterwards to clear it.

-- ---------------------------------------------------------------------------
-- Storage bucket for hazard photos (public read, so map thumbnails resolve
-- without signed URLs).
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('hazard-photos', 'hazard-photos', true)
on conflict (id) do nothing;

drop policy if exists hazard_photos_read on storage.objects;
create policy hazard_photos_read on storage.objects
  for select to anon, authenticated using (bucket_id = 'hazard-photos');

drop policy if exists hazard_photos_insert on storage.objects;
create policy hazard_photos_insert on storage.objects
  for insert to anon, authenticated with check (bucket_id = 'hazard-photos');
