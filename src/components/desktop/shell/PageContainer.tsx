import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

export type PageWidth = "reading" | "form" | "editor" | "data" | "full";

const MAX_WIDTH: Record<PageWidth, string> = {
  reading: "max-w-[720px]",
  form: "max-w-[896px]",
  editor: "max-w-[1200px]",
  data: "max-w-[1440px]",
  full: "max-w-none",
};

interface PageContainerProps {
  width?: PageWidth;
  className?: string;
  children?: ReactNode;
}

export default function PageContainer({ width = "data", className, children }: PageContainerProps) {
  const layoutMode = width === "data" ? "h-full min-h-0 flex flex-col" : "";

  return (
    <div
      className={cn(
        "mx-auto w-full px-6 py-5 xl:px-8",
        MAX_WIDTH[width],
        layoutMode,
        className
      )}
    >
      {children}
    </div>
  );
}
