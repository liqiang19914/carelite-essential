/**
 * Supabase 客户端 — 本地 PGlite 模式
 *
 * 不连接远程 Supabase，使用 PGlite (WASM PostgreSQL) 在浏览器中本地运行。
 * 数据持久化在 IndexedDB，首次启动自动执行 bootstrap + migrations + patches + seed。
 *
 * 导出的 `supabase` 对象提供与 supabase-js 兼容的 API：
 *   supabase.from(table).select().eq().single()
 *   supabase.auth.signInWithPassword()
 *   supabase.rpc(fn, params)
 *   supabase.functions.invoke(name, opts)  // 通过 registerFunctionHandler 注册本地处理器
 */

import { localSupabase } from "@/lib/supabase-adapter";

export const supabase = localSupabase;
