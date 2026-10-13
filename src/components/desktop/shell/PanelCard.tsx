import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

interface PanelCardProps {
  title?: ReactNode;
  description?: string;
  action?: ReactNode;
  footer?: ReactNode;
  padded?: boolean;
  className?: string;
  bodyClassName?: string;
  children?: ReactNode;
}

export default function PanelCard({
  title,
  description,
  action,
  footer,
  padded = true,
  className,
  bodyClassName,
  children,
}: PanelCardProps) {
  return (
    <section className={cn("pc-surface flex flex-col overflow-hidden", className)}>
      {(title || action) && (
        <header className="flex items-start justify-between gap-3 border-b border-border px-4 py-2.5">
          <div className="min-w-0">
            {title && <h2 className="pc-section-title truncate">{title}</h2>}
            {description && <p className="pc-caption mt-0.5">{description}</p>}
          </div>
          {action && <div className="flex flex-none items-center gap-2">{action}</div>}
        </header>
      )}
      <div className={cn("min-w-0 flex-1", padded && "p-4", bodyClassName)}>{children}</div>
      {footer && <footer className="border-t border-border px-4 py-3">{footer}</footer>}
    </section>
  );
}
