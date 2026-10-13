-- P1 fix: 改 FK 为 ON DELETE CASCADE，避免触发器拦截级联 UPDATE
ALTER TABLE product_image_generations
  DROP CONSTRAINT IF EXISTS product_image_generations_product_id_fkey;

ALTER TABLE product_image_generations
  ADD CONSTRAINT product_image_generations_product_id_fkey
  FOREIGN KEY (product_id)
  REFERENCES products(id)
  ON DELETE CASCADE;

-- 同时让 trigger 容错：放行 cascade SET NULL 路径（防御未来变更）
DROP TRIGGER IF EXISTS product_image_gens_lock_update_trigger ON product_image_generations;

CREATE OR REPLACE FUNCTION public.product_image_gens_lock_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.product_id IS NULL AND OLD.product_id IS NOT NULL
     AND NEW.id = OLD.id
     AND NEW.user_id = OLD.user_id
     AND NEW.source_image_url = OLD.source_image_url
     AND NEW.prompt = OLD.prompt
     AND NEW.preset_key = OLD.preset_key
     AND NEW.candidate_urls IS NOT DISTINCT FROM OLD.candidate_urls
     AND NEW.selected_url = OLD.selected_url
     AND NEW.count = OLD.count
     AND NEW.status = OLD.status
     AND NEW.model_used = OLD.model_used
     AND NEW.error_message = OLD.error_message
     AND NEW.created_at = OLD.created_at
     AND NEW.completed_at IS NOT DISTINCT FROM OLD.completed_at THEN
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
