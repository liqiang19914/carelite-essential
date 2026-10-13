/**
 * DeepSeek 直连客户端（开源版）
 * API Key / baseUrl / model 从 system_settings 读取（设置页维护），支持 SSE 流式输出
 */

const DEFAULT_BASE_URL = "https://api.deepseek.com";
const DEFAULT_MODEL = "deepseek-chat";

export interface DeepSeekMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

export interface DeepSeekConfig {
  apiKey: string;
  baseUrl: string;
  model: string;
}

export interface DeepSeekStreamCallbacks {
  onDelta?: (text: string) => void;
  onDone?: (fullText: string) => void;
  onError?: (error: Error) => void;
}

/**
 * 读取 DeepSeek 配置（system_settings 表，key 前缀 deepseek_）
 */
export async function getDeepSeekConfig(): Promise<DeepSeekConfig> {
  const { getDb } = await import("@/lib/pglite-db");
  const db = await getDb();
  const result = await db.query<{ key: string; value: string }>(
    `SELECT key, value FROM system_settings WHERE key IN ('deepseek_api_key', 'deepseek_base_url', 'deepseek_model')`,
  );
  const map: Record<string, string> = {};
  for (const row of result.rows) map[row.key] = row.value ?? "";

  const apiKey = map["deepseek_api_key"]?.trim();
  if (!apiKey) throw new Error("未配置 DeepSeek API Key，请先到设置页配置");

  return {
    apiKey,
    baseUrl: (map["deepseek_base_url"]?.trim() || DEFAULT_BASE_URL).replace(/\/+$/, ""),
    model: map["deepseek_model"]?.trim() || DEFAULT_MODEL,
  };
}

/** baseUrl 兼容：填 https://api.deepseek.com 或 …/v1 均可 */
function chatUrl(baseUrl: string): string {
  const b = baseUrl.replace(/\/+$/, "");
  if (b.endsWith("/chat/completions")) return b;
  if (b.endsWith("/v1")) return `${b}/chat/completions`;
  return `${b}/v1/chat/completions`;
}

interface ChatOptions {
  model?: string;
  temperature?: number;
  maxTokens?: number;
}

async function chatRequest(
  config: DeepSeekConfig,
  messages: DeepSeekMessage[],
  stream: boolean,
  options?: ChatOptions,
): Promise<Response> {
  return fetch(chatUrl(config.baseUrl), {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${config.apiKey}`,
    },
    body: JSON.stringify({
      model: options?.model ?? config.model,
      messages,
      temperature: options?.temperature ?? 0.7,
      max_tokens: options?.maxTokens ?? 4096,
      stream,
    }),
  });
}

async function parseHttpError(resp: Response): Promise<Error> {
  const err = await resp.json().catch(() => ({}));
  return new Error(
    (err as { error?: { message?: string } })?.error?.message ??
      `DeepSeek API 错误（HTTP ${resp.status}）`,
  );
}

/**
 * 非流式调用 DeepSeek（使用数据库配置）
 */
export async function callDeepSeek(
  messages: DeepSeekMessage[],
  options?: ChatOptions,
): Promise<string> {
  const config = await getDeepSeekConfig();
  const resp = await chatRequest(config, messages, false, options);
  if (!resp.ok) throw await parseHttpError(resp);
  const data = await resp.json();
  return (data as { choices?: { message?: { content?: string } }[] }).choices?.[0]?.message?.content ?? "";
}

/**
 * 用显式配置非流式调用（设置页"测试连接"用表单当前值，不读库）
 */
export async function callDeepSeekDirect(
  config: DeepSeekConfig,
  messages: DeepSeekMessage[],
  options?: ChatOptions,
): Promise<string> {
  const resp = await chatRequest(config, messages, false, options);
  if (!resp.ok) throw await parseHttpError(resp);
  const data = await resp.json();
  return (data as { choices?: { message?: { content?: string } }[] }).choices?.[0]?.message?.content ?? "";
}

/**
 * 流式调用 DeepSeek（SSE）
 */
export async function callDeepSeekStream(
  messages: DeepSeekMessage[],
  callbacks: DeepSeekStreamCallbacks,
  options?: ChatOptions,
): Promise<void> {
  const config = await getDeepSeekConfig();
  const resp = await chatRequest(config, messages, true, options);

  if (!resp.ok) {
    const err = await parseHttpError(resp);
    callbacks.onError?.(err);
    throw err;
  }

  const reader = resp.body?.getReader();
  if (!reader) throw new Error("无法读取响应流");

  const decoder = new TextDecoder();
  let buffer = "";
  let fullText = "";

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("data: ")) continue;
        const payload = trimmed.slice(6);
        if (payload === "[DONE]") continue;

        try {
          const evt = JSON.parse(payload) as {
            choices?: { delta?: { content?: string } }[];
          };
          const delta = evt.choices?.[0]?.delta?.content;
          if (delta) {
            fullText += delta;
            callbacks.onDelta?.(delta);
          }
        } catch {
          // 忽略解析失败的行
        }
      }
    }
    callbacks.onDone?.(fullText);
  } catch (e) {
    callbacks.onError?.(e instanceof Error ? e : new Error(String(e)));
  } finally {
    reader.releaseLock();
  }
}

/**
 * 检查 DeepSeek API Key 是否已配置
 */
export async function hasDeepSeekApiKey(): Promise<boolean> {
  try {
    const config = await getDeepSeekConfig();
    return Boolean(config.apiKey);
  } catch {
    return false;
  }
}
