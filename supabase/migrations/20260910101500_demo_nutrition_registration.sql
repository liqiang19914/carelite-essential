-- 一次性演示账号注册验证码；注册成功后会被 manager-register 标记为 used。
DELETE FROM public.sms_verifications WHERE phone = '18800000301';
INSERT INTO public.sms_verifications (phone, code, expires_at, used, attempts)
VALUES ('18800000301', '731905', now() + interval '30 minutes', false, 0);
