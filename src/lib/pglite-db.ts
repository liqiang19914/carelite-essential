/**
 * PGlite 本地数据库单例 + 初始化
 *
 * 使用 IndexedDB 持久化，首次启动时执行 bootstrap → migrations → patches → seed
 * 后续启动直接复用已有数据。提供 getDb() 获取已就绪的 PGlite 实例。
 *
 * SQL 文件通过 Vite 的 ?raw 导入在构建时内联，无需运行时 fetch。
 */

import { PGlite } from "@electric-sql/pglite";

// Vite raw imports — 构建时将 SQL 文件内容内联为字符串
import bootstrapSqlRaw from "../../supabase/bootstrap.sql?raw";
import patchesSqlRaw from "../../supabase/patches.sql?raw";
import seedSqlRaw from "../../supabase/seed.sql?raw";

// WASM 文件放在 public/ 目录，通过公共路径加载
// （PGlite 包的 exports 字段不包含 .wasm，无法用 ?url 导入）
const WASM_BASE = `${import.meta.env.BASE_URL}wasm/`;

const DATA_DIR = "idb://carelite-essential";

let dbInstance: PGlite | null = null;
let initPromise: Promise<PGlite> | null = null;

/**
 * 获取已就绪的 PGlite 实例（单例）
 * 首次调用会触发数据库初始化（bootstrap + migrations + patches + seed）
 */
export function getDb(): Promise<PGlite> {
  if (dbInstance) return Promise.resolve(dbInstance);
  if (initPromise) return initPromise;

  initPromise = (async () => {
    const db = new PGlite({
      dataDir: DATA_DIR,
      wasmConfig: {
        locateFile: (filename: string) => `${WASM_BASE}${filename}`,
      },
    });
    await db.waitReady;

    // 检查是否已初始化（profiles 表是否存在）
    let initialized = false;
    try {
      const r = await db.query(
        `SELECT count(*) as cnt FROM pg_tables WHERE schemaname = 'public' AND tablename = 'profiles'`
      );
      if (Number(r.rows[0]?.cnt) > 0) {
        initialized = true;
      }
    } catch {
      // 未初始化
    }

    if (!initialized) {
      await initDatabase(db);
    }

    // 设置当前用户变量（auth.uid 等）为空（未登录状态）
    await db.exec("SET app.current_uid = '';");

    dbInstance = db;
    return db;
  })();

  return initPromise;
}

/**
 * 设置当前登录用户 ID（供 RLS 函数 auth.uid() 使用）
 */
export async function setCurrentUid(db: PGlite, uid: string) {
  await db.exec(`SET app.current_uid = '${uid.replace(/'/g, "''")}';`);
}

/**
 * 通过 Vite 的 import.meta.glob 加载所有迁移文件
 */
function loadMigrations(): { name: string; sql: string }[] {
  const files = import.meta.glob("../../supabase/migrations/*.sql", {
    query: "?raw",
    eager: true,
    import: "default",
  }) as Record<string, string>;

  return Object.entries(files)
    .map(([path, sql]) => ({
      name: path.split("/").pop()!,
      sql,
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * 执行完整数据库初始化：bootstrap → migrations → patches → seed
 */
async function initDatabase(db: PGlite) {
  // 1. bootstrap.sql
  try {
    await db.exec(bootstrapSqlRaw);
  } catch (e) {
    console.warn("[pglite] bootstrap.sql 部分失败:", e);
  }

  // 2. migrations
  const migrations = loadMigrations();
  let success = 0;
  const failed: string[] = [];

  for (const { name, sql } of migrations) {
    try {
      await db.transaction(async (tx) => {
        await tx.exec(sql);
      });
      success++;
    } catch {
      failed.push(name);
    }
  }

  // 3. patches.sql
  try {
    await db.exec(patchesSqlRaw);
  } catch (e) {
    console.warn("[pglite] patches.sql 部分失败:", e);
  }

  // 4. 重试失败的迁移
  for (const name of failed) {
    const migration = migrations.find((m) => m.name === name);
    if (!migration) continue;
    try {
      await db.transaction(async (tx) => {
        await tx.exec(migration.sql);
      });
      success++;
    } catch {
      // 仍然失败，忽略
    }
  }

  // 5. seed.sql
  const cleanedSeed = seedSqlRaw.replace(
    /CREATE EXTENSION IF NOT EXISTS pgcrypto[^;]*;/g,
    ""
  );
  try {
    await db.transaction(async (tx) => {
      await tx.exec(cleanedSeed);
    });
  } catch (e) {
    console.warn("[pglite] seed.sql 执行失败:", e);
  }

  console.log(
    `[pglite] 初始化完成: ${success}/${migrations.length} 迁移成功`
  );
}
