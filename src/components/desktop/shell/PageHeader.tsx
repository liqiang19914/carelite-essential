import type { ReactNode } from "react";
import { Link } from "react-router-dom";
import { ChevronRight } from "lucide-react";
import { cn } from "@/lib/utils";

export interface Crumb {
  label: string;
  to?: string;
}

interface PageHeaderProps {
  crumbs?: Crumb[];
  title?: string;
  description?: string;
  actions?: ReactNode;
  meta?: ReactNode;
  tabs?: ReactNode;
  className?: string;
}

export default function PageHeader({
  crumbs = [],
  title = "",
  description,
  actions,
  meta,
  tabs,
  className,
}: PageHeaderProps) {
  return (
    <header className={cn("mb-4", className)}>
      {crumbs.length > 0 && (
        <nav aria-label="面包屑" className="mb-1 flex items-center gap-1 text-xs text-muted-foreground">
          {crumbs.map((crumb, index) => (
            <span key={`${crumb.label}-${index}`} className="flex items-center gap-1">
              {index > 0 && <ChevronRight className="h-3 w-3 opacity-50" />}
              {crumb.to && index < crumbs.length - 1 ? (
                <Link to={crumb.to} className="transition-colors hover:text-foreground">
                  {crumb.label}
                </Link>
              ) : (
                <span className={index === crumbs.length - 1 ? "text-foreground" : undefined}>
                  {crumb.label}
                </span>
              )}
            </span>
          ))}
        </nav>
      )}

      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <div className="flex items-center gap-2.5">
            {title && <h1 className="pc-page-title truncate">{title}</h1>}
            {meta}
          </div>
          {description && <p className="pc-caption mt-1 max-w-2xl">{description}</p>}
        </div>
        {actions && <div className="flex flex-none items-center gap-2">{actions}</div>}
      </div>

      {tabs && <div className="mt-4 border-b border-border">{tabs}</div>}
    </header>
  );
}
