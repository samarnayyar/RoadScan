-- ============================================================================
-- Migration 002 -- backdated reports and observation time
--
-- Run this in the Supabase SQL Editor AFTER schema.sql. Safe to re-run.
--
-- Why: a user can now upload a photo taken days earlier from their gallery.
-- Until now every report was stamped now(), which would have claimed a
-- three-day-old pothole photo was observed this second. For an app whose whole
-- value is freshness -- confidence decay, "last confirmed", stale pins -- that
-- is not a cosmetic error, it corrupts the time series.
--
-- The photo's EXIF DateTimeOriginal now drives:
--   * report_photos.captured_at   -- when the road actually looked like that
--   * hazard_reports.created_at   -- for a new pin, its first observation
--   * last_confirmed_at           -- so decay runs from the OBSERVATION, not
--                                    the upload. A six-month-old photo
--                                    therefore creates an already-stale pin,
--                                    which is the honest outcome.
-- ============================================================================

-- Distinguishes "when the photo was taken" from "when the row was written".
-- Useful for auditing and for spotting bulk backfills after the fact.
alter table report_photos
  add column if not exists uploaded_at timestamptz not null default now();

alter table hazard_reports
  add column if not exists last_observed_at timestamptz;

update hazard_reports
   set last_observed_at = last_confirmed_at
 where last_observed_at is null;

-- Drop the 8-argument version from schema.sql FIRST.
--
-- `create or replace function` only replaces a function with the SAME argument
-- list. Adding p_captured_at makes this a different signature, so without this
-- drop Postgres keeps BOTH and we end up with an overload pair. That breaks two
-- things:
--
--   1. Any unqualified `grant`/`drop` on the name becomes ambiguous --
--      "42725: function name submit_report is not unique" -- which is exactly
--      how this migration failed the first time it was run.
--   2. Far worse, the old version stays callable and still stamps now() as the
--      observation time, silently reintroducing the time-series corruption this
--      migration exists to remove.
--
-- Safe to run: the app always sends p_captured_at, so nothing calls the 8-arg
-- form, and no policy or view depends on it.
drop function if exists submit_report(
  double precision, double precision, double precision,
  severity_class, hazard_class, text, text, double precision
);

create or replace function submit_report(
  p_lat            double precision,
  p_lon            double precision,
  p_severity_score double precision,
  p_severity       severity_class,
  p_hazard         hazard_class,
  p_device_id      text,
  p_storage_path   text,
  p_radius_m       double precision default 20.0,
  p_captured_at    timestamptz default null
)
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
  v_observed timestamptz;
begin
  -- Trust the client's timestamp only within reason. A camera with a wrong
  -- clock, or a deliberately forged one, could otherwise post-date a pin so it
  -- never decays and sits at full confidence forever. Future dates clamp to
  -- now; anything absurdly old is still accepted, because a genuinely old
  -- photo is legitimate -- it will simply be born stale.
  v_observed := least(coalesce(p_captured_at, now()), now());

  select * into v_existing
  from hazard_reports
  where status <> 'likely_fixed'
    and hazard = p_hazard
    and st_dwithin(location, v_point, p_radius_m)
  order by location <-> v_point
  limit 1;

  if found then
    insert into confirmations (hazard_report_id, device_id, was_negative)
    values (v_existing.id, p_device_id, false)
    on conflict (hazard_report_id, device_id, was_negative) do nothing;

    update hazard_reports
       set confirmation_count = (
             select greatest(count(distinct c.device_id), 1)
             from confirmations c
             where c.hazard_report_id = v_existing.id and not c.was_negative
           ),
           base_confidence    = 1.0,
           -- An OLDER photo must not make the pin look fresher than it is, so
           -- only move the clock forward. Uploading a week-old photo of a pin
           -- confirmed yesterday should not age it back a week.
           last_confirmed_at  = greatest(last_confirmed_at, v_observed),
           last_observed_at   = greatest(
                                  coalesce(last_observed_at, v_observed),
                                  v_observed),
           severity           = case when p_severity_score > severity_score
                                     then p_severity else severity end,
           severity_score     = greatest(severity_score, p_severity_score),
           status             = 'active'
     where id = v_existing.id;

    insert into report_photos
      (hazard_report_id, storage_path, is_original, severity_score, captured_at)
    values (v_existing.id, p_storage_path, false, p_severity_score, v_observed);

    return query
      select hr.id, true, hr.confirmation_count
      from hazard_reports hr where hr.id = v_existing.id;
  else
    insert into hazard_reports
      (location, severity_score, severity, hazard,
       created_at, last_confirmed_at, last_observed_at)
    values (v_point, p_severity_score, p_severity, p_hazard,
            v_observed, v_observed, v_observed)
    returning * into v_existing;

    insert into confirmations (hazard_report_id, device_id, was_negative)
    values (v_existing.id, p_device_id, false);

    insert into report_photos
      (hazard_report_id, storage_path, is_original, severity_score, captured_at)
    values (v_existing.id, p_storage_path, true, p_severity_score, v_observed);

    return query select v_existing.id, false, 1;
  end if;
end;
$fn$;

-- Argument list spelled out rather than `grant ... on function submit_report`.
-- The bare form only works while exactly one function carries the name, so it
-- is a latent failure the moment anyone adds an overload. Being explicit costs
-- one line and cannot break that way.
grant execute on function submit_report(
  double precision, double precision, double precision,
  severity_class, hazard_class, text, text, double precision, timestamptz
) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- device_reports -- backs the "my reports" / incident list in the drawer.
-- Everything this device has contributed to, newest activity first.
-- ---------------------------------------------------------------------------
create or replace function device_reports(p_device_id text)
returns table (
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
  photo_count        integer,
  latest_photo       text,
  i_reported         boolean
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
    (select count(*)::integer from report_photos rp
      where rp.hazard_report_id = hr.id),
    (select rp.storage_path from report_photos rp
      where rp.hazard_report_id = hr.id
      order by rp.captured_at desc limit 1),
    true
  from hazard_reports hr
  where exists (
    select 1 from confirmations c
    where c.hazard_report_id = hr.id and c.device_id = p_device_id
  )
  order by hr.last_confirmed_at desc;
$fn$;

grant execute on function device_reports to anon, authenticated;

-- ---------------------------------------------------------------------------
-- all_reports -- every pin in the area, for the incident list.
-- ---------------------------------------------------------------------------
create or replace function all_reports(p_limit integer default 200)
returns table (
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
  photo_count        integer,
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
    (select count(*)::integer from report_photos rp
      where rp.hazard_report_id = hr.id),
    (select rp.storage_path from report_photos rp
      where rp.hazard_report_id = hr.id
      order by rp.captured_at desc limit 1)
  from hazard_reports hr
  order by hr.last_confirmed_at desc
  limit p_limit;
$fn$;

grant execute on function all_reports to anon, authenticated;
