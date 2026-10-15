# carelite-essential 技能包

CareLite Essential 健康师本地工作站技能清单

> 版本 1.0.0。本分支由 CI 在每次发版时自动生成，请勿手动编辑。

## 技能列表

| 技能 | 说明 | 参数 |
|------|------|------|
| [客户概况统计](./client-summary/SKILL.md)（`client-summary`） | 统计活跃客户总数、本周新增与回收站数量 | 无 |
| [健康档案速览](./health-check/SKILL.md)（`health-check`） | 按客户 ID 汇总健康档案列表与最近一次体征记录 | `clientId` |
| [跟进提醒盘点](./followup-suggest/SKILL.md)（`followup-suggest`） | 列出已到期或今日应跟进的客户，输出跟进优先级建议 | 无 |

## 安装到 WorkBuddy

1. 将本分支下对应技能目录（如 `client-summary/`）下载或克隆到本地
2. 在 WorkBuddy 中按技能目录安装（识别目录内的 `SKILL.md`）
3. 技能需在 CareLite-Essential 应用内执行：打开应用 → 智能体页面发起请求

## 源码

技能实现在主仓库 `src/skills/builtin.ts`，清单见 `src/skills/manifest.json`。
