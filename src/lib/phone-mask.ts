/**
 * 全站统一的客户手机号脱敏格式：
 * 大陆号 → 前三位 + **** + 后四位（如 138****5678）；
 * 国际 E.164（+852/+853/+886 等任何 +国家码 开头）→ 国家码 + **** + 后四位；
 * 非以上格式原样返回（可能已是脱敏串，保持幂等）。
 */
export function maskPhone(phone: string | null | undefined): string {
  if (!phone) return "未绑定";
  const clean = phone.replace("+86", "").replace(/[\s-]/g, "");
  if (/^\+\d{6,15}$/.test(clean)) {
    return `${clean.slice(0, 4)}****${clean.slice(-4)}`;
  }
  const digits = clean.replace(/\D/g, "");
  if (digits.length === 11) {
    return `${digits.slice(0, 3)}****${digits.slice(7)}`;
  }
  if (/^(852\d{8}|853\d{8}|886\d{8,9})$/.test(digits)) {
    return `${digits.slice(0, 3)}****${digits.slice(-4)}`;
  }
  return clean;
}
