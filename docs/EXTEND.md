# 二开指南

本文档说明如何在 CareLite-Essential 骨架上二次开发。

## 1. 如何加模块

1. 在 `src/pages/<端>/<NewPage>.tsx` 新建页面组件。
2. 在 `src/App.tsx` 的 `<Routes>` 中注册路由。
3. 业务逻辑放 `src/lib/`，页面只做编排。

## 2. 如何改品牌

编辑 `src/config/brand.ts`，修改 `name` / `tagline` / `version` 即可。窗口标题在 `src-tauri/tauri.conf.json` 的 `app.windows[0].title`。

## 3. 如何接 AI

- **DeepSeek**：在 `src/lib/deepseek.ts` 封装 `chat.completions` 调用（流式优先）。API Key 从 `.env.local` 的 `VITE_DEEPSEEK_API_KEY` 读取。
- **替换为其他模型**：实现同签名接口即可，上层无感。

## 4. 本地数据

- 使用 `@electric-sql/pglite` 在浏览器/WASM 内跑 PostgreSQL，无需后端。
- 适配层 `src/lib/supabase-adapter.ts` 对上暴露类 Supabase 查询接口，便于从 HMS 迁移代码时最小改动。

## 5. 目录约定

```
src/lib/       工具与适配层（pglite / deepseek / auth / cn）
src/config/    静态配置（品牌）
src/pages/     页面组件，按端分目录
src/components/ 共享组件（待建）
```
