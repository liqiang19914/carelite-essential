UPDATE public.managers
SET
  membership_level = 'basic',
  membership_enforcement_mode = 'enforced',
  membership_updated_at = now(),
  membership_note = '平台一次性纠正：存量不限量商户改为基础版，并开启真实限额'
WHERE membership_enforcement_mode = 'legacy_unlimited';