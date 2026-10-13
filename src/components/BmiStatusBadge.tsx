import type { BmiStatus } from "@/types/app/bmiStatus";
import { bmiMeta } from "@/lib/bmiStatus";
import { cn } from "@/lib/utils";

interface Props {
  status?: BmiStatus;
  small?: boolean;
}

export default function BmiStatusBadge({ status = null, small = false }: Props) {
  const meta = bmiMeta(status);
  if (!meta) return null;
  return (
    <span
      className={cn(
        "inline-flex shrink-0 items-center rounded px-1.5 font-medium",
        small ? "text-[10px] leading-4" : "text-xs leading-5",
        meta.className,
      )}
    >
      {meta.label}
    </span>
  );
}
