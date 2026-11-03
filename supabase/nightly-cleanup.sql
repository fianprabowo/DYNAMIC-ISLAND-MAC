-- Optional: empties the pokes table every night at 23:59 Jakarta time (WIB, UTC+7).
-- Run once in the Supabase dashboard's SQL Editor, after poke.sql. Running it again is safe.
--
-- pg_cron runs in UTC, so 23:59 WIB is 16:59 UTC. For another time zone, change the schedule.
-- TRUNCATE keeps the id counter going (it doesn't restart identity): the app catches up on pokes
-- by id, so ids must keep growing.

create extension if not exists pg_cron with schema pg_catalog;

select cron.unschedule(jobid) from cron.job where jobname = 'truncate-pokes-nightly';
select cron.schedule('truncate-pokes-nightly', '59 16 * * *', $$truncate table public.pokes$$);

-- To check it ran:   select * from cron.job_run_details order by start_time desc limit 5;
-- To stop it:        select cron.unschedule('truncate-pokes-nightly');
