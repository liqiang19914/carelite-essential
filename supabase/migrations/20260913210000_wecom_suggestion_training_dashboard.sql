-- 话术训练看板 RPC：聚合统计 + 明细分页（阶段一反馈采集/任务五）
-- 口径（商户时区切日）：
--   生成数    = error 为空的推荐批次数（1 行日志=1 批，每批最多 3 条建议）
--   复制率    = 有复制回执的批次 / 生成数
--   采纳率    = (verbatim + edited) / (verbatim + edited + rewritten)   文本已对账口径
--   大幅改写率 = rewritten / 同口径
--   复制未发率 = abandoned / 已对账的复制批次（含 non_text）
--   差评率    = down / (up + down)，按反馈行（建议槽位）计
-- 所有率分母为 0 时返回 null（前端显示「—」），不强行补 0。

-- ───────────────────────── 1. 聚合统计 ─────────────────────────

CREATE OR REPLACE FUNCTION public.get_wecom_suggestion_training_stats(
  p_days integer DEFAULT 7,
  p_actor_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_is_admin boolean;
  v_tz text;
  v_day_start timestamptz;
  v_start timestamptz;
  v_actor uuid;
  v_result jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;
  IF NOT public.wecom_pro_module_open(v_root) THEN
    RAISE EXCEPTION '企微助手 Pro 尚未开通' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('wecom_pro_archive', v_uid) THEN
    RAISE EXCEPTION '没有查看话术训练数据的权限' USING ERRCODE = '42501';
  END IF;

  v_is_admin := public.is_enterprise_admin(v_uid);
  -- FR-14：非管理员强制只看本人；管理员的 p_actor_id 必须属于本商户
  IF v_is_admin AND p_actor_id IS NOT NULL THEN
    IF COALESCE(public.get_enterprise_root_manager_id(p_actor_id), '00000000-0000-0000-0000-000000000000'::uuid) <> v_root THEN
      RAISE EXCEPTION '员工不存在' USING ERRCODE = '42501';
    END IF;
    v_actor := p_actor_id;
  ELSIF v_is_admin THEN
    v_actor := NULL;
  ELSE
    v_actor := v_uid;
  END IF;

  p_days := LEAST(GREATEST(COALESCE(p_days, 7), 1), 90);

  SELECT timezone INTO v_tz FROM public.merchant_wecom_settings
  WHERE root_manager_id = v_root;
  v_tz := COALESCE(NULLIF(btrim(COALESCE(v_tz, '')), ''), 'Asia/Shanghai');
  v_day_start := date_trunc('day', now() AT TIME ZONE v_tz) AT TIME ZONE v_tz;
  v_start := v_day_start - ((p_days - 1) * interval '1 day');

  WITH params AS (
    SELECT v_root AS root, v_actor AS actor, v_start AS start_at, now() AS end_at
  ),
    logs AS (
      SELECT l.id, l.actor_id, l.scene, l.agent_role, l.created_at,
             (l.copied_at IS NOT NULL) AS copied,
             l.outcome,
             COALESCE(NULLIF(btrim(l.agent_role), ''), 'unspecified') AS role_key,
             COALESCE(NULLIF(btrim(l.scene), ''), 'unspecified') AS scene_key,
             (to_char(l.created_at AT TIME ZONE v_tz, 'YYYY-MM-DD'))::date AS day
      FROM public.wecom_reply_suggestion_logs l, params p
      WHERE l.root_manager_id = p.root
        AND l.error IS NULL
        AND l.created_at >= p.start_at AND l.created_at <= p.end_at
        AND (p.actor IS NULL OR l.actor_id = p.actor)
    ),
    votes AS (
      SELECT f.vote, f.reason_tags, f.log_id, f.suggestion_index,
             l.day, l.actor_id,
             COALESCE(NULLIF(btrim(l.agent_role), ''), 'unspecified') AS role_key,
             COALESCE(NULLIF(btrim(l.scene), ''), 'unspecified') AS scene_key
      FROM public.wecom_suggestion_feedback f
      JOIN logs l ON l.id = f.log_id
    ),
    days AS (
      SELECT g.i,
             ((v_day_start AT TIME ZONE v_tz) - (g.i * interval '1 day'))::date AS day
      FROM generate_series(0, p_days - 1) AS g(i)
    ),
    daily_raw AS (
      SELECT day,
        count(*) AS generated,
        count(*) FILTER (WHERE copied) AS copied,
        count(*) FILTER (WHERE outcome IN ('verbatim','edited','rewritten')) AS text_reconciled,
        count(*) FILTER (WHERE outcome IN ('verbatim','edited')) AS adopted,
        count(*) FILTER (WHERE outcome = 'rewritten') AS rewritten,
        count(*) FILTER (WHERE outcome = 'abandoned') AS abandoned,
        count(*) FILTER (WHERE outcome = 'non_text') AS non_text,
        count(*) FILTER (WHERE outcome IN ('verbatim','edited','rewritten','abandoned','non_text')) AS copied_reconciled,
        (SELECT count(*) FROM votes v WHERE v.day = l.day AND v.vote = 'up') AS up_votes,
        (SELECT count(*) FROM votes v WHERE v.day = l.day AND v.vote = 'down') AS down_votes
      FROM logs l
      GROUP BY day
    ),
    daily AS (
      SELECT to_char(d.day, 'YYYY-MM-DD') AS date,
             COALESCE(r.generated, 0) AS generated,
             COALESCE(r.copied, 0) AS copied,
             CASE WHEN COALESCE(r.text_reconciled,0) > 0
                  THEN round((r.adopted::numeric / r.text_reconciled), 4) END AS adopt_rate,
             CASE WHEN COALESCE(r.up_votes,0) + COALESCE(r.down_votes,0) > 0
                  THEN round((r.down_votes::numeric / (r.up_votes + r.down_votes)), 4) END AS down_rate,
             CASE WHEN COALESCE(r.generated,0) > 0
                  THEN round((r.copied::numeric / r.generated), 4) END AS copied_rate
      FROM days d
      LEFT JOIN daily_raw r ON r.day = d.day
      ORDER BY d.day
    ),
    ov AS (
      SELECT
        count(*) AS generated,
        count(*) FILTER (WHERE copied) AS copied,
        count(*) FILTER (WHERE outcome IN ('verbatim','edited','rewritten')) AS text_reconciled,
        count(*) FILTER (WHERE outcome IN ('verbatim','edited')) AS adopted,
        count(*) FILTER (WHERE outcome = 'rewritten') AS rewritten,
        count(*) FILTER (WHERE outcome = 'abandoned') AS abandoned,
        count(*) FILTER (WHERE outcome = 'non_text') AS non_text,
        count(*) FILTER (WHERE outcome IN ('verbatim','edited','rewritten','abandoned','non_text')) AS copied_reconciled
      FROM logs
    ),
    ovv AS (
      SELECT count(*) FILTER (WHERE vote = 'up') AS up_votes,
             count(*) FILTER (WHERE vote = 'down') AS down_votes
      FROM votes
    ),
    staff AS (
      SELECT l.actor_id,
        COALESCE(NULLIF(pr.real_name,''), NULLIF(pr.nickname,''),
                 NULLIF(pr.wecom_userid,''), '未知员工') AS name,
        count(*) AS generated,
        count(*) FILTER (WHERE l.copied) AS copied,
        count(*) FILTER (WHERE l.outcome IN ('verbatim','edited')) AS adopted,
        count(*) FILTER (WHERE l.outcome = 'rewritten') AS rewritten,
        count(*) FILTER (WHERE l.outcome IN ('verbatim','edited','rewritten')) AS text_reconciled,
        count(*) FILTER (WHERE l.outcome = 'abandoned') AS abandoned,
        (SELECT count(*) FROM votes v WHERE v.actor_id = l.actor_id AND v.vote='up') AS up_votes,
        (SELECT count(*) FROM votes v WHERE v.actor_id = l.actor_id AND v.vote='down') AS down_votes
      FROM logs l
      LEFT JOIN public.profiles pr ON pr.id = l.actor_id
      GROUP BY l.actor_id, pr.real_name, pr.nickname, pr.wecom_userid
    ),
    staff_out AS (
      SELECT jsonb_build_object(
        'actorId', actor_id, 'name', name,
        'generated', generated, 'copied', copied,
        'copiedRate', CASE WHEN generated > 0 THEN round(copied::numeric/generated,4) END,
        'adoptRate', CASE WHEN text_reconciled > 0 THEN round(adopted::numeric/text_reconciled,4) END,
        'rewrittenRate', CASE WHEN text_reconciled > 0 THEN round(rewritten::numeric/text_reconciled,4) END,
        'abandoned', abandoned,
        'upVotes', up_votes, 'downVotes', down_votes,
        'downRate', CASE WHEN up_votes+down_votes > 0 THEN round(down_votes::numeric/(up_votes+down_votes),4) END
      ) AS j FROM staff
      ORDER BY generated DESC, name
    ),
    scenes AS (
      SELECT scene_key AS key, count(*) AS generated,
        count(*) FILTER (WHERE copied) AS copied,
        count(*) FILTER (WHERE outcome IN ('verbatim','edited')) AS adopted,
        count(*) FILTER (WHERE outcome IN ('verbatim','edited','rewritten')) AS text_reconciled,
        (SELECT count(*) FROM votes v WHERE v.scene_key = l.scene_key AND v.vote='up') AS up_votes,
        (SELECT count(*) FROM votes v WHERE v.scene_key = l.scene_key AND v.vote='down') AS down_votes
      FROM logs l GROUP BY scene_key
    ),
    roles AS (
      SELECT role_key AS key, count(*) AS generated,
        count(*) FILTER (WHERE copied) AS copied,
        count(*) FILTER (WHERE outcome IN ('verbatim','edited')) AS adopted,
        count(*) FILTER (WHERE outcome IN ('verbatim','edited','rewritten')) AS text_reconciled,
        (SELECT count(*) FROM votes v WHERE v.role_key = l.role_key AND v.vote='up') AS up_votes,
        (SELECT count(*) FROM votes v WHERE v.role_key = l.role_key AND v.vote='down') AS down_votes
      FROM logs l GROUP BY role_key
    ),
    dim_out AS (
      SELECT 'scenes' AS dim, jsonb_agg(jsonb_build_object(
        'key', key, 'generated', generated, 'copied', copied,
        'copiedRate', CASE WHEN generated > 0 THEN round(copied::numeric/generated,4) END,
        'adoptRate', CASE WHEN text_reconciled > 0 THEN round(adopted::numeric/text_reconciled,4) END,
        'upVotes', up_votes, 'downVotes', down_votes,
        'downRate', CASE WHEN up_votes+down_votes > 0 THEN round(down_votes::numeric/(up_votes+down_votes),4) END
      ) ORDER BY generated DESC) AS j FROM scenes
      UNION ALL
      SELECT 'roles', jsonb_agg(jsonb_build_object(
        'key', key, 'generated', generated, 'copied', copied,
        'copiedRate', CASE WHEN generated > 0 THEN round(copied::numeric/generated,4) END,
        'adoptRate', CASE WHEN text_reconciled > 0 THEN round(adopted::numeric/text_reconciled,4) END,
        'upVotes', up_votes, 'downVotes', down_votes,
        'downRate', CASE WHEN up_votes+down_votes > 0 THEN round(down_votes::numeric/(up_votes+down_votes),4) END
      ) ORDER BY generated DESC) FROM roles
    ),
    tags AS (
      SELECT t AS tag, count(*) AS n
      FROM votes, unnest(reason_tags) t
      WHERE vote = 'down'
      GROUP BY t ORDER BY n DESC, t
    )
    SELECT jsonb_build_object(
      'days', p_days,
      'actorId', v_actor,
      'scope', CASE WHEN v_actor IS NULL THEN 'enterprise' ELSE 'self' END,
      'overview', (
        SELECT jsonb_build_object(
          'generated', generated,
          'copied', copied,
          'copiedRate', CASE WHEN generated > 0 THEN round(copied::numeric/generated,4) END,
          'textReconciled', text_reconciled,
          'adopted', adopted,
          'adoptRate', CASE WHEN text_reconciled > 0 THEN round(adopted::numeric/text_reconciled,4) END,
          'rewrittenRate', CASE WHEN text_reconciled > 0 THEN round(rewritten::numeric/text_reconciled,4) END,
          'abandoned', abandoned,
          'nonText', non_text,
          'copiedReconciled', copied_reconciled,
          'abandonedRate', CASE WHEN copied_reconciled > 0 THEN round(abandoned::numeric/copied_reconciled,4) END,
          'upVotes', up_votes, 'downVotes', down_votes,
          'downRate', CASE WHEN up_votes+down_votes > 0 THEN round(down_votes::numeric/(up_votes+down_votes),4) END
        ) FROM ov, ovv
      ),
      'daily', (SELECT jsonb_agg(daily) FROM daily),
      'staff', COALESCE((SELECT jsonb_agg(j) FROM staff_out), '[]'::jsonb),
      'scenes', COALESCE((SELECT j FROM dim_out WHERE dim='scenes'), '[]'::jsonb),
      'roles', COALESCE((SELECT j FROM dim_out WHERE dim='roles'), '[]'::jsonb),
      'reasonTags', COALESCE((SELECT jsonb_agg(jsonb_build_object('tag', tag, 'count', n)) FROM tags), '[]'::jsonb)
    )
    INTO v_result;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_wecom_suggestion_training_stats(integer, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_wecom_suggestion_training_stats(integer, uuid) TO authenticated;

-- ───────────────────────── 2. 明细分页 ─────────────────────────

CREATE OR REPLACE FUNCTION public.list_wecom_suggestion_logs_for_training(
  p_days integer DEFAULT 7,
  p_actor_id uuid DEFAULT NULL,
  p_scene text DEFAULT NULL,
  p_agent_role text DEFAULT NULL,
  p_outcome text DEFAULT NULL,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_is_admin boolean;
  v_tz text;
  v_day_start timestamptz;
  v_start timestamptz;
  v_actor uuid;
  v_page int := GREATEST(COALESCE(p_page, 1), 1);
  v_size int := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);
  v_total int;
  v_items jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;
  IF NOT public.wecom_pro_module_open(v_root) THEN
    RAISE EXCEPTION '企微助手 Pro 尚未开通' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('wecom_pro_archive', v_uid) THEN
    RAISE EXCEPTION '没有查看话术训练数据的权限' USING ERRCODE = '42501';
  END IF;

  v_is_admin := public.is_enterprise_admin(v_uid);
  IF v_is_admin AND p_actor_id IS NOT NULL THEN
    IF COALESCE(public.get_enterprise_root_manager_id(p_actor_id), '00000000-0000-0000-0000-000000000000'::uuid) <> v_root THEN
      RAISE EXCEPTION '员工不存在' USING ERRCODE = '42501';
    END IF;
    v_actor := p_actor_id;
  ELSIF v_is_admin THEN
    v_actor := NULL;
  ELSE
    v_actor := v_uid;
  END IF;

  p_days := LEAST(GREATEST(COALESCE(p_days, 7), 1), 90);
  SELECT timezone INTO v_tz FROM public.merchant_wecom_settings
  WHERE root_manager_id = v_root;
  v_tz := COALESCE(NULLIF(btrim(COALESCE(v_tz, '')), ''), 'Asia/Shanghai');
  v_day_start := date_trunc('day', now() AT TIME ZONE v_tz) AT TIME ZONE v_tz;
  v_start := v_day_start - ((p_days - 1) * interval '1 day');

  -- 白名单 outcome
  IF p_outcome IS NOT NULL
     AND p_outcome NOT IN ('verbatim','edited','rewritten','abandoned','non_text','manual_self','pending') THEN
    p_outcome := NULL;
  END IF;

  WITH base AS (
    SELECT l.*,
      COALESCE(NULLIF(pr.real_name,''), NULLIF(pr.nickname,''),
               NULLIF(pr.wecom_userid,''), '未知员工') AS actor_name,
      CASE WHEN l.reconciled_at IS NULL AND l.outcome IS NULL
           THEN CASE WHEN l.copied_at IS NULL THEN 'pending' ELSE 'pending' END
           ELSE l.outcome END AS outcome_key
    FROM public.wecom_reply_suggestion_logs l
    LEFT JOIN public.profiles pr ON pr.id = l.actor_id
    WHERE l.root_manager_id = v_root
      AND l.error IS NULL
      AND l.created_at >= v_start
      AND (v_actor IS NULL OR l.actor_id = v_actor)
      AND (p_scene IS NULL OR l.scene = p_scene)
      AND (p_agent_role IS NULL OR l.agent_role = p_agent_role)
  )
  SELECT count(*) INTO v_total
  FROM base
  WHERE (p_outcome IS NULL OR outcome_key = p_outcome);

  WITH base AS (
    SELECT l.*,
      COALESCE(NULLIF(pr.real_name,''), NULLIF(pr.nickname,''),
               NULLIF(pr.wecom_userid,''), '未知员工') AS actor_name,
      CASE WHEN l.outcome IS NULL THEN 'pending' ELSE l.outcome END AS outcome_key
    FROM public.wecom_reply_suggestion_logs l
    LEFT JOIN public.profiles pr ON pr.id = l.actor_id
    WHERE l.root_manager_id = v_root
      AND l.error IS NULL
      AND l.created_at >= v_start
      AND (v_actor IS NULL OR l.actor_id = v_actor)
      AND (p_scene IS NULL OR l.scene = p_scene)
      AND (p_agent_role IS NULL OR l.agent_role = p_agent_role)
  ),
  fb AS (
    SELECT log_id, suggestion_index, vote, reason_tags, comment, actor_kind
    FROM public.wecom_suggestion_feedback
  ),
  page_rows AS (
    SELECT * FROM base
    WHERE (p_outcome IS NULL OR outcome_key = p_outcome)
    ORDER BY created_at DESC
    LIMIT v_size OFFSET (v_page - 1) * v_size
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', id,
      'createdAt', created_at,
      'actorId', actor_id,
      'actorName', actor_name,
      'scene', scene,
      'agentRole', agent_role,
      'targetName', target_name,
      'queryText', query_text,
      'copiedIndex', copied_index,
      'copiedAt', copied_at,
      'outcome', outcome_key,
      'similarity', similarity,
      'staffSentText', staff_sent_text,
      'reconciledAt', reconciled_at,
      'upCount', (SELECT count(*) FROM fb f WHERE f.log_id = page_rows.id AND f.vote='up'),
      'downCount', (SELECT count(*) FROM fb f WHERE f.log_id = page_rows.id AND f.vote='down'),
      'suggestions', (
        SELECT jsonb_agg(
          jsonb_build_object(
            'index', s.idx,
            'text', s.sugg ->> 'text',
            'score', s.sugg -> 'score',
            'best', COALESCE((s.sugg ->> 'best')::boolean, false),
            'feedback', (
              SELECT jsonb_agg(jsonb_build_object(
                'vote', f.vote, 'reasonTags', f.reason_tags,
                'comment', f.comment, 'actorKind', f.actor_kind
              ))
              FROM fb f WHERE f.log_id = page_rows.id AND f.suggestion_index = s.idx
            )
          ) ORDER BY s.idx
        )
        FROM jsonb_array_elements(page_rows.suggestions) WITH ORDINALITY AS s(sugg, idx)
      )
    )
  ) INTO v_items
  FROM page_rows;

  RETURN jsonb_build_object(
    'total', v_total,
    'page', v_page,
    'pageSize', v_size,
    'items', COALESCE(v_items, '[]'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_suggestion_logs_for_training(integer, uuid, text, text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_suggestion_logs_for_training(integer, uuid, text, text, text, integer, integer) TO authenticated;
