-- ============================================================
-- 客户数上限触发器（企业聚合，锁 root manager 行防并发绕过）
-- ============================================================

CREATE OR REPLACE FUNCTION public.enforce_membership_client_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root_id uuid;
  v_root public.managers;
  v_plan public.membership_plans;
  v_effective_limit integer;
  v_current_count integer;
  v_was_active boolean := false;
BEGIN
  IF NEW.status <> 'active' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    v_was_active := (OLD.status = 'active');
    IF v_was_active THEN
      RETURN NEW;
    END IF;
  END IF;

  v_root_id := public.get_membership_root_manager_id(NEW.manager_id);
  IF v_root_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT m.* INTO v_root FROM public.managers m WHERE m.id = v_root_id FOR UPDATE;
  IF NOT FOUND OR v_root.membership_enforcement_mode = 'legacy_unlimited' THEN
    RETURN NEW;
  END IF;

  SELECT p.* INTO v_plan FROM public.membership_plans p WHERE p.code = v_root.membership_level;
  IF NOT FOUND OR NOT v_plan.hard_enforce_numeric_limits THEN
    RETURN NEW;
  END IF;

  v_effective_limit := COALESCE(v_root.client_limit_override, v_plan.client_limit);

  SELECT COUNT(DISTINCT cr.client_id) INTO v_current_count
  FROM public.client_relations cr
  WHERE cr.status = 'active'
    AND cr.id <> NEW.id
    AND (cr.manager_id = v_root_id OR cr.manager_id IN (
      SELECT emp.id FROM public.profiles emp WHERE emp.parent_manager_id = v_root_id
    ));

  IF v_current_count + 1 > v_effective_limit THEN
    RAISE EXCEPTION '当前套餐客户数已达上限（%人），请联系平台升级套餐或扩容', v_effective_limit
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_enforce_membership_client_limit ON public.client_relations;
CREATE TRIGGER trg_enforce_membership_client_limit
  BEFORE INSERT OR UPDATE OF manager_id, client_id, status ON public.client_relations
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_membership_client_limit();

-- ============================================================
-- 坐席数上限触发器（boss + 未禁用员工）
-- ============================================================

CREATE OR REPLACE FUNCTION public.enforce_membership_seat_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_will_be_active_seat boolean;
  v_was_active_seat boolean := false;
  v_root_id uuid;
  v_root public.managers;
  v_plan public.membership_plans;
  v_effective_limit integer;
  v_current_count integer;
BEGIN
  v_will_be_active_seat := (NEW.role = 'manager' AND NEW.parent_manager_id IS NOT NULL AND NEW.is_disabled = false);

  IF NOT v_will_be_active_seat THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    v_was_active_seat := (OLD.role = 'manager' AND OLD.parent_manager_id IS NOT NULL AND OLD.is_disabled = false);
    IF v_was_active_seat THEN
      RETURN NEW;
    END IF;
  END IF;

  v_root_id := NEW.parent_manager_id;

  SELECT m.* INTO v_root FROM public.managers m WHERE m.id = v_root_id FOR UPDATE;
  IF NOT FOUND OR v_root.membership_enforcement_mode = 'legacy_unlimited' THEN
    RETURN NEW;
  END IF;

  SELECT p.* INTO v_plan FROM public.membership_plans p WHERE p.code = v_root.membership_level;
  IF NOT FOUND OR NOT v_plan.hard_enforce_numeric_limits THEN
    RETURN NEW;
  END IF;

  v_effective_limit := COALESCE(v_root.seat_limit_override, v_plan.manager_seat_limit);

  SELECT COUNT(*) INTO v_current_count
  FROM public.profiles emp
  WHERE emp.id <> NEW.id
    AND (emp.id = v_root_id OR (emp.parent_manager_id = v_root_id AND emp.is_disabled = false AND emp.role = 'manager'));

  IF v_current_count + 1 > v_effective_limit THEN
    RAISE EXCEPTION '当前套餐健康管理师坐席已达上限（%人），请联系平台升级套餐', v_effective_limit
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_enforce_membership_seat_limit ON public.profiles;
CREATE TRIGGER trg_enforce_membership_seat_limit
  BEFORE INSERT OR UPDATE OF role, parent_manager_id, is_disabled ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_membership_seat_limit();

-- ============================================================
-- 知识库文档数上限触发器（按每位管理师个人计）
-- ============================================================

CREATE OR REPLACE FUNCTION public.enforce_membership_knowledge_doc_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root_id uuid;
  v_root public.managers;
  v_plan public.membership_plans;
  v_effective_limit integer;
  v_current_count integer;
BEGIN
  IF NEW.source <> 'user_upload' THEN
    RETURN NEW;
  END IF;

  v_root_id := public.get_membership_root_manager_id(NEW.manager_id);
  IF v_root_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT m.* INTO v_root FROM public.managers m WHERE m.id = v_root_id;
  IF NOT FOUND OR v_root.membership_enforcement_mode = 'legacy_unlimited' THEN
    RETURN NEW;
  END IF;

  SELECT p.* INTO v_plan FROM public.membership_plans p WHERE p.code = v_root.membership_level;
  IF NOT FOUND OR NOT v_plan.hard_enforce_numeric_limits THEN
    RETURN NEW;
  END IF;

  v_effective_limit := v_plan.knowledge_doc_limit_per_manager;

  SELECT COUNT(*) INTO v_current_count
  FROM public.manager_knowledge_documents d
  WHERE d.manager_id = NEW.manager_id
    AND d.source = 'user_upload';

  IF v_current_count + 1 > v_effective_limit THEN
    RAISE EXCEPTION '知识库文档数量已达套餐上限（%篇/人），请联系平台升级套餐', v_effective_limit
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_enforce_membership_knowledge_doc_limit ON public.manager_knowledge_documents;
CREATE TRIGGER trg_enforce_membership_knowledge_doc_limit
  BEFORE INSERT ON public.manager_knowledge_documents
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_membership_knowledge_doc_limit();

-- ============================================================
-- managers 套餐字段防篡改触发器（仅平台管理员可改，其余静默还原）
-- ============================================================

CREATE OR REPLACE FUNCTION public.prevent_managers_membership_tampering()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF auth.uid() IS NULL OR public.is_admin(auth.uid()) THEN
    RETURN NEW;
  END IF;

  IF NEW.membership_level IS DISTINCT FROM OLD.membership_level
     OR NEW.membership_enforcement_mode IS DISTINCT FROM OLD.membership_enforcement_mode
     OR NEW.seat_limit_override IS DISTINCT FROM OLD.seat_limit_override
     OR NEW.client_limit_override IS DISTINCT FROM OLD.client_limit_override THEN
    NEW.membership_level := OLD.membership_level;
    NEW.membership_enforcement_mode := OLD.membership_enforcement_mode;
    NEW.seat_limit_override := OLD.seat_limit_override;
    NEW.client_limit_override := OLD.client_limit_override;
    NEW.membership_updated_at := OLD.membership_updated_at;
    NEW.membership_updated_by := OLD.membership_updated_by;
    NEW.membership_note := OLD.membership_note;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_prevent_managers_membership_tampering ON public.managers;
CREATE TRIGGER trg_prevent_managers_membership_tampering
  BEFORE UPDATE ON public.managers
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_managers_membership_tampering();
