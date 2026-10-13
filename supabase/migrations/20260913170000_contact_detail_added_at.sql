-- 客户库「添加时间」口径统一：详情 RPC 也改用 COALESCE(wecom_added_at, first_seen_at)
-- （列表 RPC 已在 20260911193000 改过，本迁移基于线上现网函数体仅改该一行）

CREATE OR REPLACE FUNCTION public.get_wecom_pro_contact_detail(p_external_userid text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_is_admin boolean;
  v_my_userid text;
  v_contact public.merchant_wecom_contacts;
  v_profile jsonb;
  v_health_records jsonb;
  v_timeline jsonb;
  v_tags jsonb;
  v_follow_staff jsonb;
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
  IF NOT public.has_enterprise_permission('wecom_pro_customers', v_uid) THEN
    RAISE EXCEPTION '没有访问客户库的权限' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_contact
  FROM public.merchant_wecom_contacts
  WHERE root_manager_id = v_root AND external_userid = btrim(COALESCE(p_external_userid, ''));
  IF v_contact.id IS NULL THEN
    RAISE EXCEPTION '客户不存在或无权查看' USING ERRCODE = '42501';
  END IF;

  v_is_admin := public.is_enterprise_admin(v_uid);
  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_my_userid FROM public.profiles WHERE id = v_uid;
    IF COALESCE(btrim(COALESCE(v_my_userid, '')), '') = ''
       OR NOT (
         v_contact.follow_userids @> ARRAY[btrim(v_my_userid)]
         OR v_contact.lost_userid = btrim(v_my_userid)
       ) THEN
      RAISE EXCEPTION '客户不存在或无权查看' USING ERRCODE = '42501';
    END IF;
  END IF;

  v_follow_staff := COALESCE(
    (SELECT jsonb_agg(jsonb_build_object('wecomUserid', s.wecom_userid, 'nickname', s.nickname) ORDER BY s.nickname)
     FROM public.profiles s
     WHERE s.wecom_userid = ANY (v_contact.follow_userids)),
    '[]'::jsonb
  );

  v_tags := COALESCE(
    (SELECT jsonb_agg(jsonb_build_object('tagId', t.tag_id, 'tagName', t.tag_name, 'groupId', t.group_id) ORDER BY t.sort_order, t.tag_id)
     FROM public.merchant_wecom_contact_tags ct
     JOIN public.merchant_wecom_tags t
       ON t.root_manager_id = ct.root_manager_id AND t.tag_id = ct.tag_id
     WHERE ct.root_manager_id = v_root
       AND ct.external_userid = v_contact.external_userid),
    '[]'::jsonb
  );

  IF v_contact.profile_id IS NOT NULL THEN
    v_profile := (
      SELECT jsonb_build_object(
        'id', pr.id,
        'nickname', pr.nickname,
        'phone', pr.phone,
        'healthManagerNickname', hm.nickname,
        'latestWeighing', (
          SELECT jsonb_build_object('measuredAt', bc.measured_at, 'weight', bc.weight, 'bmi', bc.bmi)
          FROM public.body_compositions bc
          JOIN public.health_records hr ON hr.id = bc.record_id
          WHERE hr.user_id = pr.id
          ORDER BY bc.measured_at DESC
          LIMIT 1
        )
      )
      FROM public.profiles pr
      LEFT JOIN LATERAL (
        SELECT p2.nickname
        FROM public.client_relations cr
        JOIN public.profiles p2 ON p2.id = cr.manager_id
        WHERE cr.client_id = pr.id AND cr.status = 'active'
        ORDER BY cr.created_at DESC
        LIMIT 1
      ) hm ON true
      WHERE pr.id = v_contact.profile_id
    );
  ELSE
    v_profile := NULL;
  END IF;

  IF v_contact.profile_id IS NOT NULL THEN
    v_health_records := (
      SELECT COALESCE(jsonb_agg(sub.item ORDER BY sub.is_default DESC, sub.created_at DESC), '[]'::jsonb)
      FROM (
        SELECT hr.is_default AS is_default,
               hr.created_at AS created_at,
               jsonb_build_object(
                 'id', hr.id,
                 'name', hr.name,
                 'relationship', hr.relationship,
                 'isDefault', hr.is_default,
                 'gender', hr.gender,
                 'birthDate', hr.birth_date,
                 'height', hr.height,
                 'weight', hr.weight,
                 'bloodType', hr.blood_type,
                 'medicalHistory', hr.medical_history,
                 'allergyHistory', hr.allergy_history,
                 'surgeryHistory', hr.surgery_history,
                 'medicationHistory', hr.medication_history,
                 'latestComposition', (
                   SELECT jsonb_build_object(
                            'measuredAt', bc.measured_at,
                            'weight', bc.weight,
                            'bmi', bc.bmi,
                            'bodyFatPercent', bc.body_fat_percent,
                            'visceralFatLevel', bc.visceral_fat_level,
                            'skeletalMusclePercent', bc.skeletal_muscle_percent,
                            'healthScore', bc.health_score)
                   FROM public.body_compositions bc
                   WHERE bc.record_id = hr.id
                   ORDER BY bc.measured_at DESC
                   LIMIT 1
                 )
               ) AS item
        FROM public.health_records hr
        WHERE hr.user_id = v_contact.profile_id
      ) sub
    );
  ELSE
    v_health_records := '[]'::jsonb;
  END IF;

  v_timeline := COALESCE(
    (SELECT jsonb_agg(sub.item ORDER BY (sub.item->>'eventTime') ASC, sub.item->>'type' ASC)
     FROM (
       SELECT jsonb_build_object(
          'type', CASE ev.payload->>'ChangeType'
                    WHEN 'add_external_contact' THEN 'add_friend'
                    WHEN 'del_external_contact' THEN 'lost'
                    ELSE (ev.payload->>'ChangeType')
                  END,
          'operator', COALESCE(
            (SELECT s.nickname FROM public.profiles s
             WHERE s.wecom_userid = COALESCE(ev.payload->>'UserID', ev.payload->>'FromUserID')
               AND COALESCE(s.parent_manager_id, s.id) = v_root
             LIMIT 1),
            COALESCE(ev.payload->>'UserID', ev.payload->>'FromUserID')
          ),
          'state', ev.payload->>'State',
          'tagName', NULL,
          'eventTime', CASE
            WHEN ev.wecom_create_time IS NOT NULL THEN to_timestamp(ev.wecom_create_time)
            ELSE ev.created_at
          END
        ) AS item
        FROM public.merchant_wecom_events ev
        WHERE ev.root_manager_id = v_root
          AND ev.event_type = 'change_external_contact'
          AND ev.payload->>'ExternalUserID' = v_contact.external_userid
          AND ev.payload->>'ChangeType' IN ('add_external_contact', 'del_external_contact')
       UNION ALL
       SELECT jsonb_build_object(
          'type', 'tag_added',
          'operator', NULL,
          'state', NULL,
          'tagName', t.tag_name,
          'eventTime', ct.created_at
        ) AS item
        FROM public.merchant_wecom_contact_tags ct
        JOIN public.merchant_wecom_tags t
          ON t.root_manager_id = ct.root_manager_id AND t.tag_id = ct.tag_id
        WHERE ct.root_manager_id = v_root
          AND ct.external_userid = v_contact.external_userid
     ) sub),
    '[]'::jsonb
  );

  RETURN jsonb_build_object(
    'contact', jsonb_build_object(
      'id', v_contact.id,
      'externalUserid', v_contact.external_userid,
      'type', v_contact.type,
      'name', COALESCE(v_contact.name, v_contact.external_userid),
      'avatarUrl', v_contact.avatar_url,
      'unionid', v_contact.unionid,
      'followUserids', to_jsonb(v_contact.follow_userids),
      'profileId', v_contact.profile_id,
      'sourceState', v_contact.source_state,
      'firstSeenAt', COALESCE(v_contact.wecom_added_at, v_contact.first_seen_at),
      'lastMessageAt', v_contact.last_message_at,
      'lostAt', v_contact.lost_at,
      'lostUserid', v_contact.lost_userid,
      'followStaff', v_follow_staff,
      'tags', v_tags
    ),
    'profile', v_profile,
    'healthRecords', v_health_records,
    'timeline', v_timeline
  );
END;
$function$


NOTIFY pgrst, 'reload schema';
