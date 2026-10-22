# Time Off tool: context for Claude

A staff time-off web app for Rob Gorrie (Deputy Head, Futures & Communities, King's College School, Wimbledon) and his team. It was designed and built (stage 1) in a Claude Cowork session in October 2026. This file carries over the decisions made there.

## Working with Rob

- Rob is not a developer. Explain technical points in plain English, one notch less technical than you would by default (eg explain "schema", "RLS" or "edge function" if you mention them).
- He checks numbers closely and will flag mistakes.
- Copy inside the app follows King's house style: British English, no contractions, no em dashes, "eg"/"ie" without full stops, dates as "Monday 21st December", times as "9.00am", numbers one to nine in words in prose.
- Ask before guessing at HR policy (pay, entitlements, carry-over). HR Director: Saima Ali. Bursar: Dave Navarro.

## Stack

- `index.html`: a single-file app (vanilla JS, no build step) hosted on GitHub Pages. It uses supabase-js 2.45.4 from jsdelivr with an integrity hash; if you change the version, recompute the hash.
- `schema.sql`: the database setup, run once in the Supabase SQL Editor. Everything lives in the `timeoff` schema, which must be listed under Data API "Exposed schemas".
- Supabase project: **kings-apps**, London region, Pro plan, URL `https://zpwerwzekpbnulhgjkvt.supabase.co`. The publishable key is in index.html; it is safe to be public. Never put a secret or service_role key in the repo.
- One Supabase project holds several of Rob's apps, each in its own schema. The seating plan app (currently in an older EU project) will be moved into a `seating` schema later.
- `SETUP.md` is Rob's setup guide.

## How it works

- **Contract types.** Year-round staff (eg Claudia, Gina) request annual leave in days, with half days allowed, from an allowance that resets on 1st August. Term time plus staff (eg Charlie, Isla, possibly Beverley) log extra hours worked outside contractual hours against a yearly total, which also resets on 1st August.
- **Term dates.** Each term row covers the whole term, because half terms and INSET days count as term. Hours can also be logged on term days (eg evening events); these are labelled "Term day" for the approver to check.
- **Bank holidays** are on top of leave and are not counted.
- **Pro rata.** `staff.start_date` (contractual start) makes the joining year's leave days and extra hours pro rata, because payroll assumes hours are worked evenly through the year. The share is the rest of the starting month (by days) plus each whole month to July, out of 12, rounded to the nearest half (`timeoff.pro_rata`, mirrored by `proRata` in index.html). Approved hours beyond the pro rata total count as overtime and appear in the year-end summary. The rounding and monthly basis are an assumption still to confirm with Finance or HR.
- **Database changes** to a live database go in `updates/NNN-*.sql`, which Rob runs once in the SQL Editor; `schema.sql` is kept as the full fresh install.
- **Request types:**
  - annual_leave;
  - kit: keeping in touch days during maternity leave, 10 by default, where any work on a day uses a whole KIT day;
  - term_off: an exceptional day off in term, where the approver picks unpaid, made up later or paid special leave ("made up later" is term time plus only and adds day_hours per day to that year's hours target);
  - flex: "one-off flex", a single day with hours away to the nearest half hour, approve or decline only, always shown on the team calendar, with the person's flex history this year shown to the approver.
- **Sickness** is recorded with dates only, never reasons, and needs no approval. Only the person, their line managers and admins can see it, plus a sickness logger (Gina) for rows she logged herself.
- **Approvals.** Each person has their own approvers, all of whom must approve, in any order. Staff only ever see Pending, Approved or Declined. If one approver declines, the request becomes "under_discussion" (approvers only). The decliner can then change to approve, or any approver can "decline outright". A deputy acts when an approver is marked away. If a person has no active approver, any one administrator decides.
- **Cancelling.** Staff can cancel without approval, unless the booking affects pay (over allowance or unpaid), in which case it needs approval. Bookings that have started can only be changed by an admin.
- **Roles.** Staff see their own records. Approvers and line managers see their people. People "copied in" receive emails only and get no data access. Admins see and edit everything.
- **Data changes** go through SECURITY DEFINER functions (submit_request, decide_request, decline_outright, cancel_request, admin_set_status, submit_hours, decide_hours, log_sickness). Direct table writes are admin-only via RLS. Functions use `search_path = ''`, and internal helpers are revoked from `authenticated`.
- **Emails** are queued in `timeoff.outbox` (no app access) but are **not yet sent**.

## Testing

Stage 1 was tested against a local Postgres 16 with stubbed Supabase roles and `auth.uid()`, covering approval flows, deputies, sickness visibility and attack cases, plus a Playwright smoke test of every screen with mocked data. An independent review's findings were fixed. Please keep testing changes to the security rules this way.

## Still to do (stage 2 onwards)

1. **Email sending.** Rob is buying a new domain for now (perhaps moving later to timeoff@kcs.org.uk or a KingsFutures domain). Set up Resend (or similar) with DNS records, configure Supabase Auth custom SMTP so sign-in links reach all staff, and add an edge function plus a schedule to send the outbox. HTML-escape user text in emails.
2. **Monthly pace email** on the 1st of each month: matter-of-fact, non-alarmist wording, based on projected year-end position including bookings, to both the person and their line manager, with a reminder to book known hours or holidays early.
3. **Outlook calendar subscription** via a private ICS feed, with no IT admin approval needed. Stage 1 has a manual .ics download.
4. Move the seating plan app into this project.
5. Open questions:
   - check KIT-day rules with Saima;
   - confirm whether Beverley is term time plus;
   - the "under_discussion" status is visible in raw API data to the employee (the UI shows Pending); accepted for now.
