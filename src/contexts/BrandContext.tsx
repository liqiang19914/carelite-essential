/**
 * BrandContext — 开源版静态品牌上下文
 *
 * 直接读 src/config/brand.ts 静态常量，不依赖 OEM 白牌 / 平台后台配置 / sessionStorage。
 * 二开时改 src/config/brand.ts 即可替换品牌名 / 标语 / 版本。
 */

import { createContext, useContext, type ReactNode } from "react";
import { brand, type Brand } from "@/config/brand";

interface BrandContextValue extends Brand {
  /** 兼容字段：原 HMS 的 BrandContextValue.brandName 等；开源版直接复用 brand.name */
  brandName: string;
  aiAgentName: string;
  brandFullName: string;
  supportContact: string;
  brandPrimaryColor: string;
  documentBrandTitle: string;
  refreshBrand: () => Promise<void>;
}

const BrandContext = createContext<BrandContextValue | undefined>(undefined);

interface BrandProviderProps {
  children: ReactNode;
}

function toValue(): BrandContextValue {
  return {
    ...brand,
    brandName: brand.name,
    aiAgentName: brand.name,
    brandFullName: brand.name,
    supportContact: "",
    brandPrimaryColor: "#f97316", // Tailwind orange-500，与 HMS 默认主色一致
    documentBrandTitle: brand.name,
    refreshBrand: async () => {
      /* 静态品牌无需刷新 */
    },
  };
}

export function BrandProvider({ children }: BrandProviderProps) {
  const value = toValue();
  return <BrandContext.Provider value={value}>{children}</BrandContext.Provider>;
}

const BRAND_FALLBACK: BrandContextValue = {
  ...toValue(),
};

export function useBrand(): BrandContextValue {
  const ctx = useContext(BrandContext);
  if (ctx === undefined) return BRAND_FALLBACK;
  return ctx;
}
