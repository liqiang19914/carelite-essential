-- 企微外部联系人定时全量同步：pg_cron 每日北京凌晨3点 POST wecom-cron-sync-contacts
-- 定位：兜底对账（非主同步）。主同步靠企微回调实时增量；每日一次全量校验去重，对齐 SCRM 行业惯例。

create extension if not exists pg_cron;

insert into public.cron_job_config (job_name, function_url, anon_key, cron_secret)
values (
  'wecom-cron-sync-contacts',
  'https://vkmfgvlfztddylbcupxl.db.superun.com/functions/v1/wecom-cron-sync-contacts',
  (select anon_key from public.cron_job_config where job_name = 'wecom-super-cron'),
  gen_random_uuid()::text
)
on conflict (job_name) do nothing;

do $function$
begin
  perform cron.unschedule('wecom-cron-sync-contacts');
exception when others then
  null;
end
$function$;

select cron.schedule(
  'wecom-cron-sync-contacts',
  '0 19 * * *',  -- 19:00 UTC = 次日 03:00 北京时间
  $function$
  select net.http_post(
    url := (select function_url from public.cron_job_config where job_name = 'wecom-cron-sync-contacts'),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (select anon_key from public.cron_job_config where job_name = 'wecom-cron-sync-contacts'),
      'Authorization', 'Bearer ' || (select anon_key from public.cron_job_config where job_name = 'wecom-cron-sync-contacts'),
      'x-cron-secret', (select cron_secret from public.cron_job_config where job_name = 'wecom-cron-sync-contacts')
    ),
    body := '{}'
  );
  $function$
);
