UPDATE profiles SET avatar_url = 'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/static-assets/platform/uxarts-agent/20260609/918aab578d344f04a6a05427d54e300d.png' WHERE avatar_url = 'https://b.ux-cdn.com/uxarts-agent/20260609/918aab578d344f04a6a05427d54e300d.png';

UPDATE managers SET digital_avatar_image_url = 'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/static-assets/platform/uxarts-agent/20260609/918aab578d344f04a6a05427d54e300d.png' WHERE digital_avatar_image_url = 'https://b.ux-cdn.com/uxarts-agent/20260609/918aab578d344f04a6a05427d54e300d.png';

UPDATE managers SET partner_card_avatar_url = 'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/static-assets/platform/uxarts-agent/20260609/918aab578d344f04a6a05427d54e300d.png' WHERE partner_card_avatar_url = 'https://b.ux-cdn.com/uxarts-agent/20260609/918aab578d344f04a6a05427d54e300d.png';

UPDATE manager_courses SET cover_image_url = 'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/static-assets/platform/uxarts-agent/20260609/3a2430c792514f7b8ff66f00f773fba8.png' WHERE cover_image_url = 'https://b.ux-cdn.com/uxarts-agent/20260609/3a2430c792514f7b8ff66f00f773fba8.png';

UPDATE manager_courses SET cover_image_url = 'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/static-assets/platform/uxarts-agent/20260609/71e7b6e48923423f9f94a24f0dac0a17.png' WHERE cover_image_url = 'https://b.ux-cdn.com/uxarts-agent/20260609/71e7b6e48923423f9f94a24f0dac0a17.png';

UPDATE manager_courses SET cover_image_url = 'https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/static-assets/platform/uxarts-agent/20260609/89ec0bbadcf646e9ab3b11263b508aa0.png' WHERE cover_image_url = 'https://b.ux-cdn.com/uxarts-agent/20260609/89ec0bbadcf646e9ab3b11263b508aa0.png';

UPDATE diet_map_templates SET report = jsonb_set(report, '{sourceImageUrl}', '"https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/static-assets/platform/uxarts/20260804/8f71dd6a1a964ab2883305175e697426.jpg"') WHERE report->>'sourceImageUrl' = 'https://b.ux-cdn.com/uxarts/20260804/8f71dd6a1a964ab2883305175e697426.jpg';