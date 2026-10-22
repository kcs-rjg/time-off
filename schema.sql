-- ============================================================
-- King's Time Off tool - database setup (stage 1)
-- Run this once in the Supabase SQL Editor of the London project.
-- Everything lives in its own walled-off section ("schema") called
-- timeoff, so other apps in the same project cannot see it.
-- ============================================================

create schema if not exists timeoff;
grant usage on schema timeoff to authenticated, service_role;
revoke all on schema timeoff from anon;

-- ------------------------------------------------------------
-- Tables
-- ------------------------------------------------------------

create table timeoff.staff (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete set null,
  email text not null unique check (email = lower(email)),
  full_name text not null,
  contract_type text not null check (contract_type in ('year_round','term_time_plus')),
  leave_days numeric(5,1) not null default 0,      -- annual leave entitlement (year-round staff)
  extra_hours numeric(6,1) not null default 0,     -- contracted extra hours (term time plus staff)
  day_hours numeric(4,2) not null default 7.5,     -- length of a working day, for "made up later"
  kit_from date,                                   -- set while on maternity leave: KIT days count from here
  kit_allowance numeric(4,1) not null default 10,
  is_admin boolean not null default false,
  is_sickness_logger boolean not null default false,
  away boolean not null default false,             -- approver is away: their deputy can act
  deputy_id uuid references timeoff.staff(id) on delete set null,
  active boolean not null default true,
  start_date date,                                 -- contractual start: allowances are pro rata in the year they join
  created_at timestamptz not null default now()
);

-- Who approves, line manages, or is copied in for each person
create table timeoff.links (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references timeoff.staff(id) on delete cascade,  -- the employee
  other_id uuid not null references timeoff.staff(id) on delete cascade,  -- the approver / manager / copied person
  role text not null check (role in ('approver','line_manager','copied')),
  unique (staff_id, other_id, role),
  check (staff_id <> other_id)
);

-- Term periods (half terms and INSET days count as term, so each row is a whole term)
create table timeoff.term_dates (
  id uuid primary key default gen_random_uuid(),
  label text not null,
  starts date not null,
  ends date not null,
  check (ends >= starts)
);

create table timeoff.bank_holidays (
  day date primary key,
  name text not null
);

create table timeoff.requests (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references timeoff.staff(id) on delete cascade,
  kind text not null check (kind in ('annual_leave','kit','term_off','flex')),
  start_date date not null,
  end_date date not null,
  part text not null default 'full' check (part in ('full','am','pm')),
  days numeric(5,1) not null default 0,
  hours numeric(5,1) not null default 0,
  reason text,
  status text not null default 'pending'
    check (status in ('pending','under_discussion','approved','declined','cancelled','cancel_requested')),
  treatment text check (treatment in ('unpaid','made_up','paid_special')),
  over_entitlement boolean not null default false,
  created_by uuid references timeoff.staff(id),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  check (end_date >= start_date)
);

create table timeoff.decisions (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references timeoff.requests(id) on delete cascade,
  approver_id uuid not null references timeoff.staff(id) on delete cascade,
  acted_by uuid not null references timeoff.staff(id),
  decision text not null check (decision in ('approve','decline')),
  decided_at timestamptz not null default now(),
  unique (request_id, approver_id)
);

create table timeoff.hours_entries (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references timeoff.staff(id) on delete cascade,
  work_date date not null,
  hours numeric(4,2) not null check (hours > 0 and hours <= 24),
  description text not null,
  term_day boolean not null default false,
  status text not null default 'pending' check (status in ('pending','approved','declined')),
  decided_by uuid references timeoff.staff(id),
  decided_at timestamptz,
  created_by uuid references timeoff.staff(id),
  created_at timestamptz not null default now()
);

-- Sickness: dates only, never reasons
create table timeoff.sickness (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references timeoff.staff(id) on delete cascade,
  start_date date not null,
  end_date date not null,
  part text not null default 'full' check (part in ('full','am','pm')),
  logged_by uuid not null references timeoff.staff(id),
  created_at timestamptz not null default now(),
  check (end_date >= start_date)
);

-- Carry-over and other changes to a year's allowance
create table timeoff.adjustments (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references timeoff.staff(id) on delete cascade,
  leave_year int not null,                    -- 2026 means 1st August 2026 to 31st July 2027
  kind text not null check (kind in ('leave_days','extra_hours')),
  amount numeric(6,2) not null,
  note text,
  request_id uuid references timeoff.requests(id) on delete cascade,
  created_by uuid references timeoff.staff(id),
  created_at timestamptz not null default now()
);

-- Emails waiting to be sent (stage 2 sends them)
create table timeoff.outbox (
  id uuid primary key default gen_random_uuid(),
  to_staff uuid not null references timeoff.staff(id) on delete cascade,
  subject text not null,
  body text not null,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  error text
);

create index on timeoff.requests (staff_id, start_date);
create index on timeoff.hours_entries (staff_id, work_date);
create index on timeoff.sickness (staff_id, start_date);
create index on timeoff.links (other_id);
create index on timeoff.outbox (sent_at) where sent_at is null;

-- ------------------------------------------------------------
-- Helper functions (who am I, what may I see)
-- ------------------------------------------------------------

create or replace function timeoff.me() returns uuid
language sql stable security definer set search_path = '' as $$
  select id from timeoff.staff where user_id = auth.uid() and active
$$;

create or replace function timeoff.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select is_admin from timeoff.staff where user_id = auth.uid() and active), false)
$$;

create or replace function timeoff.leave_year(d date) returns int
language sql immutable as $$
  select case when extract(month from d) >= 8 then extract(year from d)::int
              else extract(year from d)::int - 1 end
$$;

create or replace function timeoff.is_term_day(d date) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from timeoff.term_dates where d between starts and ends)
$$;

-- People who approve for an employee (falls back to administrators if none set)
create or replace function timeoff.approvers_of(p uuid) returns setof uuid
language sql stable security definer set search_path = '' as $$
  with direct as (select l.other_id from timeoff.links l join timeoff.staff s on s.id = l.other_id
                   where l.staff_id = p and l.role = 'approver' and s.active)
  select other_id from direct
  union
  select id from timeoff.staff
   where is_admin and active and id <> p and not exists (select 1 from direct)
$$;

-- Which approver (if any) the current user acts for on this employee's requests
create or replace function timeoff.acting_for(p uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select a from timeoff.approvers_of(p) a where a = timeoff.me()),
    (select s.id from timeoff.approvers_of(p) a join timeoff.staff s on s.id = a
      where s.away and s.deputy_id = timeoff.me() limit 1)
  )
$$;

create or replace function timeoff.acting_set(p uuid) returns setof uuid
language sql stable security definer set search_path = '' as $$
  select a from timeoff.approvers_of(p) a where a = timeoff.me()
  union
  select s.id from timeoff.approvers_of(p) a join timeoff.staff s on s.id = a
   where s.away and s.deputy_id = timeoff.me()
$$;

-- Admin fallback: true when nobody active is set as this person's approver
create or replace function timeoff.uses_admin_fallback(p uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select not exists (select 1 from timeoff.links l join timeoff.staff s on s.id = l.other_id
                      where l.staff_id = p and l.role = 'approver' and s.active)
$$;

create or replace function timeoff.can_view(p uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select timeoff.me() is not null and (
       p = timeoff.me()
    or timeoff.is_admin()
    or exists (select 1 from timeoff.links where staff_id = p and other_id = timeoff.me() and role in ('approver','line_manager'))
    or timeoff.acting_for(p) is not null
  )
$$;

-- Sickness is health data: only the person, their line manager(s) and administrators
create or replace function timeoff.can_view_sickness(p uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select timeoff.me() is not null and (
       p = timeoff.me()
    or timeoff.is_admin()
    or exists (select 1 from timeoff.links where staff_id = p and other_id = timeoff.me() and role = 'line_manager')
  )
$$;

-- Working days in a range (weekdays that are not bank holidays)
create or replace function timeoff.working_days(s date, e date, part text) returns numeric
language sql stable security definer set search_path = '' as $$
  select case
    when s = e and part in ('am','pm') then
      case when extract(isodow from s) < 6 and not exists (select 1 from timeoff.bank_holidays where day = s)
           then 0.5 else 0 end
    else (select count(*) from generate_series(s, e, interval '1 day') g(d)
           where extract(isodow from d) < 6
             and not exists (select 1 from timeoff.bank_holidays b where b.day = g.d::date))::numeric
  end
$$;

create or replace function timeoff.leave_booked(p uuid, yr int) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(days), 0) from timeoff.requests
   where staff_id = p and kind = 'annual_leave'
     and status in ('pending','under_discussion','approved','cancel_requested')
     and timeoff.leave_year(start_date) = yr
$$;

-- Pro rata share of a yearly figure for someone who starts part way through the year
-- (1st August to 31st July), by month as payroll pays monthly (part months by days), rounded to the nearest half
create or replace function timeoff.pro_rata(full_amount numeric, started date, yr int) returns numeric
language sql stable set search_path = '' as $$
  select case
    when started is null or started <= make_date(yr, 8, 1) then full_amount
    when started > make_date(yr + 1, 7, 31) then 0
    -- the part of the starting month still to run, plus each whole month after it, out of 12
    else round(full_amount * (
        ((date_trunc('month', started::timestamp) + interval '1 month')::date - started)::numeric
          / extract(day from date_trunc('month', started::timestamp) + interval '1 month - 1 day')::numeric
        + (select count(*) from generate_series(date_trunc('month', started::timestamp) + interval '1 month',
                                                make_date(yr + 1, 7, 1)::timestamp, interval '1 month'))
      ) / 12 * 2) / 2
  end
$$;

create or replace function timeoff.leave_allowance(p uuid, yr int) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce((select timeoff.pro_rata(leave_days, start_date, yr) from timeoff.staff where id = p), 0)
       + coalesce((select sum(amount) from timeoff.adjustments where staff_id = p and leave_year = yr and kind = 'leave_days'), 0)
$$;

create or replace function timeoff.hours_due(p uuid, yr int) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce((select timeoff.pro_rata(extra_hours, start_date, yr) from timeoff.staff where id = p), 0)
       + coalesce((select sum(amount) from timeoff.adjustments where staff_id = p and leave_year = yr and kind = 'extra_hours'), 0)
$$;

create or replace function timeoff.notify(p uuid, subj text, msg text) returns void
language sql security definer set search_path = '' as $$
  insert into timeoff.outbox (to_staff, subject, body)
  select p, subj, msg where p is not null
$$;

create or replace function timeoff.name_of(p uuid) returns text
language sql stable security definer set search_path = '' as $$
  select full_name from timeoff.staff where id = p
$$;

create or replace function timeoff.fmt_date(d date) returns text
language sql immutable as $$
  select to_char(d, 'FMDay') || ' ' || extract(day from d)::int ||
         case when extract(day from d)::int in (11,12,13) then 'th'
              when extract(day from d)::int % 10 = 1 then 'st'
              when extract(day from d)::int % 10 = 2 then 'nd'
              when extract(day from d)::int % 10 = 3 then 'rd'
              else 'th' end || ' ' || to_char(d, 'FMMonth YYYY')
$$;

create or replace function timeoff.fmt_num(n numeric) returns text
language sql immutable as $$
  select case when n = trunc(n) then trunc(n)::text else trim(trailing '0' from n::text) end
$$;

create or replace function timeoff.describe(r timeoff.requests) returns text
language sql stable as $$
  select case r.kind
           when 'annual_leave' then 'annual leave'
           when 'kit' then 'keeping in touch day'
           when 'term_off' then 'time off in term'
           else 'one-off flex' end
         || ' on ' || timeoff.fmt_date(r.start_date)
         || case when r.end_date > r.start_date then ' to ' || timeoff.fmt_date(r.end_date) else '' end
         || case when r.part = 'am' then ' (morning)' when r.part = 'pm' then ' (afternoon)' else '' end
         || case when r.kind = 'flex' then ' (' || timeoff.fmt_num(r.hours) || case when r.hours = 1 then ' hour)' else ' hours)' end
                 when r.part <> 'full' then ''
                 else ' (' || timeoff.fmt_num(r.days) || case when r.days = 1 then ' day)' else ' days)' end end
$$;

-- ------------------------------------------------------------
-- Actions the app calls (all checks happen here, on the server)
-- ------------------------------------------------------------

-- Link a signed-in user to their staff record and return who they are
create or replace function timeoff.claim_profile() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare me_id uuid; result jsonb;
begin
  update timeoff.staff s set user_id = u.id
    from auth.users u
   where u.id = auth.uid() and u.email_confirmed_at is not null
     and coalesce(u.is_anonymous, false) = false
     and s.email = lower(u.email) and s.user_id is null and s.active;
  me_id := timeoff.me();
  if me_id is null then return null; end if;
  select to_jsonb(s) || jsonb_build_object(
           'is_approver', exists (select 1 from timeoff.links where other_id = me_id and role = 'approver')
                          or exists (select 1 from timeoff.staff a where a.deputy_id = me_id and a.away)
                          or s.is_admin,
           'has_team', exists (select 1 from timeoff.links where other_id = me_id) or s.is_admin)
    into result from timeoff.staff s where s.id = me_id;
  return result;
end $$;

-- Names of colleagues, for administrators and sickness loggers
create or replace function timeoff.staff_directory() returns table (id uuid, full_name text)
language sql stable security definer set search_path = '' as $$
  select id, full_name from timeoff.staff
   where active and (timeoff.is_admin()
         or (select is_sickness_logger from timeoff.staff where id = timeoff.me()))
  order by full_name
$$;

create or replace function timeoff.submit_request(
  p_kind text, p_start date, p_end date, p_part text, p_hours numeric, p_reason text, p_for uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  me_id uuid := timeoff.me();
  who uuid;
  s timeoff.staff;
  r timeoff.requests;
  d numeric := 0;
  a uuid;
begin
  if me_id is null then raise exception 'You are not set up in the app yet.'; end if;
  who := coalesce(p_for, me_id);
  if who <> me_id and not timeoff.is_admin() then raise exception 'Only an administrator can add requests for someone else.'; end if;
  select * into s from timeoff.staff where id = who and active;
  if not found then raise exception 'Person not found.'; end if;
  if p_kind not in ('annual_leave','kit','term_off','flex') then raise exception 'Unknown request type.'; end if;
  if p_end < p_start then raise exception 'The end date is before the start date.'; end if;
  if p_end > p_start + 120 then raise exception 'Please book no more than 120 days at a time.'; end if;
  if length(coalesce(p_reason, '')) > 500 then raise exception 'Please keep the reason to 500 characters.'; end if;
  if p_part not in ('full','am','pm') then raise exception 'Unknown part of day.'; end if;
  if p_part <> 'full' and p_end <> p_start then raise exception 'Half days can only be booked one day at a time.'; end if;
  if p_kind = 'annual_leave' and s.contract_type <> 'year_round' then raise exception 'Annual leave is for year-round staff.'; end if;
  if p_kind = 'kit' and s.kit_from is null then raise exception 'KIT days are only available during maternity leave.'; end if;

  if p_kind = 'flex' then
    if p_start <> p_end then raise exception 'One-off flex is for a single day.'; end if;
    if p_hours is null or p_hours <= 0 or p_hours > 12 or p_hours * 2 <> round(p_hours * 2) then
      raise exception 'Enter the hours to the nearest half hour.';
    end if;
  elsif p_kind = 'kit' then
    -- any work on a day uses a whole KIT day
    select count(*) into d from generate_series(p_start, p_end, interval '1 day') g(x)
      where extract(isodow from x) < 6;
    if d = 0 then raise exception 'Those dates contain no working days.'; end if;
  else
    d := timeoff.working_days(p_start, p_end, p_part);
    if d = 0 then raise exception 'Those dates contain no working days.'; end if;
  end if;

  insert into timeoff.requests (staff_id, kind, start_date, end_date, part, days, hours, reason, created_by, over_entitlement)
  values (who, p_kind, p_start, p_end, p_part, d, case when p_kind = 'flex' then p_hours else 0 end,
          nullif(trim(p_reason), ''), me_id,
          case when p_kind = 'annual_leave'
               then timeoff.leave_booked(who, timeoff.leave_year(p_start)) + d > timeoff.leave_allowance(who, timeoff.leave_year(p_start))
               when p_kind = 'kit'
               then (select coalesce(sum(days),0) from timeoff.requests where staff_id = who and kind = 'kit'
                      and start_date >= s.kit_from and status in ('pending','under_discussion','approved')) + d > s.kit_allowance
               else false end)
  returning * into r;

  perform timeoff.notify(who, 'Request received: ' || timeoff.describe(r),
    'Your request for ' || timeoff.describe(r) || ' has been submitted. You will receive an email when it has been decided.');
  for a in select timeoff.approvers_of(who) loop
    perform timeoff.notify(a, 'New request from ' || s.full_name,
      s.full_name || ' has requested ' || timeoff.describe(r) || '.' ||
      case when r.over_entitlement then ' This would take them over their allowance.' else '' end ||
      ' Please open the Time Off app to approve or decline it.');
  end loop;
  return r.id;
end $$;

-- Work out a request's overall status from the approvers' decisions
create or replace function timeoff.recompute(p_id uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare
  r timeoff.requests;
  n_approvers int; n_approve int; n_decline int;
  new_status text;
  c uuid;
begin
  select * into r from timeoff.requests where id = p_id for update;
  select count(*) into n_approvers from timeoff.approvers_of(r.staff_id);
  select count(*) filter (where decision = 'approve'), count(*) filter (where decision = 'decline')
    into n_approve, n_decline
    from timeoff.decisions d where d.request_id = p_id and d.approver_id in (select timeoff.approvers_of(r.staff_id));

  if timeoff.uses_admin_fallback(r.staff_id) then
    -- no approver set: any one administrator decides
    new_status := case when n_decline > 0 then 'declined' when n_approve > 0 then 'approved' else 'pending' end;
  elsif n_decline > 0 then
    new_status := case when n_approvers > 1 then 'under_discussion' else 'declined' end;
  elsif n_approve >= n_approvers and n_approvers > 0 then
    new_status := 'approved';
  else
    new_status := 'pending';
  end if;

  if new_status = 'approved' and r.kind = 'term_off' and r.treatment is null then
    raise exception 'Choose how this time off should be treated before approving.';
  end if;

  if new_status = 'approved' and r.kind = 'annual_leave' then
    update timeoff.requests set over_entitlement =
      timeoff.leave_booked(r.staff_id, timeoff.leave_year(r.start_date)) > timeoff.leave_allowance(r.staff_id, timeoff.leave_year(r.start_date))
     where id = p_id;
  end if;

  if new_status is distinct from r.status then
    update timeoff.requests set status = new_status,
           decided_at = case when new_status in ('approved','declined') then now() else null end
     where id = p_id;
    if new_status in ('approved','declined') then
      perform timeoff.finalise(p_id, new_status);
    end if;
  end if;
  return new_status;
end $$;

-- Side effects of a final decision: emails, and extra hours for "made up later"
create or replace function timeoff.finalise(p_id uuid, final text) returns void
language plpgsql security definer set search_path = '' as $$
declare r timeoff.requests; s timeoff.staff; c uuid;
begin
  select * into r from timeoff.requests where id = p_id;
  select * into s from timeoff.staff where id = r.staff_id;
  perform timeoff.notify(r.staff_id, 'Request ' || final || ': ' || timeoff.describe(r),
    'Your request for ' || timeoff.describe(r) || ' has been ' || final || '.' ||
    case when final = 'approved' and r.kind = 'term_off' then
      case r.treatment when 'unpaid' then ' It will be recorded as unpaid.'
                       when 'made_up' then ' The hours will be added to your extra hours for the year.'
                       else ' It will be recorded as paid special leave.' end
    else '' end);
  for c in select other_id from timeoff.links where staff_id = r.staff_id and role = 'copied' loop
    perform timeoff.notify(c, 'For information: ' || s.full_name || ' - ' || final,
      s.full_name || '''s request for ' || timeoff.describe(r) || ' has been ' || final || '.');
  end loop;
end $$;

-- An approver approves or declines (or changes their earlier decision)
create or replace function timeoff.decide_request(p_id uuid, p_decision text, p_treatment text default null)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  r timeoff.requests;
  acting uuid;
  me_id uuid := timeoff.me();
  result text;
  a uuid;
begin
  if me_id is null then raise exception 'You are not set up in the app yet.'; end if;
  select * into r from timeoff.requests where id = p_id for update;
  if not found then raise exception 'Request not found.'; end if;
  if p_decision not in ('approve','decline') then raise exception 'Unknown decision.'; end if;
  if r.status = 'cancel_requested' then
    -- decision on a cancellation that affects pay
    if timeoff.acting_for(r.staff_id) is null and not timeoff.is_admin() then raise exception 'You cannot decide this request.'; end if;
    if r.staff_id = me_id and not timeoff.is_admin() then raise exception 'You cannot decide your own cancellation.'; end if;
    update timeoff.requests set status = case when p_decision = 'approve' then 'cancelled' else 'approved' end,
           decided_at = now() where id = p_id;
    perform timeoff.notify(r.staff_id, 'Cancellation ' || case when p_decision = 'approve' then 'approved' else 'declined' end,
      'Your request to cancel ' || timeoff.describe(r) || ' has been ' || case when p_decision = 'approve' then 'approved.' else 'declined, so the booking stands.' end);
    return case when p_decision = 'approve' then 'cancelled' else 'approved' end;
  end if;
  if r.status not in ('pending','under_discussion') then raise exception 'This request has already been decided.'; end if;
  if r.staff_id = me_id then raise exception 'You cannot approve your own request.'; end if;
  acting := timeoff.acting_for(r.staff_id);
  if acting is null then raise exception 'You are not an approver for this person.'; end if;

  if r.kind = 'term_off' and p_decision = 'approve' then
    if p_treatment is null or p_treatment not in ('unpaid','made_up','paid_special') then
      raise exception 'Choose how this time off should be treated.';
    end if;
    if p_treatment = 'made_up' and (select contract_type from timeoff.staff where id = r.staff_id) <> 'term_time_plus' then
      raise exception '"Made up later" only applies to term time plus staff.';
    end if;
    update timeoff.requests set treatment = p_treatment where id = p_id;
  end if;

  insert into timeoff.decisions (request_id, approver_id, acted_by, decision)
  select p_id, x, me_id, p_decision from timeoff.acting_set(r.staff_id) x
  on conflict (request_id, approver_id) do update
    set decision = excluded.decision, acted_by = excluded.acted_by, decided_at = now();

  -- tell the other approvers
  for a in select x from timeoff.approvers_of(r.staff_id) x where x not in (select timeoff.acting_set(r.staff_id)) loop
    perform timeoff.notify(a, timeoff.name_of(me_id) || ' has ' || p_decision || 'd a request',
      timeoff.name_of(me_id) || ' has ' || p_decision || 'd ' || timeoff.name_of(r.staff_id) || '''s request for ' ||
      timeoff.describe(r) || '.' ||
      case when p_decision = 'decline' then ' The request is now under discussion: please talk to them, then either they change their decision or the request is declined outright.' else '' end);
  end loop;

  result := timeoff.recompute(p_id);
  return result;
end $$;

-- After discussion, an approver declines outright
create or replace function timeoff.decline_outright(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r timeoff.requests;
begin
  select * into r from timeoff.requests where id = p_id for update;
  if not found or r.status <> 'under_discussion' then raise exception 'This request is not under discussion.'; end if;
  if timeoff.acting_for(r.staff_id) is null then raise exception 'You are not an approver for this person.'; end if;
  update timeoff.requests set status = 'declined', decided_at = now() where id = p_id;
  perform timeoff.finalise(p_id, 'declined');
end $$;

-- The employee cancels their own request
create or replace function timeoff.cancel_request(p_id uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare r timeoff.requests; a uuid; c uuid; new_status text;
begin
  select * into r from timeoff.requests where id = p_id for update;
  if not found then raise exception 'Request not found.'; end if;
  if timeoff.me() is null or (r.staff_id is distinct from timeoff.me() and not timeoff.is_admin()) then
    raise exception 'You can only cancel your own requests.';
  end if;
  if r.status = 'approved' and r.start_date <= current_date and not timeoff.is_admin() then
    raise exception 'This booking has started or passed. Please ask an administrator to change it.';
  end if;
  if r.status not in ('pending','under_discussion','approved') then raise exception 'This request cannot be cancelled.'; end if;
  -- an approved booking that affects pay needs approval to cancel
  if r.status = 'approved' and (r.over_entitlement or r.treatment = 'unpaid') and not timeoff.is_admin() then
    new_status := 'cancel_requested';
  else
    new_status := 'cancelled';
  end if;
  update timeoff.requests set status = new_status where id = p_id;
  for a in select timeoff.approvers_of(r.staff_id) loop
    perform timeoff.notify(a, timeoff.name_of(r.staff_id) || ' has ' ||
      case when new_status = 'cancelled' then 'cancelled' else 'asked to cancel' end || ' a booking',
      timeoff.name_of(r.staff_id) || ' has ' || case when new_status = 'cancelled' then 'cancelled ' else 'asked to cancel ' end ||
      timeoff.describe(r) || '.' ||
      case when new_status = 'cancel_requested' then ' This affects pay, so please approve or decline the cancellation in the app.' else '' end);
  end loop;
  for c in select other_id from timeoff.links where staff_id = r.staff_id and role = 'copied' loop
    perform timeoff.notify(c, 'For information: ' || timeoff.name_of(r.staff_id) || ' cancellation',
      timeoff.name_of(r.staff_id) || ' has cancelled ' || timeoff.describe(r) || '.');
  end loop;
  perform timeoff.notify(r.staff_id, 'Cancellation received: ' || timeoff.describe(r),
    case when new_status = 'cancelled' then 'Your booking for ' || timeoff.describe(r) || ' has been cancelled.'
         else 'Your request to cancel ' || timeoff.describe(r) || ' has been sent for approval, as it affects pay.' end);
  return new_status;
end $$;

-- An administrator sets any status directly (the employee is told)
create or replace function timeoff.admin_set_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare r timeoff.requests;
begin
  if not timeoff.is_admin() then raise exception 'Administrators only.'; end if;
  select * into r from timeoff.requests where id = p_id for update;
  if not found then raise exception 'Request not found.'; end if;
  if p_status not in ('pending','approved','declined','cancelled') then raise exception 'Unknown status.'; end if;
  if r.kind = 'term_off' and p_status = 'approved' and r.treatment is null then
    raise exception 'Set how this time off is treated first.';
  end if;
  update timeoff.requests set status = p_status,
         decided_at = case when p_status in ('approved','declined') then now() else null end where id = p_id;
  if p_status in ('approved','declined') then
    perform timeoff.finalise(p_id, p_status);
  else
    perform timeoff.notify(r.staff_id, 'Your request has been updated',
      'An administrator has changed your request for ' || timeoff.describe(r) || ' to ' || p_status || '.');
  end if;
end $$;

-- Extra hours
create or replace function timeoff.submit_hours(p_date date, p_hours numeric, p_desc text, p_for uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare me_id uuid := timeoff.me(); who uuid; s timeoff.staff; new_id uuid; a uuid;
begin
  if me_id is null then raise exception 'You are not set up in the app yet.'; end if;
  who := coalesce(p_for, me_id);
  if who <> me_id and not timeoff.is_admin() then raise exception 'Only an administrator can log hours for someone else.'; end if;
  select * into s from timeoff.staff where id = who and active;
  if s.contract_type <> 'term_time_plus' then raise exception 'Extra hours are for term time plus staff.'; end if;
  if p_hours is null or p_hours <= 0 or p_hours > 24 then raise exception 'Enter a sensible number of hours.'; end if;
  if coalesce(trim(p_desc), '') = '' then raise exception 'Say what the work was.'; end if;
  if length(p_desc) > 500 then raise exception 'Please keep the description to 500 characters.'; end if;
  insert into timeoff.hours_entries (staff_id, work_date, hours, description, term_day, created_by)
  values (who, p_date, p_hours, trim(p_desc), timeoff.is_term_day(p_date), me_id)
  returning id into new_id;
  for a in select timeoff.approvers_of(who) loop
    perform timeoff.notify(a, s.full_name || ' has logged extra hours',
      s.full_name || ' has logged ' || timeoff.fmt_num(p_hours) || ' hours on ' || timeoff.fmt_date(p_date) ||
      ' (' || trim(p_desc) || ')' || case when timeoff.is_term_day(p_date) then ', a term day.' else '.' end ||
      ' Please approve or decline it in the Time Off app.');
  end loop;
  return new_id;
end $$;

create or replace function timeoff.decide_hours(p_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare h timeoff.hours_entries;
begin
  select * into h from timeoff.hours_entries where id = p_id for update;
  if not found then raise exception 'Entry not found.'; end if;
  if timeoff.me() is null then raise exception 'You are not set up in the app yet.'; end if;
  if h.staff_id = timeoff.me() then raise exception 'You cannot approve your own hours.'; end if;
  if h.status <> 'pending' and not timeoff.is_admin() then raise exception 'These hours have already been decided.'; end if;
  if timeoff.acting_for(h.staff_id) is null and not timeoff.is_admin() then raise exception 'You are not an approver for this person.'; end if;
  update timeoff.hours_entries set status = case when p_approve then 'approved' else 'declined' end,
         decided_by = timeoff.me(), decided_at = now() where id = p_id;
  perform timeoff.notify(h.staff_id, 'Extra hours ' || case when p_approve then 'approved' else 'declined' end,
    'Your ' || timeoff.fmt_num(h.hours) || ' hours on ' || timeoff.fmt_date(h.work_date) || ' (' || h.description || ') have been ' ||
    case when p_approve then 'approved.' else 'declined. Please speak to your line manager if you have questions.' end);
end $$;

-- Sickness: staff record their own; administrators and sickness loggers can record for anyone
create or replace function timeoff.log_sickness(p_start date, p_end date, p_part text, p_for uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare me_id uuid := timeoff.me(); who uuid; new_id uuid;
begin
  if me_id is null then raise exception 'You are not set up in the app yet.'; end if;
  who := coalesce(p_for, me_id);
  if who <> me_id and not (timeoff.is_admin() or (select is_sickness_logger from timeoff.staff where id = me_id)) then
    raise exception 'You cannot record sickness for someone else.';
  end if;
  if p_end < p_start then raise exception 'The end date is before the start date.'; end if;
  if p_end > p_start + 120 then raise exception 'Please record no more than 120 days at a time.'; end if;
  if p_part not in ('full','am','pm') then raise exception 'Unknown part of day.'; end if;
  if p_part <> 'full' and p_end <> p_start then raise exception 'Half days can only be recorded one day at a time.'; end if;
  insert into timeoff.sickness (staff_id, start_date, end_date, part, logged_by)
  values (who, p_start, p_end, p_part, me_id) returning id into new_id;
  return new_id;
end $$;

-- Year-end summary for HR or Finance (administrators)
create or replace function timeoff.year_summary(yr int)
returns table (full_name text, contract_type text, start_date date, allowance numeric, used numeric,
               unpaid_days numeric, extra_hours_due numeric, extra_hours_approved numeric, extra_hours_over numeric,
               sickness_days numeric, flex_count bigint, flex_hours numeric, kit_days numeric)
language sql stable security definer set search_path = '' as $$
  with base as (
    select s.*,
      (select coalesce(sum(days),0) from timeoff.requests r where r.staff_id = s.id and r.kind = 'annual_leave'
         and r.status = 'approved' and timeoff.leave_year(r.start_date) = yr) as leave_taken,
      (select coalesce(sum(hours),0) from timeoff.hours_entries h where h.staff_id = s.id and h.status = 'approved'
         and timeoff.leave_year(h.work_date) = yr) as hours_done
    from timeoff.staff s
    where timeoff.is_admin() and s.active
  )
  select b.full_name, b.contract_type, b.start_date,
    case when b.contract_type = 'year_round' then timeoff.leave_allowance(b.id, yr) end,
    b.leave_taken,
    case when b.contract_type = 'year_round' then greatest(0, b.leave_taken - timeoff.leave_allowance(b.id, yr)) else 0 end
    + (select coalesce(sum(days),0) from timeoff.requests r where r.staff_id = b.id and r.kind = 'term_off'
          and r.status = 'approved' and r.treatment = 'unpaid' and timeoff.leave_year(r.start_date) = yr),
    case when b.contract_type = 'term_time_plus' then timeoff.hours_due(b.id, yr) end,
    b.hours_done,
    case when b.contract_type = 'term_time_plus' then greatest(0, b.hours_done - timeoff.hours_due(b.id, yr)) end,
    (select coalesce(sum(timeoff.working_days(k.start_date, k.end_date, k.part)),0) from timeoff.sickness k
       where k.staff_id = b.id and timeoff.leave_year(k.start_date) = yr),
    (select count(*) from timeoff.requests r where r.staff_id = b.id and r.kind = 'flex' and r.status = 'approved'
       and timeoff.leave_year(r.start_date) = yr),
    (select coalesce(sum(hours),0) from timeoff.requests r where r.staff_id = b.id and r.kind = 'flex' and r.status = 'approved'
       and timeoff.leave_year(r.start_date) = yr),
    (select coalesce(sum(days),0) from timeoff.requests r where r.staff_id = b.id and r.kind = 'kit' and r.status = 'approved'
       and timeoff.leave_year(r.start_date) = yr)
  from base b
  order by b.full_name
$$;

-- Keep "made up later" hours in step with the request, whichever way it changes
create or replace function timeoff.sync_made_up() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from timeoff.adjustments where request_id = new.id;
  if new.status = 'approved' and new.kind = 'term_off' and new.treatment = 'made_up' then
    insert into timeoff.adjustments (staff_id, leave_year, kind, amount, note, request_id, created_by)
    select new.staff_id, timeoff.leave_year(new.start_date), 'extra_hours', new.days * s.day_hours,
           'Made up later: ' || timeoff.describe(new), new.id, timeoff.me()
      from timeoff.staff s where s.id = new.staff_id;
  end if;
  return new;
end $$;
create trigger requests_sync_made_up after update of status, treatment, days on timeoff.requests
  for each row execute function timeoff.sync_made_up();

-- Who the signed-in user approves for (including as a deputy), worked out on the server
create or replace function timeoff.my_acting() returns table (staff_id uuid, acting_for uuid)
language sql stable security definer set search_path = '' as $$
  select s.id, timeoff.acting_for(s.id) from timeoff.staff s
   where s.active and s.id is distinct from timeoff.me() and timeoff.acting_for(s.id) is not null
$$;

-- Names of approvers and managers linked to people the user can see (eg a co-approver)
create or replace function timeoff.colleague_names() returns table (id uuid, full_name text)
language sql stable security definer set search_path = '' as $$
  select distinct s.id, s.full_name from timeoff.links l join timeoff.staff s on s.id = l.other_id
   where timeoff.can_view(l.staff_id) and l.role in ('approver','line_manager')
$$;

-- ------------------------------------------------------------
-- Security rules: every table locked by default, then opened
-- one rule at a time. Changes to requests, hours and sickness
-- only happen through the actions above.
-- ------------------------------------------------------------

alter table timeoff.staff enable row level security;
alter table timeoff.links enable row level security;
alter table timeoff.term_dates enable row level security;
alter table timeoff.bank_holidays enable row level security;
alter table timeoff.requests enable row level security;
alter table timeoff.decisions enable row level security;
alter table timeoff.hours_entries enable row level security;
alter table timeoff.sickness enable row level security;
alter table timeoff.adjustments enable row level security;
alter table timeoff.outbox enable row level security;

grant select on all tables in schema timeoff to authenticated;
grant insert, update, delete on timeoff.staff, timeoff.links, timeoff.term_dates, timeoff.bank_holidays,
  timeoff.adjustments, timeoff.hours_entries, timeoff.sickness, timeoff.requests to authenticated;
revoke all on timeoff.outbox from authenticated;

-- staff
create policy staff_read on timeoff.staff for select to authenticated using (timeoff.can_view(id));
create policy staff_admin on timeoff.staff for all to authenticated using (timeoff.is_admin()) with check (timeoff.is_admin());

-- links
create policy links_read on timeoff.links for select to authenticated
  using (timeoff.is_admin() or staff_id = timeoff.me() or other_id = timeoff.me());
create policy links_admin on timeoff.links for all to authenticated using (timeoff.is_admin()) with check (timeoff.is_admin());

-- term dates and bank holidays: everyone signed in can read; administrators edit
create policy term_read on timeoff.term_dates for select to authenticated using (timeoff.me() is not null);
create policy term_admin on timeoff.term_dates for all to authenticated using (timeoff.is_admin()) with check (timeoff.is_admin());
create policy bh_read on timeoff.bank_holidays for select to authenticated using (timeoff.me() is not null);
create policy bh_admin on timeoff.bank_holidays for all to authenticated using (timeoff.is_admin()) with check (timeoff.is_admin());

-- requests
create policy req_read on timeoff.requests for select to authenticated using (timeoff.can_view(staff_id));
create policy req_admin on timeoff.requests for all to authenticated using (timeoff.is_admin()) with check (timeoff.is_admin());

-- decisions: approvers and administrators only (staff never see individual decisions)
create policy dec_read on timeoff.decisions for select to authenticated using (
  timeoff.is_admin() or exists (select 1 from timeoff.requests r where r.id = request_id
                                 and r.staff_id <> timeoff.me() and timeoff.acting_for(r.staff_id) is not null));

-- hours
create policy hours_read on timeoff.hours_entries for select to authenticated using (timeoff.can_view(staff_id));
create policy hours_admin on timeoff.hours_entries for all to authenticated using (timeoff.is_admin()) with check (timeoff.is_admin());

-- sickness
create policy sick_read on timeoff.sickness for select to authenticated
  using (timeoff.can_view_sickness(staff_id) or logged_by = timeoff.me());
create policy sick_admin on timeoff.sickness for all to authenticated using (timeoff.is_admin()) with check (timeoff.is_admin());

-- adjustments
create policy adj_read on timeoff.adjustments for select to authenticated using (timeoff.can_view(staff_id));
create policy adj_admin on timeoff.adjustments for all to authenticated using (timeoff.is_admin()) with check (timeoff.is_admin());

-- outbox: no access from the app at all (only the email sender, in stage 2)

-- Functions: only signed-in users may call the actions
revoke execute on all functions in schema timeoff from public, anon;
grant execute on all functions in schema timeoff to authenticated;
-- internal helpers that should not be called directly from the app
revoke execute on function timeoff.notify(uuid, text, text), timeoff.finalise(uuid, text), timeoff.recompute(uuid),
  timeoff.approvers_of(uuid), timeoff.acting_set(uuid), timeoff.uses_admin_fallback(uuid), timeoff.name_of(uuid),
  timeoff.leave_booked(uuid, int), timeoff.leave_allowance(uuid, int), timeoff.hours_due(uuid, int), timeoff.pro_rata(numeric, date, int), timeoff.working_days(date, date, text),
  timeoff.is_term_day(date), timeoff.describe(timeoff.requests), timeoff.fmt_date(date), timeoff.fmt_num(numeric),
  timeoff.leave_year(date), timeoff.sync_made_up() from authenticated;
-- functions added later are not callable unless granted on purpose
alter default privileges in schema timeoff revoke execute on functions from public;

-- ------------------------------------------------------------
-- Starting data: 2026-27 term dates and bank holidays (England)
-- Check these and edit them in the app's Settings page each year.
-- ------------------------------------------------------------

insert into timeoff.term_dates (label, starts, ends) values
  ('Autumn term 2026', '2026-08-27', '2026-12-11'),
  ('Spring term 2027', '2027-01-05', '2027-03-25'),
  ('Summer term 2027', '2027-04-19', '2027-07-07');

insert into timeoff.bank_holidays (day, name) values
  ('2026-08-31', 'Summer bank holiday'),
  ('2026-12-25', 'Christmas Day'),
  ('2026-12-28', 'Boxing Day (substitute day)'),
  ('2027-01-01', 'New Year''s Day'),
  ('2027-03-26', 'Good Friday'),
  ('2027-03-29', 'Easter Monday'),
  ('2027-05-03', 'Early May bank holiday'),
  ('2027-05-31', 'Spring bank holiday'),
  ('2027-08-30', 'Summer bank holiday');

-- ------------------------------------------------------------
-- Finally: add yourself as the first administrator.
-- Replace the email and name below before running.
-- ------------------------------------------------------------
insert into timeoff.staff (email, full_name, contract_type, is_admin)
values ('rjg@kcs.org.uk', 'Rob Gorrie', 'year_round', true);
