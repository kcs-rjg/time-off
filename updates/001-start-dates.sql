-- ============================================================
-- Update 1: contractual start dates and pro rata allowances
-- Run once in the Supabase SQL Editor (the database already exists).
-- ============================================================

alter table timeoff.staff add column if not exists start_date date;

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

drop function if exists timeoff.year_summary(int);
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

revoke execute on function timeoff.pro_rata(numeric, date, int), timeoff.hours_due(uuid, int),
  timeoff.leave_allowance(uuid, int) from public, anon, authenticated;
grant execute on function timeoff.year_summary(int) to authenticated;
