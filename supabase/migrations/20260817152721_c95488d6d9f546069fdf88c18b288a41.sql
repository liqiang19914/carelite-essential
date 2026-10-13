CREATE OR REPLACE FUNCTION public._backfill_content_enterprise_roots()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_items int;
  v_pages int;
  v_spaces int;
  v_cats int;
  v_courses int;
BEGIN
  ALTER TABLE public.manager_content_items DISABLE TRIGGER manager_content_items_before_write_trg;
  ALTER TABLE public.manager_content_album_pages DISABLE TRIGGER manager_content_album_pages_before_write_trg;
  ALTER TABLE public.manager_content_album_pages DISABLE TRIGGER manager_content_album_pages_reset_moderation_trg;

  ALTER TABLE public.manager_content_album_pages
    DROP CONSTRAINT IF EXISTS manager_content_album_pages_parent_fkey;

  UPDATE public.manager_content_album_pages ap
     SET root_manager_id = e.owner_profile_id
    FROM public.profiles p
    JOIN public.enterprises e ON e.id = p.enterprise_id
   WHERE ap.root_manager_id = p.id
     AND e.owner_profile_id IS NOT NULL
     AND ap.root_manager_id IS DISTINCT FROM e.owner_profile_id;
  GET DIAGNOSTICS v_pages = ROW_COUNT;

  UPDATE public.manager_content_items i
     SET root_manager_id = e.owner_profile_id
    FROM public.profiles p
    JOIN public.enterprises e ON e.id = p.enterprise_id
   WHERE i.root_manager_id = p.id
     AND e.owner_profile_id IS NOT NULL
     AND i.root_manager_id IS DISTINCT FROM e.owner_profile_id;
  GET DIAGNOSTICS v_items = ROW_COUNT;

  ALTER TABLE public.manager_content_album_pages
    ADD CONSTRAINT manager_content_album_pages_parent_fkey
    FOREIGN KEY (content_id, root_manager_id)
    REFERENCES public.manager_content_items(id, root_manager_id) ON DELETE CASCADE;

  UPDATE public.manager_content_spaces s
     SET root_manager_id = e.owner_profile_id
    FROM public.profiles p
    JOIN public.enterprises e ON e.id = p.enterprise_id
   WHERE s.root_manager_id = p.id
     AND e.owner_profile_id IS NOT NULL
     AND s.root_manager_id IS DISTINCT FROM e.owner_profile_id;
  GET DIAGNOSTICS v_spaces = ROW_COUNT;

  UPDATE public.manager_course_categories c
     SET root_manager_id = e.owner_profile_id
    FROM public.profiles p
    JOIN public.enterprises e ON e.id = p.enterprise_id
   WHERE c.root_manager_id = p.id
     AND e.owner_profile_id IS NOT NULL
     AND c.root_manager_id IS DISTINCT FROM e.owner_profile_id;
  GET DIAGNOSTICS v_cats = ROW_COUNT;

  UPDATE public.manager_courses c
     SET manager_id = e.owner_profile_id
    FROM public.profiles p
    JOIN public.enterprises e ON e.id = p.enterprise_id
   WHERE c.manager_id = p.id
     AND e.owner_profile_id IS NOT NULL
     AND c.manager_id IS DISTINCT FROM e.owner_profile_id;
  GET DIAGNOSTICS v_courses = ROW_COUNT;

  ALTER TABLE public.manager_content_items ENABLE TRIGGER manager_content_items_before_write_trg;
  ALTER TABLE public.manager_content_album_pages ENABLE TRIGGER manager_content_album_pages_before_write_trg;
  ALTER TABLE public.manager_content_album_pages ENABLE TRIGGER manager_content_album_pages_reset_moderation_trg;

  RETURN jsonb_build_object(
    'items', v_items,
    'pages', v_pages,
    'spaces', v_spaces,
    'categories', v_cats,
    'courses', v_courses
  );
END;
$function$;