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

  IF EXISTS (SELECT 1 FROM public.managers m WHERE m.id = NEW.id AND m.is_system_default) THEN
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