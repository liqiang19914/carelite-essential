-- 称重语音播报诊断轨迹：真机事件只进不出，仅 Edge Function（service_role）可写
create table if not exists public.scale_voice_diagnostics (
  id bigint generated always as identity primary key,
  manager_id uuid not null,
  session_id text not null check (char_length(session_id) between 1 and 128),
  event_seq integer not null check (event_seq >= 0 and event_seq <= 10000),
  event_type text not null check (event_type in (
    'session_start','session_stop','preload',
    'phrase_cache_hit','phrase_fetch_start','phrase_fetch_ok','phrase_fetch_fail',
    'weight_synth_start','weight_synth_ok','weight_synth_retry','weight_synth_fail','weight_synth_expired',
    'queue_drop','queue_full',
    'play_start','play_ended','play_error','play_guard'
  )),
  detail text check (detail is null or char_length(detail) <= 300),
  voice_module_version text check (voice_module_version is null or char_length(voice_module_version) <= 32),
  created_at timestamptz not null default now(),
  unique (session_id, event_seq)
);

create index if not exists scale_voice_diag_manager_created_idx
  on public.scale_voice_diagnostics (manager_id, created_at desc);

alter table public.scale_voice_diagnostics enable row level security;

-- 客户端与登录用户一律不开放直读直写：轨迹查询只走服务端
revoke all on table public.scale_voice_diagnostics from anon, authenticated;