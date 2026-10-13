/**
 * WorkBuddy 技能注册入口
 *
 * 技能目录约定：
 * - 清单：`src/skills/manifest.json` 声明技能 id / 名称 / 描述 / 参数
 * - 实现：`src/skills/` 下技能文件调用 registerSkill() 注册执行入口（内置技能见 builtin.ts）
 * - 调用：外部（WorkBuddy 桌面助手）通过 runSkill(id, params) 触发，
 *   返回结构化结果 + 文本摘要，供 AI 二次加工或直接展示
 */

export interface WorkBuddySkillParameter {
  /** 参数名（英文，调用时作为 params 的 key） */
  name: string;
  /** 中文说明（供 AI / 用户理解填什么） */
  description: string;
  required: boolean;
}

export interface WorkBuddySkillResult {
  ok: boolean;
  /** 供展示 / AI 加工的文本摘要 */
  output: string;
  /** 可选结构化数据 */
  data?: unknown;
}

export interface WorkBuddySkill {
  /** 全局唯一，与 manifest.json 中 id 对应，如 "client-summary" */
  id: string;
  /** 中文名，如 "客户概况统计" */
  name: string;
  description: string;
  parameters: WorkBuddySkillParameter[];
  run: (params: Record<string, unknown>) => Promise<WorkBuddySkillResult>;
}

const registry = new Map<string, WorkBuddySkill>();

/** 注册技能（同 id 重复注册以最后一次为准，保证幂等） */
export function registerSkill(skill: WorkBuddySkill) {
  registry.set(skill.id, skill);
}

export function getRegisteredSkills(): WorkBuddySkill[] {
  return [...registry.values()];
}

/**
 * 执行技能：统一做存在性检查与必填参数校验，异常降级为 ok:false 结果
 */
export async function runSkill(
  id: string,
  params?: Record<string, unknown>,
): Promise<WorkBuddySkillResult> {
  const skill = registry.get(id);
  if (!skill) {
    return { ok: false, output: `技能「${id}」未注册` };
  }
  const input = params ?? {};
  for (const p of skill.parameters) {
    if (p.required && (input[p.name] === undefined || input[p.name] === null || input[p.name] === "")) {
      return { ok: false, output: `缺少必填参数「${p.description}」` };
    }
  }
  try {
    return await skill.run(input);
  } catch (e) {
    return { ok: false, output: e instanceof Error ? e.message : String(e) };
  }
}

export interface SkillManifest {
  version: string;
  name: string;
  description: string;
  skills: {
    id: string;
    name: string;
    description: string;
    parameters: WorkBuddySkillParameter[];
  }[];
}

import manifestJson from "@/skills/manifest.json";

export function getSkillManifest(): SkillManifest {
  return manifestJson as SkillManifest;
}

/** 校验清单与已注册技能的一致性，返回差异描述（空数组 = 一致） */
export function validateManifest(): string[] {
  const issues: string[] = [];
  const manifestIds = new Set(getSkillManifest().skills.map((s) => s.id));
  for (const id of manifestIds) {
    if (!registry.has(id)) issues.push(`清单中的技能「${id}」未注册实现`);
  }
  for (const id of registry.keys()) {
    if (!manifestIds.has(id)) issues.push(`已注册技能「${id}」未在清单中声明`);
  }
  return issues;
}
