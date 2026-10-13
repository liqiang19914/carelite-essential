alter table public.manager_content_spaces
  add column if not exists reputation_name text;

create or replace function public.get_my_content_space()
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_root uuid;
  v_name text;
  v_rep_name text;
begin
  if v_uid is null then
    raise exception '请先登录后再管理内容' using errcode = '28000';
  end if;

  if not public.is_active_enterprise_content_member(v_uid) then
    raise exception '所属企业当前不可使用内容管理，请联系企业负责人或平台处理'
      using errcode = '42501';
  end if;

  v_root := public.get_enterprise_root_manager_id(v_uid);

  select nullif(btrim(display_name), ''),
         nullif(btrim(reputation_name), '')
    into v_name, v_rep_name
  from public.manager_content_spaces
  where root_manager_id = v_root;

  return jsonb_build_object(
    'root_manager_id', v_root,
    'display_name', coalesce(v_name, '健康学堂'),
    'is_custom_name', v_name is not null,
    'reputation_name', coalesce(v_rep_name, '达人口碑'),
    'is_custom_reputation_name', v_rep_name is not null
  );
end;
$function$;

create or replace function public.save_reputation_section_name(
  p_name text,
  p_root_manager_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_root uuid;
  v_name text := nullif(btrim(p_name), '');
begin
  if v_uid is null then
    raise exception '请先登录后再保存' using errcode = '28000';
  end if;

  if char_length(coalesce(v_name, '')) > 30 then
    raise exception '用户发布板块名称最多 30 个字，请精简后重试' using errcode = '22023';
  end if;

  if public.is_admin(v_uid) then
    v_root := p_root_manager_id;
    if v_root is null
       or not exists (select 1 from public.managers where id = v_root) then
      raise exception '请选择有效企业' using errcode = '22023';
    end if;
  else
    if not public.is_active_enterprise_content_member(v_uid) then
      raise exception '所属企业当前不可修改板块名称，请联系企业负责人或平台处理'
        using errcode = '42501';
    end if;
    v_root := public.get_enterprise_root_manager_id(v_uid);
  end if;

  insert into public.manager_content_spaces (
    root_manager_id, reputation_name, created_by, updated_by
  )
  values (v_root, v_name, v_uid, v_uid)
  on conflict (root_manager_id) do update
    set reputation_name = excluded.reputation_name,
        updated_by = v_uid,
        updated_at = now();

  return jsonb_build_object(
    'root_manager_id', v_root,
    'reputation_name', coalesce(v_name, '达人口碑'),
    'is_custom_reputation_name', v_name is not null
  );
end;
$function$;

create or replace function public.get_public_reputation_module(p_manager_id uuid, p_cat uuid DEFAULT NULL::uuid, p_search text DEFAULT NULL::text, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_total integer;
  v_categories jsonb;
  v_posts jsonb;
  v_section_name text;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
  v_offset integer := LEAST(GREATEST(COALESCE(p_offset, 0), 0), 10000);
  v_search text := NULLIF(btrim(COALESCE(p_search, '')), '');
BEGIN
  v_root := public.get_enterprise_root_manager_id(p_manager_id);
  IF v_root IS NULL OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RETURN NULL;
  END IF;

  select coalesce(nullif(btrim(s.reputation_name), ''), '达人口碑')
    into v_section_name
  from public.manager_content_spaces s
  where s.root_manager_id = v_root;

  SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.sort_weight, c.name), '[]'::jsonb)
    INTO v_categories
  FROM (
    SELECT id, name, sort_weight
    FROM public.reputation_categories
    WHERE root_manager_id = v_root
  ) c;

  SELECT COUNT(*) INTO v_total
  FROM public.reputation_posts p
  WHERE p.root_manager_id = v_root
    AND p.moderation_status = 'passed'
    AND (p_cat IS NULL OR p.category_id = p_cat)
    AND (v_search IS NULL OR p.title ILIKE '%' || v_search || '%' OR p.content ILIKE '%' || v_search || '%');

  SELECT COALESCE(
    jsonb_agg(
      to_jsonb(item)
      ORDER BY item.is_pinned DESC, item.pinned_rank DESC, item.created_at DESC, item.id
    ),
    '[]'::jsonb
  )
    INTO v_posts
  FROM (
    SELECT
      p.id,
      p.category_id,
      p.title,
      p.content,
      COALESCE(p.like_count, 0) + COALESCE(p.base_like_count, 0) AS like_count,
      p.comment_count,
      p.created_at,
      p.post_type,
      p.cover_layout,
      p.video_url,
      p.video_cover_url,
      p.video_duration_seconds,
      COALESCE(p.is_pinned, false) AS is_pinned,
      COALESCE(p.pinned_rank, 0) AS pinned_rank,
      COALESCE(p.view_count, 0) + COALESCE(p.base_view_count, 0) AS view_count,
      EXISTS (
        SELECT 1 FROM public.reputation_likes l
        WHERE l.post_id = p.id AND l.user_id = auth.uid()
      ) AS my_liked,
      COALESCE(NULLIF(btrim(p.author_display_name), ''), pr.nickname) AS author_name,
      pr.avatar_url AS author_avatar_url,
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('image_url', i.image_url, 'is_before', i.is_before) ORDER BY i.sort_order)
        FROM public.reputation_post_images i
        WHERE i.post_id = p.id
      ), '[]'::jsonb) AS images
    FROM public.reputation_posts p
    LEFT JOIN public.profiles pr ON pr.id = p.author_user_id
    WHERE p.root_manager_id = v_root
      AND p.moderation_status = 'passed'
      AND (p_cat IS NULL OR p.category_id = p_cat)
      AND (v_search IS NULL OR p.title ILIKE '%' || v_search || '%' OR p.content ILIKE '%' || v_search || '%')
    ORDER BY
      COALESCE(p.is_pinned, false) DESC,
      COALESCE(p.pinned_rank, 0) DESC,
      p.created_at DESC,
      p.id
    LIMIT v_limit OFFSET v_offset
  ) item;

  RETURN jsonb_build_object(
    'root_manager_id', v_root,
    'section_name', v_section_name,
    'categories', v_categories,
    'total', v_total,
    'posts', v_posts
  );
END;
$function$;