INSERT INTO products (
  source_type, owner_manager_id, title, subtitle, description,
  cover_image_url, cover_images, gallery_images, category, tags,
  status, is_featured, sort_weight, created_by,
  requires_shipping, virtual_card_code
) VALUES
(
  'platform', NULL, '365健康管理卡', '全年健康管理会员身份，专属标识',
  '每年365元，开通后账号即获得「365健康管理卡」会员身份，一年有效期，「我的」页面展示专属身份标识。健康打卡、AI 咨询、健康洞察等核心功能对所有用户免费开放，不受会员身份影响，本卡仅代表长期会员身份。',
  '', '[]'::jsonb, '[]'::jsonb, 'service', ARRAY['会员','365'],
  'active', false, 100, '145548cf-6509-4eb4-9041-6c46b306b96a',
  false, 'consumer_health365'
),
(
  'platform', NULL, '365管理师开通卡', '开通健康管理师基础版资质',
  '购买后（需完成管理师资质审核）即可升级为基础版套餐，获得基础版对应的客户名额与功能权益，一年有效期。若购买时资质审核尚未通过，将在审核通过后自动生效。',
  '', '[]'::jsonb, '[]'::jsonb, 'service', ARRAY['管理师','套餐'],
  'active', false, 90, '145548cf-6509-4eb4-9041-6c46b306b96a',
  false, 'manager_basic_365'
),
(
  'platform', NULL, '高级管理师包', '升级高级版套餐，解锁更多权益',
  '购买后即可升级为高级版套餐，获得更高的坐席数、客户名额与更多专属权益，一年有效期。',
  '', '[]'::jsonb, '[]'::jsonb, 'service', ARRAY['管理师','套餐','高级版'],
  'active', false, 80, '145548cf-6509-4eb4-9041-6c46b306b96a',
  false, 'manager_advanced_pack'
);

UPDATE product_skus SET price_cents = 36500, stock = 999999
WHERE is_default = true AND product_id = (SELECT id FROM products WHERE virtual_card_code = 'consumer_health365');

UPDATE product_skus SET price_cents = 36500, stock = 999999
WHERE is_default = true AND product_id = (SELECT id FROM products WHERE virtual_card_code = 'manager_basic_365');

UPDATE product_skus SET price_cents = 298000, stock = 999999
WHERE is_default = true AND product_id = (SELECT id FROM products WHERE virtual_card_code = 'manager_advanced_pack');
