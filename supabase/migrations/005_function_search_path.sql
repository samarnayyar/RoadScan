-- ============================================================================
-- Migration 005 -- pin search_path on every RoadScan function
--
-- Run this in the Supabase SQL Editor. Safe to re-run.
--
-- Closes the "Function Search Path Mutable" advisor findings on:
--   current_confidence, derived_status, nearby_reports, report_timeline,
--   device_reports, all_reports, review_queue, review_decide
--
-- (confirm_report and submit_report already pin it; they are included anyway
-- so the guarantee is uniform and a future edit cannot quietly drop it.)
--
-- Why it matters
-- --------------
-- A function without `SET search_path` resolves unqualified names using
-- whatever search_path the CALLER happens to have. An attacker who can create
-- objects in a schema that sits earlier in that path can therefore decide
-- which `hazard_reports` or which `st_dwithin` the function body actually
-- calls.
--
-- For a SECURITY DEFINER function that is a privilege-escalation route: the
-- hijacked call runs as the function's owner, not as the caller. submit_report
-- and confirm_report are both SECURITY DEFINER and both granted to anon, so
-- they are the ones that would matter most -- and they were already pinned.
--
-- The rest are SECURITY INVOKER, where the blast radius is smaller: a hijacked
-- call runs as anon and RLS still applies. It is still worth closing. These
-- functions are the app's only read path, so redirecting one of them to an
-- attacker-controlled table would let someone feed the map arbitrary pins
-- without ever touching the real data.
--
-- Written as a loop over pg_proc rather than a list of ALTER statements,
-- because each ALTER needs the exact argument list and those have already
-- changed twice in this project's life -- submit_report gained p_captured_at
-- in 002 and p_review_note in 004. Looking the signatures up at run time
-- cannot drift out of date the way a hand-written list does.
-- ============================================================================

do $$
declare
  r record;
  n integer := 0;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public'
      and p.proname in (
        'current_confidence', 'derived_status', 'nearby_reports',
        'report_timeline', 'device_reports', 'all_reports',
        'confirm_report', 'submit_report', 'review_queue', 'review_decide'
      )
  loop
    execute format('alter function %s set search_path = public', r.sig);
    raise notice 'pinned search_path on %', r.sig;
    n := n + 1;
  end loop;

  if n = 0 then
    raise notice 'no matching functions found -- has schema.sql been run?';
  else
    raise notice '% function(s) pinned', n;
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Verify. Every row should show a search_path setting; a null means the
-- advisor will still flag that function.
-- ---------------------------------------------------------------------------
select
  p.proname                                   as function_name,
  pg_get_function_identity_arguments(p.oid)   as args,
  p.prosecdef                                 as security_definer,
  coalesce(
    (select s from unnest(p.proconfig) s where s like 'search_path=%'),
    '** NOT SET **'
  )                                           as search_path
from pg_proc p
join pg_namespace ns on ns.oid = p.pronamespace
where ns.nspname = 'public'
  and p.proname in (
    'current_confidence', 'derived_status', 'nearby_reports',
    'report_timeline', 'device_reports', 'all_reports',
    'confirm_report', 'submit_report', 'review_queue', 'review_decide'
  )
order by p.proname;
