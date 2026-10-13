import type { ReactNode } from "react";
import { Search, X } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

interface FilterBarProps {
  searchValue?: string;
  onSearchChange?: (value: string) => void;
  searchPlaceholder?: string;
  searchWidth?: string;
  activeCount?: number;
  onReset?: () => void;
  right?: ReactNode;
  className?: string;
  children?: ReactNode;
}

export default function FilterBar({
  searchValue,
  onSearchChange,
  searchPlaceholder = "搜索",
  searchWidth = "w-[240px]",
  activeCount = 0,
  onReset,
  right,
  className,
  children,
}: FilterBarProps) {
  return (
    <div className={cn("pc-surface flex flex-wrap items-center gap-2 px-3 py-2", className)}>
      {onSearchChange && (
        <div className={cn("relative", searchWidth)}>
          <Search className="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={searchValue ?? ""}
            onChange={(event) => onSearchChange(event.target.value)}
            placeholder={searchPlaceholder}
            className="h-8 pl-8 text-[13px]"
          />
          {Boolean(searchValue) && (
            <button
              type="button"
              onClick={() => onSearchChange("")}
              className="absolute right-2 top-1/2 -translate-y-1/2 text-muted-foreground transition-colors hover:text-foreground"
              aria-label="清空搜索"
            >
              <X className="h-3.5 w-3.5" />
            </button>
          )}
        </div>
      )}

      {children}

      {activeCount > 0 && onReset && (
        <Button variant="ghost" size="sm" onClick={onReset} className="h-8 px-2 text-xs text-muted-foreground">
          清除 {activeCount} 个筛选
        </Button>
      )}

      {right && <div className="ml-auto flex items-center gap-2">{right}</div>}
    </div>
  );
}
