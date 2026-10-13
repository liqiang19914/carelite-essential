-- 会话存档媒体「入库即识别」定时工作：pg_cron 每分钟 POST wecom-vision-worker。
-- 职责：消化 ingest 即时识别没跑到的图片/文件、失败重试（30 分钟退避，最多 3 次）、
--       存量 30 天内图片逐步回填。识别结果写消息 content.visionDesc，推荐话术直接读结论。

create extension if not exists pg_cron;

insert into public.cron_job_config (job_name, function_url, anon_key, cron_secret)
values (
  'wecom-vision-worker',
  'https://vkmfgvlfztddylbcupxl.db.superun.com/functions/v1/wecom-vision-worker',
  (select anon_key from public.cron_job_config where job_name = 'wecom-super-cron'),
  gen_random_uuid()::text
)
on conflict (job_name) do nothing;

do $function$
begin
  perform cron.unschedule('wecom-vision-worker');
exception when others then
  null;
end
$function$;

select cron.schedule(
  'wecom-vision-worker',
  '* * * * *',
  $function$
  select net.http_post(
    url := (select function_url from public.cron_job_config where job_name = 'wecom-vision-worker'),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (select anon_key from public.cron_job_config where job_name = 'wecom-vision-worker'),
      'Authorization', 'Bearer ' || (select anon_key from public.cron_job_config where job_name = 'wecom-vision-worker'),
      'x-cron-secret', (select cron_secret from public.cron_job_config where job_name = 'wecom-vision-worker')
    ),
    body := '{}'
  );
  $function$
);
