-- P2-3: bump_product_view 仅允许 authenticated（撤销 anon），加可见性兜底
REVOKE EXECUTE ON FUNCTION public.bump_product_view(UUID) FROM anon;

CREATE OR REPLACE FUNCTION public.bump_product_view(p_product_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_product_id IS NULL OR auth.uid() IS NULL THEN RETURN; END IF;
  IF NOT public.can_view_product(p_product_id, auth.uid()) THEN
    RETURN;
  END IF;
  UPDATE products SET view_count = view_count + 1 WHERE id = p_product_id;
END;
$$;

-- P2-4: product_image_generations 限制 UPDATE 仅能改 selected_url
CREATE OR REPLACE FUNCTION public.product_image_gens_lock_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- service_role 走 bypass，触发器只在 client (authenticated) 上下文执行（auth.uid() IS NOT NULL）
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
    OR NEW.product_id IS DISTINCT FROM OLD.product_id
    OR NEW.user_id IS DISTINCT FROM OLD.user_id
    OR NEW.source_image_url IS DISTINCT FROM OLD.source_image_url
    OR NEW.prompt IS DISTINCT FROM OLD.prompt
    OR NEW.preset_key IS DISTINCT FROM OLD.preset_key
    OR NEW.candidate_urls IS DISTINCT FROM OLD.candidate_urls
    OR NEW.count IS DISTINCT FROM OLD.count
    OR NEW.status IS DISTINCT FROM OLD.status
    OR NEW.model_used IS DISTINCT FROM OLD.model_used
    OR NEW.error_message IS DISTINCT FROM OLD.error_message
    OR NEW.created_at IS DISTINCT FROM OLD.created_at
    OR NEW.completed_at IS DISTINCT FROM OLD.completed_at THEN
    RAISE EXCEPTION 'product_image_generations: only selected_url is mutable by client';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER product_image_gens_lock_update_trigger
BEFORE UPDATE ON product_image_generations
FOR EACH ROW
EXECUTE FUNCTION public.product_image_gens_lock_update();
