import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { getDb } from "@/lib/pglite-db";
import { callDeepSeekDirect } from "@/lib/deepseek";
import { getSkillManifest, getRegisteredSkills, validateManifest } from "@/lib/workbuddy";
import { registerBuiltinSkills } from "@/skills/builtin";
import { brand } from "@/config/brand";
import PageContainer from "@/components/desktop/shell/PageContainer";
import PageHeader from "@/components/desktop/shell/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { toast } from "sonner";
import {
  AlertCircle,
  CheckCircle,
  Cpu,
  Database,
  Eye,
  EyeOff,
  Loader2,
  Puzzle,
  Save,
  TestTube,
} from "lucide-react";

const DEFAULT_BASE_URL = "https://api.deepseek.com";
const DEFAULT_MODEL = "deepseek-chat";

const MODEL_OPTIONS = [
  { value: "deepseek-chat", label: "DeepSeek Chat（对话模型 · 响应快）" },
  { value: "deepseek-reasoner", label: "DeepSeek Reasoner（深度推理 · 响应慢）" },
];

export default function SettingsPage() {
  // ── DeepSeek 配置 ──
  const { data: saved, isLoading: configLoading } = useQuery({
    queryKey: ["deepseek-settings"],
    queryFn: async () => {
      const db = await getDb();
      const r = await db.query<{ key: string; value: string }>(
        `SELECT key, value FROM system_settings WHERE key LIKE 'deepseek%'`,
      );
      const map: Record<string, string> = {};
      for (const row of r.rows) map[row.key] = row.value ?? "";
      return map;
    },
  });

  const [apiKey, setApiKey] = useState("");
  const [model, setModel] = useState(DEFAULT_MODEL);
  const [baseUrl, setBaseUrl] = useState(DEFAULT_BASE_URL);
  const [showKey, setShowKey] = useState(false);
  const [saving, setSaving] = useState(false);
  const [testing, setTesting] = useState(false);
  const [testResult, setTestResult] = useState<{ ok: boolean; message: string } | null>(null);

  useEffect(() => {
    if (saved) {
      setApiKey(saved["deepseek_api_key"] ?? "");
      setModel(saved["deepseek_model"] || DEFAULT_MODEL);
      setBaseUrl(saved["deepseek_base_url"] || DEFAULT_BASE_URL);
    }
  }, [saved]);

  // ── WorkBuddy 技能（注册幂等） ──
  useEffect(() => {
    registerBuiltinSkills();
  }, []);
  const manifest = getSkillManifest();
  const registeredIds = new Set(getRegisteredSkills().map((s) => s.id));
  const manifestIssues = validateManifest();

  // ── 本地数据库统计 ──
  const { data: stats } = useQuery({
    queryKey: ["settings-db-stats"],
    queryFn: async () => {
      const db = await getDb();
      const [clients, followups, records] = await Promise.all([
        db.query<{ c: number }>(`SELECT count(*)::int AS c FROM client_relations WHERE status = 'active'`),
        db.query<{ c: number }>(`SELECT count(*)::int AS c FROM follow_up_records`),
        db.query<{ c: number }>(`SELECT count(*)::int AS c FROM health_records`),
      ]);
      return {
        clients: clients.rows[0]?.c ?? 0,
        followups: followups.rows[0]?.c ?? 0,
        records: records.rows[0]?.c ?? 0,
      };
    },
  });

  const handleSave = async () => {
    setSaving(true);
    try {
      const settings = [
        { key: "deepseek_api_key", value: apiKey.trim() },
        { key: "deepseek_model", value: model },
        { key: "deepseek_base_url", value: baseUrl.trim() },
      ];
      for (const s of settings) {
        const { error } = await supabase
          .from("system_settings")
          .upsert({ ...s, updated_at: new Date().toISOString() }, { onConflict: "key" });
        if (error) throw error;
      }
      toast.success("配置已保存，AI 对话即时生效");
    } catch {
      toast.error("保存失败，请重试");
    } finally {
      setSaving(false);
    }
  };

  const handleTest = async () => {
    if (!apiKey.trim()) {
      toast.error("请先填写 API Key");
      return;
    }
    setTesting(true);
    setTestResult(null);
    try {
      await callDeepSeekDirect(
        { apiKey: apiKey.trim(), baseUrl: baseUrl.trim() || DEFAULT_BASE_URL, model },
        [{ role: "user", content: "你好" }],
        { maxTokens: 16 },
      );
      setTestResult({ ok: true, message: "连接成功" });
    } catch (e) {
      setTestResult({ ok: false, message: e instanceof Error ? e.message : "连接失败" });
    } finally {
      setTesting(false);
    }
  };

  const isConfigured = Boolean(saved?.["deepseek_api_key"]?.trim());

  return (
    <PageContainer width="form">
      <PageHeader crumbs={[{ label: "设置" }]} title="通用设置" />

      <div className="space-y-5 pb-8">
        {/* DeepSeek API 配置 */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-base font-semibold">
              <Cpu className="h-4 w-4 text-primary" />
              DeepSeek API 配置
            </CardTitle>
            <CardDescription>
              健康师智能体通过 DeepSeek 官方 API 生成回答，密钥仅保存在本机数据库
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            {configLoading ? (
              <div className="space-y-3">
                <Skeleton className="h-9 w-full" />
                <Skeleton className="h-9 w-full" />
                <Skeleton className="h-9 w-1/2" />
              </div>
            ) : (
              <>
                <div className="flex items-center gap-2 text-sm">
                  {isConfigured ? (
                    <>
                      <CheckCircle className="h-4 w-4 text-emerald-500" />
                      <span className="text-emerald-600">已配置</span>
                      <span className="text-muted-foreground">
                        当前模型：{MODEL_OPTIONS.find((m) => m.value === model)?.label ?? model}
                      </span>
                    </>
                  ) : (
                    <>
                      <AlertCircle className="h-4 w-4 text-amber-500" />
                      <span className="text-amber-600">未配置</span>
                      <span className="text-muted-foreground">
                        配置后即可在「健康师智能体」使用 AI 对话
                      </span>
                    </>
                  )}
                </div>

                <div className="space-y-2">
                  <Label>
                    API Key <span className="text-destructive">*</span>
                  </Label>
                  <div className="relative">
                    <Input
                      type={showKey ? "text" : "password"}
                      value={apiKey}
                      onChange={(e) => setApiKey(e.target.value)}
                      placeholder="sk-..."
                      className="pr-10"
                    />
                    <button
                      type="button"
                      onClick={() => setShowKey(!showKey)}
                      className="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
                    >
                      {showKey ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                    </button>
                  </div>
                  <p className="text-xs text-muted-foreground">
                    在 platform.deepseek.com 创建 API Key
                  </p>
                </div>

                <div className="space-y-2">
                  <Label>对话模型</Label>
                  <Select value={model} onValueChange={setModel}>
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {MODEL_OPTIONS.map((m) => (
                        <SelectItem key={m.value} value={m.value}>
                          {m.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>

                <div className="space-y-2">
                  <Label>接口地址</Label>
                  <Input
                    value={baseUrl}
                    onChange={(e) => setBaseUrl(e.target.value)}
                    placeholder={DEFAULT_BASE_URL}
                  />
                  <p className="text-xs text-muted-foreground">
                    默认官方地址，支持 OpenAI 兼容接口（自动拼接 /chat/completions）
                  </p>
                </div>

                <div className="flex items-center justify-between pt-1">
                  <div className="flex items-center gap-2">
                    <Button variant="outline" size="sm" onClick={handleTest} disabled={testing}>
                      {testing ? (
                        <Loader2 className="mr-1.5 h-4 w-4 animate-spin" />
                      ) : (
                        <TestTube className="mr-1.5 h-4 w-4" />
                      )}
                      测试连接
                    </Button>
                    {testResult && (
                      <span
                        className={`flex items-center gap-1 text-sm ${
                          testResult.ok ? "text-emerald-600" : "text-destructive"
                        }`}
                      >
                        {testResult.ok ? (
                          <CheckCircle className="h-4 w-4" />
                        ) : (
                          <AlertCircle className="h-4 w-4" />
                        )}
                        {testResult.message}
                      </span>
                    )}
                  </div>
                  <Button onClick={handleSave} disabled={saving}>
                    {saving ? (
                      <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                    ) : (
                      <Save className="mr-2 h-4 w-4" />
                    )}
                    保存配置
                  </Button>
                </div>
              </>
            )}
          </CardContent>
        </Card>

        {/* 本地数据库 */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-base font-semibold">
              <Database className="h-4 w-4 text-primary" />
              本地数据库
            </CardTitle>
            <CardDescription>所有数据仅保存在本机，不上传任何服务器</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid grid-cols-2 gap-x-6 gap-y-2 text-sm">
              <div className="flex items-center justify-between border-b pb-2">
                <span className="text-muted-foreground">数据库引擎</span>
                <span className="font-medium">PGlite（WASM PostgreSQL）</span>
              </div>
              <div className="flex items-center justify-between border-b pb-2">
                <span className="text-muted-foreground">存储位置</span>
                <span className="font-mono text-xs font-medium">idb://carelite-essential</span>
              </div>
              <div className="flex items-center justify-between border-b pb-2">
                <span className="text-muted-foreground">活跃客户</span>
                <span className="font-medium">{stats ? `${stats.clients} 名` : "—"}</span>
              </div>
              <div className="flex items-center justify-between border-b pb-2">
                <span className="text-muted-foreground">跟进记录</span>
                <span className="font-medium">{stats ? `${stats.followups} 条` : "—"}</span>
              </div>
              <div className="flex items-center justify-between border-b pb-2">
                <span className="text-muted-foreground">健康档案</span>
                <span className="font-medium">{stats ? `${stats.records} 份` : "—"}</span>
              </div>
              <div className="flex items-center justify-between border-b pb-2">
                <span className="text-muted-foreground">持久化方式</span>
                <span className="font-medium">浏览器 IndexedDB</span>
              </div>
            </div>
            <p className="text-xs text-muted-foreground">
              提示：清除浏览器站点数据会同时删除本地数据库，重要数据可通过客户列表「导出所选」备份 CSV。
            </p>
          </CardContent>
        </Card>

        {/* WorkBuddy 技能 */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-base font-semibold">
              <Puzzle className="h-4 w-4 text-primary" />
              WorkBuddy 技能
            </CardTitle>
            <CardDescription>
              已内置 {manifest.skills.length} 个技能，可被 WorkBuddy 桌面助手通过 runSkill() 调用
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-2.5">
            {manifest.skills.map((skill) => (
              <div
                key={skill.id}
                className="flex items-start justify-between gap-3 rounded-lg border p-3"
              >
                <div className="min-w-0">
                  <div className="flex items-center gap-2">
                    <span className="text-sm font-medium">{skill.name}</span>
                    <code className="rounded bg-muted px-1.5 py-0.5 text-[11px] text-muted-foreground">
                      {skill.id}
                    </code>
                  </div>
                  <p className="mt-0.5 text-xs text-muted-foreground">{skill.description}</p>
                  {skill.parameters.length > 0 && (
                    <div className="mt-1.5 flex flex-wrap gap-1">
                      {skill.parameters.map((p) => (
                        <Badge key={p.name} variant="outline" className="text-[10px] font-normal">
                          {p.name}
                          {p.required && <span className="text-destructive">*</span>}
                        </Badge>
                      ))}
                    </div>
                  )}
                </div>
                <Badge
                  variant="outline"
                  className={
                    registeredIds.has(skill.id)
                      ? "shrink-0 border-emerald-500 text-emerald-600"
                      : "shrink-0 border-amber-500 text-amber-600"
                  }
                >
                  {registeredIds.has(skill.id) ? "已就绪" : "未注册"}
                </Badge>
              </div>
            ))}
            {manifestIssues.length > 0 && (
              <p className="text-xs text-amber-600">
                清单校验：{manifestIssues.join("；")}
              </p>
            )}
          </CardContent>
        </Card>

        {/* 关于 */}
        <Card>
          <CardHeader>
            <CardTitle className="text-base font-semibold">关于</CardTitle>
          </CardHeader>
          <CardContent className="text-sm">
            <div className="flex items-center justify-between border-b pb-2">
              <span className="text-muted-foreground">应用</span>
              <span className="font-medium">{brand.name}</span>
            </div>
            <div className="flex items-center justify-between border-b pb-2">
              <span className="text-muted-foreground">版本</span>
              <span className="font-medium">v{brand.version}</span>
            </div>
            <div className="flex items-center justify-between pt-2">
              <span className="text-muted-foreground">定位</span>
              <span className="font-medium">{brand.tagline}</span>
            </div>
          </CardContent>
        </Card>
      </div>
    </PageContainer>
  );
}
