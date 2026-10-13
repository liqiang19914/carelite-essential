-- \u52a0\u56fa\uff1aINSERT \u8def\u5f84\u4e0a\u8ba9 submitted_at \u7531\u670d\u52a1\u7aef\u5f3a\u5236\u5199 NOW()\uff0c\u6d88\u9664\u5ba2\u6237\u7aef\u65f6\u949f\u504f\u79fb\u5e72\u6270\u3001\u5e76\u4ece\u6839\u672c\u4e0a\u6760\u4f4f FIFO \u961f\u4f4d
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
    -- review_* \u5b57\u6bb5\u5fc5\u987b\u4fdd\u6301\u521d\u59cb\u503c
    IF NEW.reviewed_at IS NOT NULL
       OR NEW.reviewed_by IS NOT NULL
       OR COALESCE(NEW.review_note, '') <> '' THEN
      RAISE EXCEPTION 'products: \u521b\u5efa\u65f6\u4e0d\u5141\u8bb8\u9884\u586b\u5ba1\u6838\u5b57\u6bb5';
    END IF;
    -- submitted_at \u7531\u670d\u52a1\u7aef\u5f3a\u5236\u5199\uff1a\u907f\u514d\u5ba2\u6237\u7aef\u504f\u79fb\u6216\u4f2a\u9020 FIFO
    IF NEW.status = 'pending_review' THEN
      NEW.submitted_at := v_now;
    ELSE
      IF NEW.submitted_at IS NOT NULL THEN
        RAISE EXCEPTION 'products: submitted_at \u4ec5\u5728\u63d0\u4ea4\u5ba1\u6838\u65f6\u53ef\u586b';
      END IF;
    END IF;
    RETURN NEW;
  END IF;

  -- ============= UPDATE \u8def\u5f84 =============
  -- \u5ba1\u6838\u5b57\u6bb5\u53ea\u8bfb
  IF NEW.review_note IS DISTINCT FROM OLD.review_note
     OR NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at
     OR NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by THEN
    RAISE EXCEPTION 'products: review_note / reviewed_at / reviewed_by \u4e3a\u53ea\u8bfb\u5b57\u6bb5\uff0c\u4ec5\u8d85\u7ba1\u5ba1\u6838 RPC \u53ef\u5199';
  END IF;

  -- submitted_at \u4ec5\u5728\u72b6\u6001\u8f6c\u5165 pending_review \u65f6\u53ef\u5199\uff1b\u540c\u65f6\u5f3a\u5236 NOW()
  IF NEW.status = 'pending_review' AND OLD.status IS DISTINCT FROM 'pending_review' THEN
    NEW.submitted_at := v_now;
  ELSIF NEW.submitted_at IS DISTINCT FROM OLD.submitted_at THEN
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