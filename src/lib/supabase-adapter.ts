/**
 * Supabase-compatible adapter backed by PGlite
 *
 * 提供 supabase-js 兼容的 API：from() / auth / rpc() / functions.invoke()
 * 所有数据操作在本地 PGlite (WASM PostgreSQL) 上执行，无需远程 Supabase。
 *
 * 支持的查询链：
 *   .from(table).select(cols).eq(col, val).order(col).limit(n)
 *   .from(table).insert(data).select()
 *   .from(table).update(data).eq(col, val).select()
 *   .from(table).delete().eq(col, val)
 *   .from(table).upsert(data, { onConflict }).select()
 *   .rpc(fn, params)
 *   .auth.signInWithPassword / setSession / signOut / onAuthStateChange / getSession / getUser / updateUser
 */

import { getDb, setCurrentUid } from "./pglite-db";
import bcrypt from "bcryptjs";

// ============================================================================
// 类型定义
// ============================================================================

type QueryResult<T = any> = {
  data: T | null;
  error: { message: string; code?: string } | null;
  count?: number | null;
  status?: number;
};

interface FilterCondition {
  column: string;
  operator: string;
  value: any;
  joiner?: "AND" | "OR";
}

interface OrderClause {
  column: string;
  ascending: boolean;
  nullsFirst?: boolean;
}

export interface AuthSession {
  access_token: string;
  refresh_token: string;
  expires_at?: number;
  user: AuthUser | null;
}

export interface AuthUser {
  id: string;
  email?: string;
  phone?: string;
  aud: string;
  role: string;
  created_at: string;
  app_metadata?: Record<string, any>;
  user_metadata?: Record<string, any>;
}

type AuthStateCallback = (
  event: string,
  session: AuthSession | null
) => void | Promise<void>;

// ============================================================================
// 工具函数
// ============================================================================

function err(message: string, code?: string): NonNullable<QueryResult["error"]> {
  return { message, code };
}

/**
 * 将 Supabase select 列字符串中的 FK hint 解析为 LEFT JOIN
 * 示例: "*, tag:client_tags(id, name, color)" → 主列 + LEFT JOIN
 */
function parseSelectColumns(
  selectStr: string,
  tableName: string
): { columns: string; joins: string[] } {
  const parts = selectStr.split(",").map((p) => p.trim());
  const directCols: string[] = [];
  const joins: string[] = [];

  for (const part of parts) {
    // 匹配 alias:table(col1, col2, ...) 模式
    const fkMatch = part.match(/^(\w+):(\w+)\(([^)]*)\)$/);
    if (fkMatch) {
      const [, alias, fkTable, fkCols] = fkMatch;
      // 约定：主表中的外键列 = alias_id 或 alias去复数_id
      const fkCol = `${alias}_id`;
      joins.push(
        `LEFT JOIN ${fkTable} AS ${alias} ON ${tableName}.${fkCol} = ${alias}.id`
      );
      const cols = fkCols
        .split(",")
        .map((c) => c.trim())
        .filter(Boolean)
        .map((c) => `${alias}.${c}`);
      directCols.push(...cols);
    } else if (part === "*") {
      directCols.push(`${tableName}.*`);
    } else {
      directCols.push(`${tableName}.${part}`);
    }
  }

  return {
    columns: directCols.join(", ") || `${tableName}.*`,
    joins,
  };
}

/**
 * 将值转换为 SQL 字面量（用于不需要参数化的简单场景）
 */
function sqlValue(val: any): string {
  if (val === null || val === undefined) return "NULL";
  if (typeof val === "boolean") return val ? "TRUE" : "FALSE";
  if (typeof val === "number") return String(val);
  if (typeof val === "object") {
    return `'${JSON.stringify(val).replace(/'/g, "''")}'::jsonb`;
  }
  // 字符串
  return `'${String(val).replace(/'/g, "''")}'`;
}

// ============================================================================
// 查询构建器
// ============================================================================

class QueryBuilder<T = any> {
  private table: string;
  private columns: string = "*";
  private selectOpts: { count?: string; head?: boolean } = {};
  private filters: FilterCondition[] = [];
  private orders: OrderClause[] = [];
  private limitN: number | null = null;
  private offsetN: number | null = null;
  private rangeFrom: number | null = null;
  private rangeTo: number | null = null;
  private mode: "select" | "insert" | "update" | "delete" | "upsert" = "select";
  private data: any = null;
  private onConflictCols: string | null = null;
  private singleMode: boolean = false;
  private maybeSingleMode: boolean = false;

  constructor(table: string) {
    this.table = table;
  }

  // --- 链式方法 ---

  select(columns: string = "*", opts?: { count?: string; head?: boolean }): this {
    this.mode = "select";
    this.columns = columns;
    if (opts) this.selectOpts = opts;
    return this;
  }

  insert(data: any): this {
    this.mode = "insert";
    this.data = data;
    return this;
  }

  update(data: any): this {
    this.mode = "update";
    this.data = data;
    return this;
  }

  delete(): this {
    this.mode = "delete";
    return this;
  }

  upsert(data: any, opts?: { onConflict?: string }): this {
    this.mode = "upsert";
    this.data = data;
    if (opts?.onConflict) this.onConflictCols = opts.onConflict;
    return this;
  }

  eq(column: string, value: any): this {
    this.filters.push({ column, operator: "=", value });
    return this;
  }

  neq(column: string, value: any): this {
    this.filters.push({ column, operator: "<>", value });
    return this;
  }

  gt(column: string, value: any): this {
    this.filters.push({ column, operator: ">", value });
    return this;
  }

  gte(column: string, value: any): this {
    this.filters.push({ column, operator: ">=", value });
    return this;
  }

  lt(column: string, value: any): this {
    this.filters.push({ column, operator: "<", value });
    return this;
  }

  lte(column: string, value: any): this {
    this.filters.push({ column, operator: "<=", value });
    return this;
  }

  like(column: string, pattern: string): this {
    this.filters.push({ column, operator: "LIKE", value: pattern });
    return this;
  }

  ilike(column: string, pattern: string): this {
    this.filters.push({ column, operator: "ILIKE", value: pattern });
    return this;
  }

  in(column: string, values: any[]): this {
    this.filters.push({ column, operator: "IN", value: values });
    return this;
  }

  is(column: string, value: any): this {
    if (value === null) {
      this.filters.push({ column, operator: "IS", value: "NULL" });
    } else {
      this.filters.push({ column, operator: "IS", value: "NOT NULL" });
    }
    return this;
  }

  not(column: string, operator: string, value: any): this {
    // 简化：not.eq(x) → <>, not.in(x) → NOT IN
    const opMap: Record<string, string> = {
      eq: "<>",
      gt: "<=",
      gte: "<",
      lt: ">=",
      lte: ">",
      like: "NOT LIKE",
      ilike: "NOT ILIKE",
      in: "NOT IN",
    };
    const op = opMap[operator] || operator;
    this.filters.push({ column, operator: op, value });
    return this;
  }

  or(conditions: string): this {
    // 简化的 OR 支持：格式 "col1.eq.val,col2.eq.val"
    // 转换为 OR 子句
    this.filters.push({
      column: "__or__",
      operator: "OR",
      value: conditions,
    });
    return this;
  }

  filter(column: string, operator: string, value: any): this {
    this.filters.push({ column, operator, value });
    return this;
  }

  order(column: string, opts?: { ascending?: boolean; nullsFirst?: boolean }): this {
    this.orders.push({
      column,
      ascending: opts?.ascending ?? true,
      nullsFirst: opts?.nullsFirst,
    });
    return this;
  }

  limit(n: number): this {
    this.limitN = n;
    return this;
  }

  range(from: number, to: number): this {
    this.rangeFrom = from;
    this.rangeTo = to;
    return this;
  }

  single(): this {
    this.singleMode = true;
    return this;
  }

  maybeSingle(): this {
    this.maybeSingleMode = true;
    return this;
  }

  // --- SQL 生成 ---

  private buildWhereClause(): string {
    if (this.filters.length === 0) return "";

    const clauses = this.filters.map((f) => {
      if (f.operator === "OR") {
        // 解析 "col1.eq.val,col2.eq.val" → col1 = 'val' OR col2 = 'val'
        const parts = f.value.split(",").map((p: string) => {
          const [col, op, ...valParts] = p.split(".");
          const val = valParts.join(".");
          const opMap: Record<string, string> = {
            eq: "=",
            neq: "<>",
            gt: ">",
            gte: ">=",
            lt: "<",
            lte: "<=",
          };
          const sqlOp = opMap[op] || "=";
          return `${col} ${sqlOp} ${sqlValue(val)}`;
        });
        return `(${parts.join(" OR ")})`;
      }

      if (f.operator === "IN") {
        const vals = (f.value as any[]).map((v) => sqlValue(v)).join(", ");
        return `${f.column} IN (${vals})`;
      }

      if (f.operator === "IS") {
        return `${f.column} IS ${f.value}`;
      }

      return `${f.column} ${f.operator} ${sqlValue(f.value)}`;
    });

    return "WHERE " + clauses.join(" AND ");
  }

  private buildOrderClause(): string {
    if (this.orders.length === 0) return "";
    const parts = this.orders.map(
      (o) =>
        `${o.column} ${o.ascending ? "ASC" : "DESC"}` +
        (o.nullsFirst !== undefined
          ? ` NULLS ${o.nullsFirst ? "FIRST" : "LAST"}`
          : "")
    );
    return "ORDER BY " + parts.join(", ");
  }

  private buildLimitClause(): string {
    if (this.rangeFrom !== null && this.rangeTo !== null) {
      const limit = this.rangeTo - this.rangeFrom + 1;
      return `LIMIT ${limit} OFFSET ${this.rangeFrom}`;
    }
    if (this.limitN !== null) return `LIMIT ${this.limitN}`;
    if (this.singleMode || this.maybeSingleMode) return "LIMIT 1";
    return "";
  }

  private async execute(): Promise<QueryResult<T>> {
    const db = await getDb();
    const where = this.buildWhereClause();
    const order = this.buildOrderClause();
    const limit = this.buildLimitClause();

    try {
      if (this.mode === "select") {
        // COUNT 模式
        if (this.selectOpts.head && this.selectOpts.count) {
          const countSql = `SELECT count(*) as cnt FROM ${this.table} ${where}`;
          const countResult = await db.query(countSql);
          return {
            data: null,
            error: null,
            count: Number(countResult.rows[0]?.cnt ?? 0),
            status: 200,
          };
        }

        // 普通 SELECT
        const { columns, joins } = parseSelectColumns(
          this.columns,
          this.table
        );
        const joinClause = joins.length > 0 ? joins.join(" ") : "";
        const sql = `SELECT ${columns} FROM ${this.table} ${joinClause} ${where} ${order} ${limit}`.trim();

        const result = await db.query(sql);
        let rows = result.rows as T[];

        // 如果有 count 选项，额外查一次总数
        let count: number | null = null;
        if (this.selectOpts.count) {
          const countSql = `SELECT count(*) as cnt FROM ${this.table} ${where}`;
          const countResult = await db.query(countSql);
          count = Number(countResult.rows[0]?.cnt ?? 0);
        }

        if (this.singleMode) {
          if (rows.length === 0) {
            return { data: null, error: err("未找到记录", "PGRST116"), status: 406 };
          }
          return { data: rows[0], error: null, count, status: 200 };
        }

        if (this.maybeSingleMode) {
          return { data: rows[0] ?? null, error: null, count, status: 200 };
        }

        return { data: rows, error: null, count, status: 200 };
      }

      if (this.mode === "insert" || this.mode === "upsert") {
        const records = Array.isArray(this.data) ? this.data : [this.data];
        if (records.length === 0) {
          return { data: [] as any, error: null, status: 201 };
        }

        const columns = Object.keys(records[0]);
        const valuesRows = records.map((rec: any) => {
          return `(${columns.map((c) => sqlValue(rec[c])).join(", ")})`;
        });

        let conflictClause = "";
        if (this.mode === "upsert" && this.onConflictCols) {
          conflictClause = `ON CONFLICT (${this.onConflictCols}) DO UPDATE SET `;
          conflictClause += columns
            .filter((c) => c !== this.onConflictCols)
            .map((c) => `${c} = EXCLUDED.${c}`)
            .join(", ");
        }

        const sql = `INSERT INTO ${this.table} (${columns.join(", ")}) VALUES ${valuesRows.join(", ")} ${conflictClause} RETURNING *`.trim();

        const result = await db.query(sql);
        const rows = result.rows as T[];

        if (this.singleMode || this.maybeSingleMode) {
          return { data: rows[0] ?? null, error: null, status: 201 };
        }
        return { data: rows, error: null, status: 201 };
      }

      if (this.mode === "update") {
        const setClauses = Object.entries(this.data).map(
          ([col, val]) => `${col} = ${sqlValue(val)}`
        );
        const sql = `UPDATE ${this.table} SET ${setClauses.join(", ")} ${where} RETURNING *`.trim();

        const result = await db.query(sql);
        const rows = result.rows as T[];

        if (this.singleMode || this.maybeSingleMode) {
          return { data: rows[0] ?? null, error: null, status: 200 };
        }
        return { data: rows, error: null, status: 200 };
      }

      if (this.mode === "delete") {
        const sql = `DELETE FROM ${this.table} ${where} RETURNING *`.trim();
        const result = await db.query(sql);
        const rows = result.rows as T[];

        if (this.singleMode || this.maybeSingleMode) {
          return { data: rows[0] ?? null, error: null, status: 200 };
        }
        return { data: rows, error: null, status: 200 };
      }

      return { data: null, error: err("未知操作模式"), status: 400 };
    } catch (e: any) {
      return { data: null, error: err(e.message), status: 400 };
    }
  }

  // --- Thenable（让 await builder 工作）---

  then<TResult1 = QueryResult<T>>(
    onResolve?:
      | ((value: QueryResult<T>) => TResult1 | PromiseLike<TResult1>)
      | null,
    onReject?: ((reason: any) => any | PromiseLike<any>) | null
  ): PromiseLike<TResult1> {
    return this.execute().then(onResolve, onReject);
  }
}

// ============================================================================
// Auth 适配器
// ============================================================================

class AuthAdapter {
  private currentSession: AuthSession | null = null;
  private listeners: Set<AuthStateCallback> = new Set();
  private sessionKey = "carelite_essential_session";

  constructor() {
    // 从 localStorage 恢复会话
    this.restoreSession();
  }

  private restoreSession() {
    try {
      const saved = localStorage.getItem(this.sessionKey);
      if (saved) {
        this.currentSession = JSON.parse(saved);
        if (this.currentSession?.user) {
          // 异步设置 DB 中的 current_uid
          getDb().then((db) => setCurrentUid(db, this.currentSession!.user!.id));
        }
      }
    } catch {
      // 忽略恢复失败
    }
  }

  private emitEvent(event: string, session: AuthSession | null) {
    this.listeners.forEach((cb) => {
      setTimeout(() => cb(event, session), 0);
    });
  }

  private async saveSession(session: AuthSession | null) {
    this.currentSession = session;
    if (session) {
      localStorage.setItem(this.sessionKey, JSON.stringify(session));
      if (session.user) {
        const db = await getDb();
        await setCurrentUid(db, session.user.id);
      }
    } else {
      localStorage.removeItem(this.sessionKey);
      const db = await getDb();
      await setCurrentUid(db, "");
    }
  }

  /**
   * 密码登录
   * 支持 email 或 phone 模式
   */
  async signInWithPassword(params: {
    email?: string;
    phone?: string;
    password: string;
  }): Promise<QueryResult<{ user: AuthUser | null; session: AuthSession | null }>> {
    const db = await getDb();
    const identifier = params.email || params.phone;
    if (!identifier) {
      return { data: { user: null, session: null }, error: err("请提供邮箱或手机号") };
    }

    // 查询 auth.users
    const isEmail = !!params.email;
    const col = isEmail ? "email" : "phone";
    const result = await db.query(
      `SELECT id, email, phone, encrypted_password, raw_user_meta_data, created_at, aud, role FROM auth.users WHERE ${col} = $1 LIMIT 1`,
      [identifier]
    );

    if (result.rows.length === 0) {
      return { data: { user: null, session: null }, error: err("账号不存在") };
    }

    const userRow = result.rows[0] as any;

    // 验证密码：使用 bcryptjs 验证
    let passwordValid = false;
    try {
      passwordValid = await bcrypt.compare(
        params.password,
        userRow.encrypted_password
      );
    } catch {
      // 如果不是 bcrypt 格式，尝试直接比较（兼容 seed 数据中可能使用 crypt 的格式）
      passwordValid = false;
    }

    if (!passwordValid) {
      return { data: { user: null, session: null }, error: err("密码错误") };
    }

    // 构造用户对象
    const user: AuthUser = {
      id: userRow.id,
      email: userRow.email,
      phone: userRow.phone,
      aud: userRow.aud || "authenticated",
      role: userRow.role || "authenticated",
      created_at: userRow.created_at,
      user_metadata: userRow.raw_user_meta_data || {},
      app_metadata: {},
    };

    // 构造会话（本地模式：使用 uuid 作为 token）
    const session: AuthSession = {
      access_token: `local_${crypto.randomUUID()}`,
      refresh_token: `local_${crypto.randomUUID()}`,
      expires_at: Date.now() + 7 * 24 * 60 * 60 * 1000, // 7 天后
      user,
    };

    await this.saveSession(session);
    this.emitEvent("SIGNED_IN", session);

    return { data: { user, session }, error: null };
  }

  /**
   * 设置会话（关联账号互跳）
   * 本地模式：access_token 格式为 local_{uuid}，通过它查找对应的用户
   * 如果是外部 token（如小程序 mp_token），则直接忽略（本地模式不需要）
   */
  async setSession(credentials: {
    access_token: string;
    refresh_token: string;
  }): Promise<QueryResult<{ user: AuthUser | null; session: AuthSession | null }>> {
    // 如果已经有当前会话且 token 匹配，直接返回
    if (
      this.currentSession &&
      this.currentSession.access_token === credentials.access_token
    ) {
      return { data: { user: this.currentSession.user, session: this.currentSession }, error: null };
    }

    // 本地模式：尝试从已保存的会话列表中查找
    // 实际上本地模式中 setSession 主要用于关联账号互跳，
    // 此时 access_token 应该是另一个本地用户的 token
    // 简化处理：如果找不到，返回错误
    return {
      data: { user: null, session: null },
      error: err("本地模式下不支持外部会话设置"),
    };
  }

  /**
   * 退出登录
   */
  async signOut(opts?: { scope?: string }): Promise<{ error: any }> {
    await this.saveSession(null);
    this.emitEvent("SIGNED_OUT", null);
    return { error: null };
  }

  /**
   * 获取当前会话
   */
  async getSession(): Promise<QueryResult<{ session: AuthSession | null }>> {
    return { data: { session: this.currentSession }, error: null, status: 200 };
  }

  /**
   * 获取当前用户
   */
  async getUser(): Promise<QueryResult<{ user: AuthUser | null }>> {
    return { data: { user: this.currentSession?.user ?? null }, error: null, status: 200 };
  }

  /**
   * 更新用户信息（密码修改等）
   */
  async updateUser(attrs: { password?: string }): Promise<QueryResult<{ user: AuthUser | null }>> {
    if (!this.currentSession?.user) {
      return { data: { user: null }, error: err("未登录") };
    }

    if (attrs.password) {
      const db = await getDb();
      const hashed = await bcrypt.hash(attrs.password, 10);
      await db.query(
        `UPDATE auth.users SET encrypted_password = $1 WHERE id = $2`,
        [hashed, this.currentSession.user.id]
      );
    }

    return { data: { user: this.currentSession.user }, error: null };
  }

  /**
   * 刷新会话（本地模式直接返回当前会话）
   */
  async refreshSession(): Promise<QueryResult<{ user: AuthUser | null; session: AuthSession | null }>> {
    return { data: { user: this.currentSession?.user ?? null, session: this.currentSession }, error: null };
  }

  /**
   * 订阅认证状态变化
   */
  onAuthStateChange(
    callback: AuthStateCallback
  ): { data: { subscription: { unsubscribe: () => void } } } {
    this.listeners.add(callback);

    // 触发 INITIAL_SESSION 事件
    setTimeout(() => {
      callback("INITIAL_SESSION", this.currentSession);
    }, 0);

    return {
      data: {
        subscription: {
          unsubscribe: () => {
            this.listeners.delete(callback);
          },
        },
      },
    };
  }
}

// ============================================================================
// RPC 适配器
// ============================================================================

async function rpc<T = any>(
  fnName: string,
  params?: Record<string, any>
): Promise<QueryResult<T>> {
  const db = await getDb();

  try {
    // 将命名参数转换为位置参数
    const keys = params ? Object.keys(params) : [];
    const values = keys.map((k) => params![k]);

    // 使用命名参数语法：SELECT * FROM fn(p_name => $1, ...)
    // PGlite/PostgreSQL 支持命名参数调用
    let sql: string;
    if (keys.length > 0) {
      const paramList = keys.map((k, i) => `${k} => $${i + 1}`).join(", ");
      sql = `SELECT * FROM ${fnName}(${paramList})`;
    } else {
      sql = `SELECT * FROM ${fnName}()`;
    }

    const result = await db.query(sql, values.length > 0 ? values : undefined);
    return { data: result.rows as T, error: null, status: 200 };
  } catch (e: any) {
    return { data: null, error: err(e.message), status: 400 };
  }
}

// ============================================================================
// functions.invoke 适配器
// ============================================================================

// Edge Function 本地处理器注册表
type FunctionHandler = (
  body: any,
  headers?: Record<string, string>
) => Promise<any>;

const functionHandlers: Map<string, FunctionHandler> = new Map();

/**
 * 注册 Edge Function 本地处理器
 * 用于替代 supabase.functions.invoke 的远程调用
 */
export function registerFunctionHandler(
  name: string,
  handler: FunctionHandler
) {
  functionHandlers.set(name, handler);
}

/**
 * 调用 Edge Function（本地处理器）
 * 如果没有注册对应的处理器，返回错误
 */
async function invokeFunction(
  name: string,
  opts: { body?: any; headers?: Record<string, string> }
): Promise<QueryResult<any>> {
  const handler = functionHandlers.get(name);
  if (!handler) {
    return {
      data: null,
      error: err(`Edge Function '${name}' 无本地处理器`),
      status: 404,
    };
  }

  try {
    const result = await handler(opts.body, opts.headers);
    return { data: result, error: null, status: 200 };
  } catch (e: any) {
    return { data: null, error: err(e.message), status: 500 };
  }
}

// ============================================================================
// 导出：Supabase 兼容对象
// ============================================================================

const authAdapter = new AuthAdapter();

/**
 * 本地 Supabase 兼容适配器
 *
 * 用法与 supabase-js 完全一致：
 *   import { supabase } from "@/integrations/supabase/client";
 *   const { data } = await supabase.from("profiles").select("*").eq("id", uid).single();
 */
export const localSupabase = {
  from: <T = any>(table: string) => new QueryBuilder<T>(table),

  auth: authAdapter,

  rpc,

  functions: {
    invoke: invokeFunction,
  },

  channel: () => ({
    on: () => ({ subscribe: () => ({ unsubscribe: () => {} }) }),
    subscribe: () => ({ unsubscribe: () => {} }),
  }),

  storage: {
    from: () => ({
      upload: async () => ({ data: null, error: err("本地模式不支持文件上传") }),
      download: async () => ({ data: null, error: err("本地模式不支持文件下载") }),
      createSignedUrl: async () => ({ data: null, error: err("本地模式不支持签名 URL") }),
      getPublicUrl: () => ({ data: { publicUrl: "" } }),
    }),
  },
};

export type LocalSupabase = typeof localSupabase;
