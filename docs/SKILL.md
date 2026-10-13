# WorkBuddy 技能接入

CareLite-Essential 可作为 [WorkBuddy](https://github.com/your-org/workbuddy) 的技能被调用。本文档为大纲，待 Phase 4 实现。

## 1. 技能目录约定

```
skills/
└─ carelite-essential/
   ├─ SKILL.md            # 技能说明（本文件的运行时版本）
   ├─ manifest.json       # 技能元数据：name / version / entry / permissions
   └─ handler.ts          # 入口处理器
```

## 2. 入口协议

WorkBuddy 通过标准协议调用技能：

- **输入**：自然语言意图 + 上下文（客户 ID、当前页面等）
- **输出**：结构化动作（跳转页面 / 查询数据 / 调用 DeepSeek 生成建议）
- **调用方式**：HTTP（本地 1420 端口）或 Tauri IPC

## 3. 与 CareLite 集成方式

- CareLite-Essential 运行时暴露 `/api/skill/invoke` 本地端点。
- WorkBuddy 在技能清单中注册本技能，调用时 CareLite 内部路由到对应页面 + 触发 AI。
- 数据通过 PGlite 本地库查询，不依赖远程服务。

> 详细接口契约待 Phase 4 与 WorkBuddy 对齐后补全。
