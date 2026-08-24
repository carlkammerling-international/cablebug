-- Move all writes behind the Edge Function.
--
-- After this, the anon key that ships inside the web build can read the
-- leaderboard and do nothing else. It cannot insert, update or delete in any
-- table. Every write arrives through score-api, which validates a signed,
-- single-use session token and then writes with the service_role key.

-- 1. Tokens are spent here. Primary key on (sid, action) makes a replay a
--    duplicate-key error rather than a race.
create table if not exists public.used_sessions (
  sid     uuid        not null,
  action  text        not null,
  used_at timestamptz not null default now(),
  primary key (sid, action)
);

-- RLS on with NO policies: unreachable by anon, and service_role bypasses RLS.
alter table public.used_sessions enable row level security;

-- Housekeeping: spent tokens are only interesting until they expire.
create index if not exists used_sessions_used_at_idx on public.used_sessions (used_at);

-- 2. Take write access away from the browser. Read stays, so the leaderboard
--    still renders straight from PostgREST.
drop policy if exists "public insert scores"  on public.scores;
drop policy if exists "public insert entries" on public.contest_entries;

-- 3. Belt and braces at the schema level, in case a policy is ever re-added by
--    accident. These match the checks in the function.
alter table public.scores
  drop constraint if exists scores_plausible;
alter table public.scores
  add constraint scores_plausible check (
    score >= 0
    and boards between 0 and 20
    and score <= (boards + 1) * 17000
  );

alter table public.contest_entries
  drop constraint if exists contest_entries_plausible;
alter table public.contest_entries
  add constraint contest_entries_plausible check (
    score >= 0
    and boards between 0 and 20
    and score <= (boards + 1) * 17000
  );

-- 4. Confirm the result: scores should list SELECT only, contest_entries none.
-- select tablename, policyname, cmd from pg_policies
--  where schemaname = 'public' and tablename in ('scores','contest_entries');
