import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

interface FieldGridProps {
  cols?: 1 | 2 | 3;
  className?: string;
  children?: ReactNode;
}

const COLS_CLASS: Record<number, string> = {
  1: "",
  2: "lg:grid-cols-2",
  3: "lg:grid-cols-3",
};

export function FieldGrid({ cols = 2, className, children }: FieldGridProps) {
  return (
    <div className={cn("grid grid-cols-1 gap-x-4 gap-y-4", COLS_CLASS[cols], className)}>{children}</div>
  );
}

interface FieldProps {
  label?: ReactNode;
  htmlFor?: string;
  hint?: string;
  error?: string;
  required?: boolean;
  span?: 1 | 2 | 3 | "full";
  action?: ReactNode;
  className?: string;
  children?: ReactNode;
}

const SPAN_CLASS: Record<string, string> = {
  1: "",
  2: "lg:col-span-2",
  3: "lg:col-span-3",
  full: "lg:col-span-full",
};

export function Field({
  label,
  htmlFor,
  hint,
  error,
  required = false,
  span = 1,
  action,
  className,
  children,
}: FieldProps) {
  return (
    <div className={cn("min-w-0", SPAN_CLASS[String(span)], className)}>
      {(label || action) && (
        <div className="flex items-center justify-between gap-2">
          {label && (
            <label htmlFor={htmlFor} className="pc-field-label">
              {label}
              {required && <span className="ml-0.5 text-destructive">*</span>}
            </label>
          )}
          {action}
        </div>
      )}
      <div className="mt-1.5">{children}</div>
      {error ? (
        <p className="mt-1 text-xs text-destructive">{error}</p>
      ) : (
        hint && <p className="pc-caption mt-1">{hint}</p>
      )}
    </div>
  );
}

export default FieldGrid;
