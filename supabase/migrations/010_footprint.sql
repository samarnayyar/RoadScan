-- ============================================================================
-- Migration 010 -- store the estimated ground size of the damage
--
-- Run this in the Supabase SQL Editor AFTER 004. Safe to re-run.
--
-- Why store it rather than derive it on the map
-- ---------------------------------------------
-- The size is estimated from the DETECTION BOX and the photo's aspect ratio
-- (see lib/services/ground_footprint.dart). Neither survives upload: the map
-- receives a coordinate and a storage path, not the box that produced them.
-- Recomputing on the map would mean re-running the detector on every pin on
-- every device, which is absurd for a number that never changes after
-- capture.
--
-- Computed once, on the phone that took the photo, against the image that
-- produced it. Every device then draws the same size.
--
-- What the numbers are
-- --------------------
-- An ESTIMATE under an assumed camera pose -- roughly 1.35 m high, tilted 50
-- degrees down, 67 degree horizontal field of view -- projected onto a flat
-- road plane. Single-image metric recovery is otherwise impossible: there is
-- no reference object, no stereo, no depth sensor, and EXIF never records how
-- high the phone was held.
--
-- Nullable on purpose, and it is NOT a defect when they are null:
--   * every report filed before this migration has none;
--   * the estimator refuses boxes whose rays never meet the road plane
--     (sky in the box) or that sit too near the horizon to trust, because a
--     number nobody should believe is worse than no number.
-- Anything reading these must handle null rather than defaulting to a size.
-- ============================================================================

alter table hazard_reports
  add column if not exists width_m  double precision,
  add column if not exists length_m double precision;

-- Guards against a client sending nonsense. The estimator already rejects
-- out-of-range values, but the estimator runs on a device we do not control
-- and these columns decide how large something is drawn on everyone's map.
alter table hazard_reports
  drop constraint if exists hazard_reports_footprint_sane;
alter table hazard_reports
  add constraint hazard_reports_footprint_sane check (
    (width_m  is null or (width_m  > 0.02 and width_m  < 15.0)) and
    (length_m is null or (length_m > 0.02 and length_m < 25.0))
  );

-- ---------------------------------------------------------------------------
-- submit_report gains the two measurements.
--
-- The 10-argument form from 004 is dropped first. Same reasoning as 002 and
-- 004: `create or replace` with a different argument list creates an OVERLOAD
-- rather than replacing, every unqualified grant then fails with "42725:
-- function name is not unique", and worse, the old version stays callable and
-- silently files reports with no footprint.
-- ---------------------------------------------------------------------------
drop function if exists submit_report(
  double precision, double precision, double precision,
  severity_class, hazard_class, text, text, double precision, timestamptz, text
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
  p_captured_at    timestamptz default null,
  p_review_note    text default null,
  p_width_m        double precision default null,
  p_length_m       double precision default null
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
  v_review   review_state := case when p_review_note is null
                                  then 'auto'::review_state
                                  else 'pending'::review_state end;
begin
  v_observed := least(coalesce(p_captured_at, now()), now());

  if v_review = 'auto' then
    select * into v_existing
    from hazard_reports
    where status <> 'likely_fixed'
      and review_state <> 'pending'
      and hazard = p_hazard
      and st_dwithin(location, v_point, p_radius_m)
    order by location <-> v_point
    limit 1;
  end if;

  if found and v_review = 'auto' then
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
           last_confirmed_at  = greatest(last_confirmed_at, v_observed),
           last_observed_at   = greatest(
                                  coalesce(last_observed_at, v_observed),
                                  v_observed),
           severity           = case when p_severity_score > severity_score
                                     then p_severity else severity end,
           severity_score     = greatest(severity_score, p_severity_score),
           -- Keep the LARGER estimate when two reports disagree, and never
           -- overwrite a real measurement with a null. Two photos of one
           -- pothole from different distances give different numbers; the
           -- bigger one is the safer thing to draw, because understating a
           -- hazard on a map is the more costly error.
           width_m            = greatest(coalesce(width_m, 0),
                                         coalesce(p_width_m, 0)),
           length_m           = greatest(coalesce(length_m, 0),
                                         coalesce(p_length_m, 0)),
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
       created_at, last_confirmed_at, last_observed_at,
       review_state, review_note, width_m, length_m)
    values (v_point, p_severity_score, p_severity, p_hazard,
            v_observed, v_observed, v_observed,
            v_review, p_review_note, p_width_m, p_length_m)
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

grant execute on function submit_report(
  double precision, double precision, double precision,
  severity_class, hazard_class, text, text, double precision, timestamptz,
  text, double precision, double precision
) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- The read paths must return the new columns, or the map cannot draw them.
--
-- DROP first, deliberately. Adding a column to a `returns table (...)` list
-- changes the function's return TYPE, and `create or replace` refuses that
-- with "42P13: cannot change return type of existing function". This is the
-- one case where dropping is correct rather than lazy -- and it is safe here
-- because the Dart client reads rows by column NAME, so two extra keys in
-- the JSON are ignored by older builds rather than breaking them.
--
-- Both are recreated with their 004 bodies (the review_state filter) intact.
-- ---------------------------------------------------------------------------
drop function if exists nearby_reports(double precision, double precision, double precision);

create function nearby_reports(
  p_lat      double precision,
  p_lon      double precision,
  p_radius_m double precision default 3000.0
)
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
  distance_m         double precision,
  latest_photo       text,
  width_m            double precision,
  length_m           double precision
)
language sql stable
set search_path = public
as $fn$
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
    st_distance(hr.location,
                st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography),
    (select rp.storage_path from report_photos rp
      where rp.hazard_report_id = hr.id
      order by rp.captured_at desc limit 1),
    hr.width_m,
    hr.length_m
  from hazard_reports hr
  where hr.review_state <> 'pending'
    and st_dwithin(hr.location,
                   st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography,
                   p_radius_m)
  order by st_distance(
    hr.location, st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography);
$fn$;

grant execute on function nearby_reports(double precision, double precision, double precision)
  to anon, authenticated;

drop function if exists all_reports(integer);

create function all_reports(p_limit integer default 200)
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
  width_m            double precision,
  length_m           double precision
)
language sql stable
set search_path = public
as $fn$
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
    hr.width_m,
    hr.length_m
  from hazard_reports hr
  where hr.review_state <> 'pending'
  order by hr.last_confirmed_at desc
  limit p_limit;
$fn$;

grant execute on function all_reports(integer) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Verify. submit_report should show 12 args ending in p_length_m, and both
-- read functions should list width_m / length_m.
-- ---------------------------------------------------------------------------
select p.proname,
       pg_get_function_identity_arguments(p.oid) as args,
       coalesce((select s from unnest(p.proconfig) s where s like 'search_path=%'),
                '** NOT SET **') as search_path
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('submit_report', 'nearby_reports', 'all_reports')
order by p.proname;
