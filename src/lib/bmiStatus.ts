import type { BmiStatus } from "@/types/app/bmiStatus";

export interface BmiMeta {
  label: string;
  className: string;
}

export const BMI_META: Record<Exclude<BmiStatus, null>, BmiMeta> = {
  underweight: { label: "偏瘦", className: "bg-blue-500/10 text-blue-600" },
  normal: { label: "正常", className: "bg-emerald-500/10 text-emerald-600" },
  overweight: { label: "超重", className: "bg-amber-500/10 text-amber-600" },
  obese: { label: "肥胖", className: "bg-red-500/10 text-red-600" },
  no_data: { label: "无数据", className: "bg-muted text-muted-foreground" },
};

export const BMI_FILTER_OPTIONS: { value: Exclude<BmiStatus, null>; label: string }[] = [
  { value: "underweight", label: "偏瘦" },
  { value: "normal", label: "正常" },
  { value: "overweight", label: "超重" },
  { value: "obese", label: "肥胖" },
  { value: "no_data", label: "无数据" },
];

export function bmiMeta(status: BmiStatus): BmiMeta | null {
  if (!status) return null;
  return BMI_META[status];
}

/**
 * 由身高(cm)与体重(kg)推算 BMI 状态
 */
export function calcBmiStatus(heightCm: number | null, weightKg: number | null): BmiStatus {
  if (!heightCm || !weightKg || heightCm <= 0 || weightKg <= 0) return "no_data";
  const bmi = weightKg / Math.pow(heightCm / 100, 2);
  if (bmi < 18.5) return "underweight";
  if (bmi < 24) return "normal";
  if (bmi < 28) return "overweight";
  return "obese";
}
