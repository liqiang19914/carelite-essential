-- 推荐话术对账定时任务：pg_cron 每 5 分钟 POST wecom-suggest-reconcile
-- （业务逻辑在 20260913190000 的 reconcile_wecom_suggestions 函数中）

create extension if not exists pg_cron;

insert into public.cron_job_config (job_name, function_url, anon_key, cron_secret)
values (
  'wecom-suggest-reconcile',
  'https://vkmfgvlfztddylbcupxl.db.superun.com/functions/v1/wecom-suggest-reconcile',
  (select anon_key from public.cron_job_config where job_name = 'wecom-super-cron'),
  gen_random_uuid()::text
)
on conflict (job_name) do nothing;

do $function$
begin
  perform cron.unschedule('wecom-suggest-reconcile');
exception when others then
  null;
end
$function$;

select cron.schedule(
  'wecom-suggest-reconcile',
  '*/5 * * * *',
  $function$
  select net.http_post(
    url := (select function_url from public.cron_job_config where job_name = 'wecom-suggest-reconcile'),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (select anon_key from public.cron_job_config where job_name = 'wecom-suggest-reconcile'),
      'Authorization', 'Bearer ' || (select anon_key from public.cron_job_config where job_name = 'wecom-suggest-reconcile'),
      'x-cron-secret', (select cron_secret from public.cron_job_config where job_name = 'wecom-suggest-reconcile')
    ),
    body := '{}'
  );
  $function$
);
