import type { ReactNode } from "react";
import { X } from "lucide-react";
import { cn } from "@/lib/utils";

interface BulkActionBarProps {
  count?: number;
  noun?: string;
  onClear?: () => void;
  className?: string;
  children?: ReactNode;
}

export default function BulkActionBar({
  count = 0,
  noun = "项",
  onClear,
  className,
  children,
}: BulkActionBarProps) {
  if (count <= 0) return null;

  return (
    <div
      className={cn(
        "animate-fade-up fixed bottom-6 left-1/2 z-40 flex -translate-x-1/2 items-center gap-3 rounded-full border border-border bg-card px-4 py-2 shadow-xl",
        className,
      )}
    >
      <span className="pc-body whitespace-nowrap">
        已选 <span className="pc-num font-semibold text-primary">{count}</span> {noun}
      </span>
      <span className="h-4 w-px bg-border" />
      <div className="flex items-center gap-1.5">{children}</div>
      {onClear && (
        <button
          type="button"
          onClick={onClear}
          className="ml-1 rounded-full p-1 text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
          aria-label="取消选择"
        >
          <X className="h-3.5 w-3.5" />
        </button>
      )}
    </div>
  );
}
