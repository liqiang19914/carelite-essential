-- 企微推荐话术 AI 训练 · 阶段一（反馈采集）
-- 1) 员工显式反馈表（👍/👎 + 差评原因）
-- 2) 话术日志增加「复制后实际发送」对账字段
-- 3) 中文文本归一化 + pg_trgm 相似度工具函数
-- 4) 反馈提交 RPC（SECURITY DEFINER，桌面端 JWT 通道）
-- 5) 发送回放对账批处理函数（由 wecom-suggest-reconcile EF 每 5 分钟以 service_role 调用）

create extension if not exists pg_trgm;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. 显式反馈表
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.wecom_suggestion_feedback (
  id uuid primary key default gen_random_uuid(),
  root_manager_id uuid not null,
  log_id uuid not null references public.wecom_reply_suggestion_logs(id) on delete cascade,
  suggestion_index int not null check (suggestion_index between 0 and 2),
  vote text not null check (vote in ('up', 'down')),
  reason_tags text[] not null default '{}',
  comment text,
  actor_id uuid,
  actor_kind text not null default 'manager' check (actor_kind in ('manager', 'staff')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint wecom_suggestion_feedback_uniq unique (
    root_manager_id, log_id, suggestion_index, actor_id
  )
);

create index if not exists idx_wecom_suggestion_feedback_root
  on public.wecom_suggestion_feedback (root_manager_id, created_at desc);
create index if not exists idx_wecom_suggestion_feedback_log
  on public.wecom_suggestion_feedback (log_id);

-- 表不向 anon/authenticated 开放直读直写，全部经 SECURITY DEFINER RPC（service_role 绕过 RLS）
alter table public.wecom_suggestion_feedback enable row level security;
revoke all on public.wecom_suggestion_feedback from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. 话术日志对账字段
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.wecom_reply_suggestion_logs
  add column if not exists outcome text
    check (outcome in ('verbatim', 'edited', 'rewritten', 'abandoned', 'manual_self', 'non_text')),
  add column if not exists similarity numeric(4,3),
  add column if not exists staff_sent_text text,
  add column if not exists staff_sent_at timestamptz,
  add column if not exists reconciled_at timestamptz,
  add column if not exists reconcile_note text,
  add column if not exists reconcile_attempts int not null default 0;

-- 已复制待对账热路径
create index if not exists idx_wecom_suggest_logs_reconcile_copied
  on public.wecom_reply_suggestion_logs (root_manager_id, copied_at)
  where reconciled_at is null and copied_at is not null;
-- 未复制、可能「未采纳自写」的近 48 小时日志
create index if not exists idx_wecom_suggest_logs_reconcile_nocopy
  on public.wecom_reply_suggestion_logs (root_manager_id, created_at)
  where reconciled_at is null and copied_at is null;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. 文本归一化 + 相似度（immutable，可用于查询内比对）
--    全角转半角（U+FF01..FF5E → U+0021..007E，偏移 0xFEE0；U+3000 → 空格），
--    小写后只保留中文/字母/数字（标点、emoji、空白全部丢弃）。
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.wecom_normalize_text(t text)
returns text
language plpgsql
immutable
as $$
declare
  ch text;
  cp int;
  out text := '';
begin
  if t is null then return ''; end if;
  foreach ch in array regexp_split_to_array(t, '')
  loop
    cp := ascii(ch);
    if cp between 65281 and 65374 then
      cp := cp - 65248;
      ch := chr(cp);
    elsif cp = 12288 then
      ch := ' ';
    end if;
    out := out || ch;
  end loop;
  return regexp_replace(lower(out), '[^0-9a-z\u4e00-\u9fff]+', '', 'g');
end;
$$;

create or replace function public.wecom_text_similarity(a text, b text)
returns numeric(4,3)
language sql
immutable
as $$
  select case
    when coalesce(length(public.wecom_normalize_text(a)), 0) = 0
      or coalesce(length(public.wecom_normalize_text(b)), 0) = 0
      then 0::numeric(4,3)
    else round(public.similarity(public.wecom_normalize_text(a), public.wecom_normalize_text(b))::numeric, 3)
  end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. 反馈提交 RPC（桌面 JWT 通道；H5 走 wecom-sidebar EF，service_role 同口径写库）
--    p_cancel=true：撤销投票；down→up 自动清空原因标签与说明。
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.submit_wecom_suggestion_feedback(
  p_log_id uuid,
  p_index int,
  p_vote text default null,
  p_reason_tags text[] default null,
  p_comment text default null,
  p_cancel boolean default false
)
returns json
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_root uuid;
  v_tags text[] := '{}';
  v_allowed text[] := array[
    'off_topic', 'fabrication', 'compliance_risk', 'robotic',
    'unhelpful', 'style_mismatch', 'other'
  ];
begin
  if v_uid is null then return json_build_object('error', '未登录'); end if;
  if p_log_id is null or p_index is null or p_index not between 0 and 2 then
    return json_build_object('error', '参数错误');
  end if;

  v_root := public.get_enterprise_root_manager_id(v_uid);

  -- 日志必须属于本商户
  if not exists (
    select 1 from public.wecom_reply_suggestion_logs
    where id = p_log_id and root_manager_id = v_root
  ) then
    return json_build_object('error', '记录不存在');
  end if;

  if p_cancel then
    delete from public.wecom_suggestion_feedback
    where root_manager_id = v_root and log_id = p_log_id
      and suggestion_index = p_index and actor_id = v_uid;
    return json_build_object('success', true, 'cancelled', true);
  end if;

  if p_vote is null or p_vote not in ('up', 'down') then
    return json_build_object('error', '投票类型错误');
  end if;

  -- 标签白名单过滤；赞不携带原因
  if p_vote = 'down' and p_reason_tags is not null then
    select coalesce(array_agg(distinct tag), '{}') into v_tags
    from unnest(p_reason_tags) as tag
    where tag = any(v_allowed);
  end if;

  insert into public.wecom_suggestion_feedback
    (root_manager_id, log_id, suggestion_index, vote, reason_tags, comment, actor_id, actor_kind)
  values (
    v_root, p_log_id, p_index, p_vote, v_tags,
    case when p_vote = 'down' then left(nullif(p_comment, ''), 100) else null end,
    v_uid, 'manager'
  )
  on conflict on constraint wecom_suggestion_feedback_uniq
  do update set
    vote = excluded.vote,
    reason_tags = excluded.reason_tags,
    comment = excluded.comment,
    updated_at = now();

  return json_build_object('success', true);
end;
$$;

revoke all on function public.submit_wecom_suggestion_feedback(uuid, int, text, text[], text, boolean) from public;
grant execute on function public.submit_wecom_suggestion_feedback(uuid, int, text, text[], text, boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. 发送回放对账批处理（service_role / definer 调用，EF 做 cron 鉴权）
--    返回各类 outcome 计数。幂等：只处理 reconciled_at is null 的日志。
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.reconcile_wecom_suggestions(p_limit int default 50)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  l record;
  v_staff text;
  v_needle text;
  v_since_ms bigint;
  v_until_ms bigint;
  v_sent record;
  v_has_nontext boolean;
  v_outcome text;
  v_sim numeric(4,3);
  v_attempts int;
  stats jsonb := '{}'::jsonb;
  n int := 0;
begin
  -- ── 第一批：已复制、12 分钟前仍未对账 ─────────────────────────────
  for l in
    select *
    from public.wecom_reply_suggestion_logs
    where reconciled_at is null
      and copied_at is not null
      and copied_at < now() - interval '12 minutes'
    order by copied_at
    limit greatest(least(coalesce(p_limit, 50), 100), 1)
  loop
    begin
      v_attempts := coalesce(l.reconcile_attempts, 0) + 1;

      select wecom_userid into v_staff
      from public.profiles
      where id = l.actor_id;

      v_needle := nullif(l.suggestions #>> array[coalesce(l.copied_index, 0)::text, 'text'], '');

      if v_staff is null or v_staff = '' or v_needle is null then
        update public.wecom_reply_suggestion_logs
        set reconcile_attempts = v_attempts,
            reconcile_note = '缺少员工企微 userid 映射或建议文本',
            reconciled_at = case when v_attempts >= 3 then now() else reconciled_at end
        where id = l.id;
        continue;
      end if;

      v_since_ms := (extract(epoch from l.copied_at) * 1000)::bigint;
      v_until_ms := v_since_ms + 600000; -- 复制后 10 分钟窗口

      -- 窗口内最相似的一条文本发送
      select into v_sent
        m.content ->> 'content' as txt,
        m.msgtime as msgtime,
        public.wecom_text_similarity(v_needle, m.content ->> 'content') as sim
      from public.merchant_wecom_archive_messages m
      where m.root_manager_id = l.root_manager_id
        and m.roomid = l.roomid
        and m.from_userid = v_staff
        and m.action = 'send'
        and m.msg_type = 'text'
        and m.msgtime between v_since_ms and v_until_ms
        and nullif(m.content ->> 'content', '') is not null
      order by public.wecom_text_similarity(v_needle, m.content ->> 'content') desc
      limit 1;

      if found then
        v_sim := v_sent.sim;
        if v_sim >= 0.85 then v_outcome := 'verbatim';
        elsif v_sim >= 0.50 then v_outcome := 'edited';
        else v_outcome := 'rewritten';
        end if;
        update public.wecom_reply_suggestion_logs set
          outcome = v_outcome,
          similarity = v_sim,
          staff_sent_text = left(v_sent.txt, 1000),
          staff_sent_at = to_timestamp(v_sent.msgtime / 1000.0),
          reconciled_at = now(),
          reconcile_note = null,
          reconcile_attempts = v_attempts
        where id = l.id and reconciled_at is null;
      else
        -- 窗口内是否有任意非文本发送（图片/语音/文件/表情等）
        select exists (
          select 1 from public.merchant_wecom_archive_messages m
          where m.root_manager_id = l.root_manager_id
            and m.roomid = l.roomid
            and m.from_userid = v_staff
            and m.action = 'send'
            and m.msgtime between v_since_ms and v_until_ms
        ) into v_has_nontext;

        if v_has_nontext then
          v_outcome := 'non_text';
          update public.wecom_reply_suggestion_logs set
            outcome = 'non_text',
            reconciled_at = now(),
            reconcile_note = null,
            reconcile_attempts = v_attempts
          where id = l.id and reconciled_at is null;
        else
          v_outcome := 'abandoned';
          update public.wecom_reply_suggestion_logs set
            outcome = 'abandoned',
            reconciled_at = now(),
            reconcile_note = null,
            reconcile_attempts = v_attempts
          where id = l.id and reconciled_at is null;
        end if;
      end if;

      n := n + 1;
      stats := jsonb_set(stats, array[v_outcome],
        to_jsonb(coalesce((stats ->> v_outcome)::int, 0) + 1), true);
    exception when others then
      -- 单条失败不阻断整批；3 次后落库停试
      update public.wecom_reply_suggestion_logs
      set reconcile_attempts = v_attempts,
          reconcile_note = left(sqlerrm, 200),
          reconciled_at = case when v_attempts >= 3 then now() else reconciled_at end
      where id = l.id;
    end;
  end loop;

  -- ── 第二批：未复制但员工 30 分钟内自行回复 → 未采纳自写（仅扫近 48h） ──
  for l in
    select *
    from public.wecom_reply_suggestion_logs
    where reconciled_at is null
      and copied_at is null
      and error is null
      and created_at between now() - interval '48 hours' and now() - interval '30 minutes'
    order by created_at desc
    limit greatest(least(coalesce(p_limit, 50), 100), 1)
  loop
    begin
      select wecom_userid into v_staff from public.profiles where id = l.actor_id;
      if v_staff is null or v_staff = '' then continue; end if;

      v_since_ms := (extract(epoch from l.created_at) * 1000)::bigint;
      v_until_ms := v_since_ms + 1800000; -- 生成后 30 分钟窗口

      select into v_sent
        m.content ->> 'content' as txt,
        m.msgtime as msgtime
      from public.merchant_wecom_archive_messages m
      where m.root_manager_id = l.root_manager_id
        and m.roomid = l.roomid
        and m.from_userid = v_staff
        and m.action = 'send'
        and m.msg_type = 'text'
        and m.msgtime between v_since_ms and v_until_ms
        and nullif(m.content ->> 'content', '') is not null
      order by m.msgtime
      limit 1;

      if found then
        update public.wecom_reply_suggestion_logs set
          outcome = 'manual_self',
          staff_sent_text = left(v_sent.txt, 1000),
          staff_sent_at = to_timestamp(v_sent.msgtime / 1000.0),
          reconciled_at = now()
        where id = l.id and reconciled_at is null;

        n := n + 1;
        stats := jsonb_set(stats, '{manual_self}',
          to_jsonb(coalesce((stats ->> 'manual_self')::int, 0) + 1), true);
      end if;
      -- 员工确实没回：保持未对账（避免误判），48h 后自然离开扫描窗口
    exception when others then
      update public.wecom_reply_suggestion_logs
      set reconcile_note = left(sqlerrm, 200)
      where id = l.id;
    end;
  end loop;

  return jsonb_build_object('processed', n, 'outcomes', stats);
end;
$$;

revoke all on function public.reconcile_wecom_suggestions(int) from public, anon, authenticated;
grant execute on function public.reconcile_wecom_suggestions(int) to service_role;

notify pgrst, 'reload schema';
