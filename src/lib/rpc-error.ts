const HAS_CHINESE = /[一-龥]/;

/**
 * 把后端抛出的错误转成可以直接放在界面上的中文。
 */
export function rpcErrorMessage(error: unknown, fallback: string): string {
  const raw =
    typeof error === "string"
      ? error
      : ((error as { message?: string } | null)?.message ?? "");

  if (raw && HAS_CHINESE.test(raw)) return raw;

  if (raw) console.warn("[rpc]", raw, error);
  return fallback;
}
