import type { ReactNode } from "react";
import type { LucideIcon } from "lucide-react";
import { cn } from "@/lib/utils";

export type StatusTone = "neutral" | "primary" | "success" | "warning" | "danger" | "info";

const TONE_CLASS: Record<StatusTone, string> = {
  neutral: "pc-badge-neutral",
  primary: "pc-badge-primary",
  success: "pc-badge-success",
  warning: "pc-badge-warning",
  danger: "pc-badge-danger",
  info: "pc-badge-info",
};

interface StatusBadgeProps {
  tone?: StatusTone;
  label?: ReactNode;
  icon?: LucideIcon;
  dot?: boolean;
  className?: string;
}

export default function StatusBadge({
  tone = "neutral",
  label,
  icon: Icon,
  dot = false,
  className,
}: StatusBadgeProps) {
  return (
    <span className={cn("pc-badge", TONE_CLASS[tone], className)}>
      {dot && <span className="h-1.5 w-1.5 rounded-full bg-current opacity-70" />}
      {Icon && <Icon className="h-3 w-3" />}
      {label}
    </span>
  );
}
