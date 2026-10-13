-- 小程序配置项
INSERT INTO system_settings (key, value, description) VALUES
  ('miniapp_name',            '', '小程序名称'),
  ('miniapp_original_id',     '', '小程序原始ID，如 gh_xxxxxxxx'),
  ('miniapp_appid',           '', '小程序 AppID'),
  ('miniapp_appsecret',       '', '小程序 AppSecret'),
  ('miniapp_upload_key',      '', '小程序代码上传密钥（RSA 私钥）'),
  ('miniapp_request_domain',  '', 'request 合法域名'),
  ('miniapp_socket_domain',   '', 'socket 合法域名'),
  ('miniapp_upload_domain',   '', 'uploadFile 合法域名'),
  ('miniapp_download_domain', '', 'downloadFile 合法域名'),
  ('miniapp_udp_domain',      '', 'udp 合法域名'),
  ('miniapp_business_domain', '', '业务域名'),
  ('miniapp_version',         '1.0.0', '小程序当前版本号')
ON CONFLICT (key) DO NOTHING;
