do $function$
begin
  perform cron.unschedule('purge-scale-voice-diagnostics');
exception when others then
  null;
end
$function$;

-- 每天 04:00 UTC（北京时间中午 12 点）清理 30 天前的诊断记录
select cron.schedule(
  'purge-scale-voice-diagnostics',
  '0 4 * * *',
  $function$
  delete from public.scale_voice_diagnostics
  where created_at < now() - interval '30 days';
  $function$
);