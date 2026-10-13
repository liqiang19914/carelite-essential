-- ================================================================
-- 1.A.1 \u52a0\u56fa\uff1a\u4fee\u590d\u4e09\u4e2a\u9519\u9519\u53d1\u73b0
-- 1) \u5217\u9501\u89e6\u53d1\u5668\u6269\u5c55\u5230 INSERT\uff0c\u9632\u7ba1\u7406\u5e08\u521b\u5efa\u65f6\u9884\u586b reviewed_*/review_note
-- 2) \u9650\u5236 submitted_at \u521d\u59cb\u9884\u586b\u4e0d\u80fd\u9020\u5047 FIFO \u961f\u4f4d\u63d2\u961f
-- 3) \u9650\u5236 manager UPDATE \u72b6\u6001\u8f6c\u79fb\u77e9\u9635\uff1a\u7981\u6b62 active \u2192 draft\uff0c\u907f\u514d\u7ed5\u8fc7\u5ba1\u6838\u8c03\u6b21\u9690\u85cf\u4ea7\u54c1
-- ================================================================

CREATE OR REPLACE FUNCTION public.products_lock_review_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_now TIMESTAMPTZ := NOW();
BEGIN
  -- service_role bypass\uff08\u8fb9\u7f18\u51fd\u6570\u6216\u540e\u53f0\u811a\u672c\uff09
  IF v_uid IS NULL THEN
    RETURN NEW;
  END IF;

  -- admin \u653e\u884c\uff08\u5ba1\u6838 RPC + \u540e\u53f0\u76f4\u6539\uff09
  IF public.is_admin(v_uid) THEN
    RETURN NEW;
  END IF;

  -- ============= INSERT \u8def\u5f84 =============
  IF TG_OP = 'INSERT' THEN
    -- review_* \u5b57\u6bb5\u53ea\u80fd\u662f\u521d\u59cb\u503c\uff1aNULL / \u7a7a\u5b57\u4e32
    IF NEW.reviewed_at IS NOT NULL
       OR NEW.reviewed_by IS NOT NULL
       OR COALESCE(NEW.review_note, '') <> '' THEN
      RAISE EXCEPTION 'products: \u521b\u5efa\u65f6\u4e0d\u5141\u8bb8\u9884\u586b\u5ba1\u6838\u5b57\u6bb5';
    END IF;
    -- submitted_at \u4ec5\u5141\u8bb8\u5728 status='pending_review' \u4e14\u8d34\u8fd1\u5f53\u524d\u65f6\u95f4\uff08\u9632\u9020\u5047 FIFO\uff09
    IF NEW.submitted_at IS NOT NULL THEN
      IF NEW.status IS DISTINCT FROM 'pending_review' THEN
        RAISE EXCEPTION 'products: submitted_at \u4ec5\u5728\u63d0\u4ea4\u5ba1\u6838\u65f6\u53ef\u586b';
      END IF;
      IF NEW.submitted_at > v_now + INTERVAL '5 minutes'
         OR NEW.submitted_at < v_now - INTERVAL '5 minutes' THEN
        RAISE EXCEPTION 'products: submitted_at \u5fc5\u987b\u63a5\u8fd1\u5f53\u524d\u65f6\u95f4';
      END IF;
    END IF;
    RETURN NEW;
  END IF;

  -- ============= UPDATE \u8def\u5f84 =============
  -- \u7ba1\u7406\u5e08\u8def\u5f84\uff1a\u5ba1\u6838\u5b57\u6bb5\u53ea\u8bfb
  IF NEW.review_note IS DISTINCT FROM OLD.review_note
     OR NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at
     OR NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by THEN
    RAISE EXCEPTION 'products: review_note / reviewed_at / reviewed_by \u4e3a\u53ea\u8bfb\u5b57\u6bb5\uff0c\u4ec5\u8d85\u7ba1\u5ba1\u6838 RPC \u53ef\u5199';
  END IF;

  -- submitted_at \u4ec5\u5728\u72b6\u6001\u8f6c\u5165 pending_review \u65f6\u53ef\u5199
  IF NEW.submitted_at IS DISTINCT FROM OLD.submitted_at
     AND NOT (
       NEW.status = 'pending_review'
       AND OLD.status IS DISTINCT FROM 'pending_review'
     ) THEN
    RAISE EXCEPTION 'products: submitted_at \u4ec5\u5728\u63d0\u4ea4\u5ba1\u6838\u65f6\u53ef\u5199';
  END IF;

  -- \u72b6\u6001\u8f6c\u79fb\u77e9\u9635\uff08\u7ba1\u7406\u5e08\uff09\uff1a\u7981\u6b62 active \u76f4\u63a5\u8df3 draft \u7ed5\u8fc7\u5ba1\u6838
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF OLD.status = 'active' AND NEW.status NOT IN ('pending_review', 'archived') THEN
      RAISE EXCEPTION 'products: \u5df2\u4e0a\u67b6\u5546\u54c1\u4ec5\u53ef\u8f6c\u4e3a\u91cd\u65b0\u5ba1\u6838(pending_review)\u6216\u4e0b\u67b6(archived)';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- \u4e3a INSERT \u8df3\u8f6c\u540c\u4e00\u51fd\u6570\uff1a\u91cd\u5efa\u89e6\u53d1\u5668\u4e3a INSERT OR UPDATE
DROP TRIGGER IF EXISTS products_lock_review_fields_trigger ON products;
CREATE TRIGGER products_lock_review_fields_trigger
BEFORE INSERT OR UPDATE ON products
FOR EACH ROW
EXECUTE FUNCTION public.products_lock_review_fields();