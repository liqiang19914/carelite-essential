/**
 * Skill 分支发布打包：把 src/skills/manifest.json 转成 WorkBuddy 可识别的技能目录结构。
 *
 * 产物 dist-skills/（CI 发布到 skills 分支）：
 *   README.md               技能包总说明 + 安装方式
 *   manifest.json           程序可读原始清单
 *   <skill-id>/SKILL.md     WorkBuddy 技能文件（frontmatter: name/description）
 *
 * 用法：node scripts/pack-skills.mjs
 */
import { readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const manifestPath = join(root, "src", "skills", "manifest.json");
const outDir = join(root, "dist-skills");

const manifest = JSON.parse(readFileSync(manifestPath, "utf-8"));

const ENV_NOTE = `## 执行环境

本技能运行在 CareLite-Essential（健康师本地 AI 工作站）内置的 WorkBuddy 技能运行时中：

- 数据存储为本机 PGlite（PostgreSQL WASM），不经过任何服务器
- 应用内入口：登录后进入「智能体」页面，或在「设置 → WorkBuddy 技能」中查看技能注册状态
- AI 能力依赖 DeepSeek API（在应用「设置」页配置 API Key）`;

function skillMd(skill) {
  const params = skill.parameters || [];
  const paramTable = params.length
    ? [
        "| 参数 | 说明 | 必填 |",
        "|------|------|------|",
        ...params.map(
          (p) => `| \`${p.name}\` | ${p.description} | ${p.required ? "是" : "否"} |`,
        ),
      ].join("\n")
    : "本技能无需参数。";

  const invocation = params.length
    ? `调用时按上表传入参数，例如用户提供客户 ID 后以 \`{"clientId": "<客户档案 ID>"}\` 执行。`
    : `用户在应用内发出与技能描述匹配的请求时，直接执行本技能。`;

  return `---
name: ${skill.id}
description: ${skill.description}
---

# ${skill.name}（${skill.id}）

${skill.description}

## 使用场景

当用户在 CareLite-Essential 中提出与「${skill.name}」相关的请求时使用本技能：
${skill.description}。

## 参数

${paramTable}

## 调用方式

${invocation}

${ENV_NOTE}
`;
}

function readme() {
  const lines = [
    `# ${manifest.name} 技能包`,
    "",
    manifest.description,
    "",
    `> 版本 ${manifest.version}。本分支由 CI 在每次发版时自动生成，请勿手动编辑。`,
    "",
    "## 技能列表",
    "",
    "| 技能 | 说明 | 参数 |",
    "|------|------|------|",
    ...manifest.skills.map(
      (s) =>
        `| [${s.name}](./${s.id}/SKILL.md)（\`${s.id}\`） | ${s.description} | ${
          (s.parameters || []).map((p) => `\`${p.name}\``).join("、") || "无"
        } |`,
    ),
    "",
    "## 安装到 WorkBuddy",
    "",
    "1. 将本分支下对应技能目录（如 `client-summary/`）下载或克隆到本地",
    "2. 在 WorkBuddy 中按技能目录安装（识别目录内的 `SKILL.md`）",
    "3. 技能需在 CareLite-Essential 应用内执行：打开应用 → 智能体页面发起请求",
    "",
    "## 源码",
    "",
    "技能实现在主仓库 `src/skills/builtin.ts`，清单见 `src/skills/manifest.json`。",
    "",
  ];
  return lines.join("\n");
}

rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });

writeFileSync(join(outDir, "README.md"), readme(), "utf-8");
writeFileSync(
  join(outDir, "manifest.json"),
  JSON.stringify(manifest, null, 2) + "\n",
  "utf-8",
);

for (const skill of manifest.skills) {
  const dir = join(outDir, skill.id);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "SKILL.md"), skillMd(skill), "utf-8");
}

console.log(
  `✅ 已打包 ${manifest.skills.length} 个技能到 dist-skills/：${manifest.skills.map((s) => s.id).join(", ")}`,
);
