/**
 * 品牌静态常量
 *
 * 二开时修改此处即可替换品牌名 / 标语 / 版本。
 */
export const brand = {
  name: "CareLite-Essential",
  tagline: "健康师本地 AI 工作站",
  version: "0.1.0",
} as const;

export type Brand = typeof brand;
