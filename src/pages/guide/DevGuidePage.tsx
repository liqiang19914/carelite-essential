import PageContainer from "@/components/desktop/shell/PageContainer";
import PageHeader from "@/components/desktop/shell/PageHeader";
import PanelCard from "@/components/desktop/shell/PanelCard";
import { brand } from "@/config/brand";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Link } from "react-router-dom";
import { KeyRound, PackageOpen, Puzzle, TerminalSquare } from "lucide-react";

const STEPS = [
  { title: "安装 CodeDesk / Trae", desc: "任意支持打开本地文件夹的 AI IDE 均可（CodeDesk、Trae 等），用于打开本项目目录进行二次开发。" },
  { title: "打开项目目录", desc: "在 IDE 顶部菜单选择「打开文件夹」，定位到本应用源码目录（git clone 下来的 carelite-essential 根目录）。" },
  { title: "安装依赖", desc: "在终端执行 npm install（Node 20+，无需 Docker / 数据库等任何额外环境）。" },
  { title: "本地运行", desc: "执行 npm run tauri:dev 启动桌面开发模式（或 npm run dev 仅跑 Web 端），改代码即时热更新。" },
  { title: "出包发版", desc: "提交并推送后打标签（git tag v0.x.x && git push origin v0.x.x），CI 自动编译四平台安装包并发布 Release。" },
];

export default function DevGuidePage() {
  return (
    <PageContainer width="reading">
      <PageHeader
        crumbs={[{ label: "开发指南" }]}
        title="二次开发指南"
        description={`${brand.name} 是本地优先的健康师工作站：数据仅存本机（PGlite），源码完全开放。通过 WorkBuddy 技能扩展 AI 能力，通过 CodeDesk 等任意 IDE 修改源码。`}
      />

      <div className="space-y-4">
        <PanelCard
          title="开箱即用"
          description="首次启动自动完成数据库初始化，无需任何配置即可使用"
        >
          <div className="space-y-3 text-sm">
            <div className="flex items-start gap-3">
              <PackageOpen className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />
              <p>
                首次启动自动建库（890 个迁移在本地 PGlite 执行），数据持久化在浏览器 IndexedDB，
                <span className="text-muted-foreground">卸载应用前请勿手动清理应用数据</span>。
              </p>
            </div>
            <div className="flex items-start gap-3">
              <KeyRound className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />
              <p>
                健康师智能体需要 DeepSeek API Key：顶部菜单点「
                <Link to="/settings" className="font-medium text-primary underline-offset-2 hover:underline">
                  设置
                </Link>
                」→ 粘贴 Key → 测试连接，即配即用。
              </p>
            </div>
          </div>
        </PanelCard>

        <PanelCard
          title="WorkBuddy 技能开发"
          description="不改源码即可扩展智能体能力"
          action={<Badge variant="secondary">src/skills/</Badge>}
        >
          <ol className="space-y-2 text-sm">
            <li className="flex items-start gap-3">
              <Puzzle className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />
              <span>
                在 <code className="rounded bg-muted px-1.5 py-0.5 text-xs">src/skills/manifest.json</code> 声明技能
                （id / 名称 / 描述 / 触发词），应用启动时自动注册。
              </span>
            </li>
            <li className="flex items-start gap-3">
              <Puzzle className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />
              <span>
                技能实现放在 <code className="rounded bg-muted px-1.5 py-0.5 text-xs">src/skills/builtin.ts</code>，
                复用 <code className="rounded bg-muted px-1.5 py-0.5 text-xs">runSkill</code> 协议，内置了客户摘要 / 健康监测 / 跟进建议 3 个示例可参考。
              </span>
            </li>
            <li className="flex items-start gap-3">
              <Puzzle className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />
              <span>
                发布：CI 会把技能打包为 WorkBuddy 可识别的 <code className="rounded bg-muted px-1.5 py-0.5 text-xs">SKILL.md</code> 目录结构，
                自动发布到 GitHub 仓库的 <code className="rounded bg-muted px-1.5 py-0.5 text-xs">skills</code> 分支。
              </span>
            </li>
          </ol>
        </PanelCard>

        <PanelCard
          title="CodeDesk 源码二开"
          description="用 IDE 打开项目目录，五步跑通本地开发"
          action={<Badge variant="secondary">Node 20+</Badge>}
        >
          <ol className="space-y-3 text-sm">
            {STEPS.map((step, index) => (
              <li key={step.title} className="flex items-start gap-3">
                <span className="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-primary/10 text-xs font-semibold text-primary">
                  {index + 1}
                </span>
                <span>
                  <span className="font-medium">{step.title}</span>
                  <span className="mt-0.5 block text-muted-foreground">{step.desc}</span>
                </span>
              </li>
            ))}
          </ol>
          <div className="mt-4 rounded-lg bg-muted p-3 font-mono text-xs leading-6">
            git clone https://github.com/liqiang19914/carelite-essential.git
            <br />
            cd carelite-essential
            <br />
            npm install
            <br />
            npm run dev
            <span className="text-muted-foreground">　# 或 npm run tauri:dev 启动桌面端</span>
          </div>
        </PanelCard>

        <PanelCard title="常用命令" description="日常开发与维护速查">
          <div className="overflow-hidden rounded-lg border">
            <table className="w-full text-sm">
              <tbody>
                {[
                  ["npm run dev", "启动 Web 开发服务器（Vite，端口 1420）"],
                  ["npm run tauri:dev", "启动桌面端开发模式（Tauri 壳）"],
                  ["npm run build", "构建前端产物到 dist/"],
                  ["npm run icons", "用 app-icon.png 重新生成全套应用图标"],
                  ["node scripts/pack-skills.mjs", "本地打包技能到 dist-skills/ 预览"],
                ].map(([cmd, desc]) => (
                  <tr key={cmd} className="border-b last:border-b-0">
                    <td className="w-[280px] px-3 py-2 font-mono text-xs">{cmd}</td>
                    <td className="px-3 py-2 text-muted-foreground">{desc}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </PanelCard>
      </div>

      <div className="mt-4 flex items-center gap-3 rounded-lg border bg-card p-4 text-sm">
        <TerminalSquare className="h-4 w-4 shrink-0 text-muted-foreground" />
        <p className="text-muted-foreground">
          准备好了？先到
          <Button asChild variant="link" className="h-auto px-1.5 py-0 text-sm">
            <Link to="/settings">设置页配置 DeepSeek API Key</Link>
          </Button>
          开启智能体。
        </p>
      </div>
    </PageContainer>
  );
}
