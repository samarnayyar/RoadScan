-- Admin delete, for clearing test reports off the map.
--
-- Why this is gated by a token
-- ---------------------------
-- Every other write in this app goes through a security-definer function that
-- can only ever ADD to the record: submit a report, confirm one, vote it
-- fixed. Nothing the client can call destroys data, which is what makes it
-- safe to ship a publishable key in the repository.
--
-- A delete breaks that. The publishable key is public by design -- it is in
-- supabase.json -- so an ungated delete function would let anyone who reads
-- this repository empty the hazard table. The token is what keeps the
-- capability with the person holding it rather than with the key.
--
-- The token is stored hashed, so a reader of this table (there should be
-- none, but still) does not learn the value.

create table if not exists admin_secrets (
  id          int primary key default 1,
  token_hash  text not null,
  created_at  timestamptz not null default now(),
  constraint admin_secrets_singleton check (id = 1)
);

alter table admin_secrets enable row level security;

-- No policies at all: RLS with zero policies denies every client read and
-- write. Only security-definer functions, which bypass RLS, can see it.
revoke all on admin_secrets from anon, authenticated;

-- Set your token. Run this ONCE with a value of your choosing, then pass the
-- same value to the app as --dart-define=ADMIN_TOKEN=...
--
--   insert into admin_secrets (id, token_hash)
--   values (1, encode(digest('your-secret-here', 'sha256'), 'hex'))
--   on conflict (id) do update set token_hash = excluded.token_hash;
--
-- pgcrypto provides digest(); it ships enabled on Supabase.
create extension if not exists pgcrypto with schema extensions;

create or replace function admin_delete_report(
  p_report_id uuid,
  p_token     text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_ok   boolean;
begin
  select token_hash into v_hash from admin_secrets where id = 1;

  -- No token configured means the capability is simply off, rather than open.
  if v_hash is null then
    raise exception 'admin delete is not configured';
  end if;

  v_ok := (v_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex'));
  if not v_ok then
    raise exception 'not authorised';
  end if;

  -- report_photos and confirmations cascade from the FK definitions in
  -- schema.sql, so this is the only row that has to go. The photo objects in
  -- storage are left alone deliberately: they are cheap, and an orphaned
  -- image is recoverable where a deleted one is not.
  delete from hazard_reports where id = p_report_id;
  return found;
end;
$$;

-- CREATE FUNCTION grants EXECUTE to PUBLIC automatically, which is exactly
-- what we do not want by default. Revoke, then grant back deliberately -- the
-- token check inside is the real gate, but there is no reason to leave the
-- function reachable by roles that have no business calling it.
revoke all on function admin_delete_report(uuid, text) from public;
grant execute on function admin_delete_report(uuid, text) to anon, authenticated;
