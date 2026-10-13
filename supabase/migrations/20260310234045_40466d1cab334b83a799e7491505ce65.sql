
-- OpenClaw 资源管理表
CREATE TABLE openclaw_resources (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  category text NOT NULL DEFAULT 'plugin',
  title text NOT NULL,
  description text NOT NULL DEFAULT '',
  version text NOT NULL DEFAULT '',
  file_url text NOT NULL,
  file_name text NOT NULL,
  file_size bigint NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE openclaw_resources IS 'OpenClaw资源管理表，存储插件包、安装包等可下载资源';
COMMENT ON COLUMN openclaw_resources.category IS '资源分类: plugin=插件包, installer_windows=Windows安装包, installer_macos=macOS安装包, installer_linux=Linux安装包, installer_android=Android安装包, document=文档, other=其他';
COMMENT ON COLUMN openclaw_resources.is_active IS '是否启用，false表示已下架';

CREATE INDEX idx_openclaw_resources_category ON openclaw_resources(category);
CREATE INDEX idx_openclaw_resources_is_active ON openclaw_resources(is_active);
