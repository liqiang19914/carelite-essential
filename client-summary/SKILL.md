---
name: client-summary
description: 统计活跃客户总数、本周新增与回收站数量
---

# 客户概况统计（client-summary）

统计活跃客户总数、本周新增与回收站数量

## 使用场景

当用户在 CareLite-Essential 中提出与「客户概况统计」相关的请求时使用本技能：
统计活跃客户总数、本周新增与回收站数量。

## 参数

本技能无需参数。

## 调用方式

用户在应用内发出与技能描述匹配的请求时，直接执行本技能。

## 执行环境

本技能运行在 CareLite-Essential（健康师本地 AI 工作站）内置的 WorkBuddy 技能运行时中：

- 数据存储为本机 PGlite（PostgreSQL WASM），不经过任何服务器
- 应用内入口：登录后进入「智能体」页面，或在「设置 → WorkBuddy 技能」中查看技能注册状态
- AI 能力依赖 DeepSeek API（在应用「设置」页配置 API Key）
