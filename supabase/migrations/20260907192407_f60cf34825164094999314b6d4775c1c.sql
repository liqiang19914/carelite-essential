-- feature 457: 内容/课程短码自动生成（BEFORE INSERT 触发器）
-- 模式照搬 managers_set_short_code（20260624195034）；共享 base36 生成器，表内 EXISTS 重试

CREATE OR REPLACE FUNCTION public.generate_short_code_6()
RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = ''
AS $function$
DECLARE
  alphabet text := 'abcdefghijklmnopqrstuvwxyz0123456789';
  result text;
  i int;
BEGIN
  result := '';
  FOR i IN 1..6 LOOP
    result := result || substr(alphabet, 1 + floor(random() * 36)::int, 1);
  END LOOP;
  RETURN result;
END;
$function$;

-- manager_content_items
CREATE OR REPLACE FUNCTION public.manager_content_items_set_short_code()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
DECLARE
  attempts int := 0;
BEGIN
  IF NEW.short_code IS NULL OR NEW.short_code = '' THEN
    LOOP
      attempts := attempts + 1;
      IF attempts > 10 THEN
        RAISE EXCEPTION 'content short_code generation exceeded 10 attempts';
      END IF;
      NEW.short_code := public.generate_short_code_6();
      EXIT WHEN NOT EXISTS (
        SELECT 1 FROM public.manager_content_items WHERE short_code = NEW.short_code
      );
    END LOOP;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS manager_content_items_set_short_code_before_insert ON public.manager_content_items;
CREATE TRIGGER manager_content_items_set_short_code_before_insert
  BEFORE INSERT ON public.manager_content_items
  FOR EACH ROW
  EXECUTE FUNCTION public.manager_content_items_set_short_code();

-- enterprise_courses
CREATE OR REPLACE FUNCTION public.enterprise_courses_set_short_code()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
DECLARE
  attempts int := 0;
BEGIN
  IF NEW.short_code IS NULL OR NEW.short_code = '' THEN
    LOOP
      attempts := attempts + 1;
      IF attempts > 10 THEN
        RAISE EXCEPTION 'course short_code generation exceeded 10 attempts';
      END IF;
      NEW.short_code := public.generate_short_code_6();
      EXIT WHEN NOT EXISTS (
        SELECT 1 FROM public.enterprise_courses WHERE short_code = NEW.short_code
      );
    END LOOP;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS enterprise_courses_set_short_code_before_insert ON public.enterprise_courses;
CREATE TRIGGER enterprise_courses_set_short_code_before_insert
  BEFORE INSERT ON public.enterprise_courses
  FOR EACH ROW
  EXECUTE FUNCTION public.enterprise_courses_set_short_code();

-- manager_courses
CREATE OR REPLACE FUNCTION public.manager_courses_set_short_code()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
DECLARE
  attempts int := 0;
BEGIN
  IF NEW.short_code IS NULL OR NEW.short_code = '' THEN
    LOOP
      attempts := attempts + 1;
      IF attempts > 10 THEN
        RAISE EXCEPTION 'manager course short_code generation exceeded 10 attempts';
      END IF;
      NEW.short_code := public.generate_short_code_6();
      EXIT WHEN NOT EXISTS (
        SELECT 1 FROM public.manager_courses WHERE short_code = NEW.short_code
      );
    END LOOP;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS manager_courses_set_short_code_before_insert ON public.manager_courses;
CREATE TRIGGER manager_courses_set_short_code_before_insert
  BEFORE INSERT ON public.manager_courses
  FOR EACH ROW
  EXECUTE FUNCTION public.manager_courses_set_short_code();