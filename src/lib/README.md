# src/lib

存放核心工具与适配层（从 D:\dev\carelite 复用，按需 cherry-pick）：

- `pglite.ts` —— PGlite 本地数据库实例与 schema 初始化（替代 HMS 的 Supabase 远程库）
- `supabase-adapter.ts` —— 对上层暴露类 Supabase 的查询接口，底层切到 PGlite
- `deepseek.ts` —— DeepSeek API 调用封装（聊天补全 / 流式输出）
- `auth.ts` —— 本地账号体系（bcryptjs 哈希，无后端）
- `cn.ts` —— clsx + tailwind-merge 类名合并工具

> 当前为空骨架，待工单迁移业务代码。
