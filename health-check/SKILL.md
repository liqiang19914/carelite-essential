---
name: health-check
description: 按客户 ID 汇总健康档案列表与最近一次体征记录
---

# 健康档案速览（health-check）

按客户 ID 汇总健康档案列表与最近一次体征记录

## 使用场景

当用户在 CareLite-Essential 中提出与「健康档案速览」相关的请求时使用本技能：
按客户 ID 汇总健康档案列表与最近一次体征记录。

## 参数

| 参数 | 说明 | 必填 |
|------|------|------|
| `clientId` | 客户档案 ID（profiles.id） | 是 |

## 调用方式

调用时按上表传入参数，例如用户提供客户 ID 后以 `{"clientId": "<客户档案 ID>"}` 执行。

## 执行环境

本技能运行在 CareLite-Essential（健康师本地 AI 工作站）内置的 WorkBuddy 技能运行时中：

- 数据存储为本机 PGlite（PostgreSQL WASM），不经过任何服务器
- 应用内入口：登录后进入「智能体」页面，或在「设置 → WorkBuddy 技能」中查看技能注册状态
- AI 能力依赖 DeepSeek API（在应用「设置」页配置 API Key）
