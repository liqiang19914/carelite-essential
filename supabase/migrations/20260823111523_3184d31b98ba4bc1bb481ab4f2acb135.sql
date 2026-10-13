create extension if not exists pg_cron;

create table if not exists public.cron_job_config (
  job_name text primary key,
  function_url text not null,
  anon_key text not null,
  cron_secret text not null
);

insert into public.cron_job_config (job_name, function_url, anon_key, cron_secret)
values (
  'scan-follow-up-reminders',
  'https://vkmfgvlfztddylbcupxl.db.superun.com/functions/v1/scan-follow-up-reminders',
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzg2MDgzODQwLCJleHAiOjIxMDE0NDM4NDB9.JvnLyNtChX_lNu8j1KxXe2O4aart3YYKlqf-10xUotQ',
  gen_random_uuid()::text
)
on conflict (job_name) do nothing;

revoke all on table public.cron_job_config from anon, authenticated;

do $function$
begin
  perform cron.unschedule('scan-follow-up-reminders');
exception when others then
  null;
end
$function$;

-- 每天 01:00 UTC = 北京时间上午 9 点
select cron.schedule(
  'scan-follow-up-reminders',
  '0 1 * * *',
  $function$
  select net.http_post(
    url := (select function_url from public.cron_job_config where job_name = 'scan-follow-up-reminders'),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (select anon_key from public.cron_job_config where job_name = 'scan-follow-up-reminders'),
      'Authorization', 'Bearer ' || (select anon_key from public.cron_job_config where job_name = 'scan-follow-up-reminders'),
      'x-cron-secret', (select cron_secret from public.cron_job_config where job_name = 'scan-follow-up-reminders')
    ),
    body := '{}'
  );
  $function$
);