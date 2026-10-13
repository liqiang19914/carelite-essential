import { useState } from "react";
import { ChevronLeft, ChevronRight, ChevronsLeft, ChevronsRight } from "lucide-react";
import {
  Pagination,
  PaginationContent,
  PaginationEllipsis,
  PaginationItem,
  PaginationLink,
} from "@/components/ui/pagination";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { cn } from "@/lib/utils";

interface ListPaginationProps {
  page?: number;
  totalPages?: number;
  onPageChange?: (page: number) => void;
  /** 总条数；传入后默认显示「共 X 条 · 第 X/Y 页」 */
  total?: number;
  /** 每页条数（仅用于展示） */
  pageSize?: number;
  /** 是否显示总数行（默认 total !== undefined 时显示） */
  showTotal?: boolean;
  /** 已废弃：首页/末页可由页码区的「1」「末页号」直达，不再单列按钮（保留入参兼容旧调用） */
  showFirstLast?: boolean;
  /** 紧凑模式（移动端）：显示首页/上一页/第X/Y页/下一页/末页 */
  compact?: boolean;
  /** 每页条数选项；传入后显示「每页 X 条」选择器 */
  pageSizeOptions?: number[];
  /** 每页条数变化回调（切条数时调用方负责回到第一页） */
  onPageSizeChange?: (pageSize: number) => void;
  /** 是否显示「跳到第 X 页」（桌面端为内联小输入框，回车/失焦即跳） */
  showPageJump?: boolean;
}

function getPageNumbers(page: number, totalPages: number): (number | "ellipsis")[] {
  if (totalPages <= 7) {
    return Array.from({ length: totalPages }, (_, i) => i + 1);
  }
  const candidates = new Set<number>([1, totalPages, page - 1, page, page + 1]);
  const sorted = Array.from(candidates)
    .filter((p) => p >= 1 && p <= totalPages)
    .sort((a, b) => a - b);

  const result: (number | "ellipsis")[] = [];
  sorted.forEach((p, idx) => {
    if (idx > 0 && p - sorted[idx - 1] > 1) {
      result.push("ellipsis");
    }
    result.push(p);
  });
  return result;
}

/**
 * 桌面端分页条：一整行、不换行——左侧总数，右侧「每页条数 + 页码 + 跳页」。
 * 首页/末页不再单列按钮：页码区的「1」「末页号」本身就能直达；上一页/下一页用纯图标。
 * 移动端 compact 模式保留独立的图标导航。
 */
export default function ListPagination({
  page = 1,
  totalPages = 1,
  onPageChange = () => {},
  total,
  pageSize,
  showTotal,
  compact = false,
  pageSizeOptions,
  onPageSizeChange,
  showPageJump = false,
}: ListPaginationProps) {
  const [jumpValue, setJumpValue] = useState("");

  if (totalPages <= 1 && !pageSizeOptions?.length) return null;

  const showTotalText = showTotal ?? total !== undefined;

  const commitJump = () => {
    const n = parseInt(jumpValue, 10);
    if (!Number.isNaN(n) && n >= 1 && n <= totalPages && n !== page) {
      onPageChange(n);
    }
    setJumpValue("");
  };

  const linkCls = (disabled: boolean) =>
    cn("h-7 w-7 p-0 text-xs text-muted-foreground", disabled && "pointer-events-none opacity-40");

  if (compact) {
    return (
      <Pagination>
        <PaginationContent className="gap-0.5">
          <PaginationItem>
            <PaginationLink href="#" aria-label="首页" className={cn("px-2", page <= 1 && "pointer-events-none opacity-50")}
              onClick={(e) => { e.preventDefault(); if (page > 1) onPageChange(1); }}>
              <ChevronsLeft className="h-4 w-4" />
            </PaginationLink>
          </PaginationItem>
          <PaginationItem>
            <PaginationLink href="#" aria-label="上一页" className={cn("px-2", page <= 1 && "pointer-events-none opacity-50")}
              onClick={(e) => { e.preventDefault(); if (page > 1) onPageChange(page - 1); }}>
              <ChevronLeft className="h-4 w-4" />
            </PaginationLink>
          </PaginationItem>
          <PaginationItem>
            <span className="px-2 text-xs text-muted-foreground">第 {page}/{totalPages} 页</span>
          </PaginationItem>
          <PaginationItem>
            <PaginationLink href="#" aria-label="下一页" className={cn("px-2", page >= totalPages && "pointer-events-none opacity-50")}
              onClick={(e) => { e.preventDefault(); if (page < totalPages) onPageChange(page + 1); }}>
              <ChevronRight className="h-4 w-4" />
            </PaginationLink>
          </PaginationItem>
          <PaginationItem>
            <PaginationLink href="#" aria-label="末页" className={cn("px-2", page >= totalPages && "pointer-events-none opacity-50")}
              onClick={(e) => { e.preventDefault(); if (page < totalPages) onPageChange(totalPages); }}>
              <ChevronsRight className="h-4 w-4" />
            </PaginationLink>
          </PaginationItem>
        </PaginationContent>
      </Pagination>
    );
  }

  // 页码 + 上一页/下一页（纯图标，紧凑 h-7）
  const control = (
    <Pagination className="w-auto">
      <PaginationContent className="gap-0.5">
        <PaginationItem>
          <PaginationLink
            href="#"
            aria-label="上一页"
            className={linkCls(page <= 1)}
            onClick={(e) => {
              e.preventDefault();
              if (page > 1) onPageChange(page - 1);
            }}
          >
            <ChevronLeft className="h-3.5 w-3.5" />
          </PaginationLink>
        </PaginationItem>
        {getPageNumbers(page, totalPages).map((p, idx) =>
          p === "ellipsis" ? (
            <PaginationItem key={`ellipsis-${idx}`}>
              <PaginationEllipsis className="h-7 w-7 text-muted-foreground" />
            </PaginationItem>
          ) : (
            <PaginationItem key={p}>
              <PaginationLink
                href="#"
                isActive={p === page}
                onClick={(e) => {
                  e.preventDefault();
                  onPageChange(p);
                }}
                className={cn(
                  "h-7 min-w-7 px-1.5 text-xs",
                  p === page && "border-primary/40 bg-primary/10 font-medium text-primary",
                )}
              >
                {p}
              </PaginationLink>
            </PaginationItem>
          ),
        )}
        <PaginationItem>
          <PaginationLink
            href="#"
            aria-label="下一页"
            className={linkCls(page >= totalPages)}
            onClick={(e) => {
              e.preventDefault();
              if (page < totalPages) onPageChange(page + 1);
            }}
          >
            <ChevronRight className="h-3.5 w-3.5" />
          </PaginationLink>
        </PaginationItem>
      </PaginationContent>
    </Pagination>
  );

  const sizeControl = pageSizeOptions?.length ? (
    <Select
      value={String(pageSize ?? pageSizeOptions[0])}
      onValueChange={(v) => {
        const n = Number(v);
        if (Number.isFinite(n) && n !== pageSize) onPageSizeChange?.(n);
      }}
    >
      <SelectTrigger className="h-7 w-[74px] gap-1 px-2 text-xs" aria-label="每页条数">
        <SelectValue placeholder={`${pageSize ?? pageSizeOptions[0]}`} />
      </SelectTrigger>
      <SelectContent>
        {pageSizeOptions.map((n) => (
          <SelectItem key={n} value={String(n)}>
            {n} 条/页
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  ) : null;

  const jumpControl = showPageJump && totalPages > 1 ? (
    <div className="flex items-center gap-1.5 text-xs text-muted-foreground">
      <span>到</span>
      <input
        type="text"
        inputMode="numeric"
        aria-label="跳转页码"
        value={jumpValue}
        onChange={(e) => setJumpValue(e.target.value.replace(/[^0-9]/g, "").slice(0, 4))}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            commitJump();
          }
        }}
        onBlur={commitJump}
        className="h-7 w-9 rounded border border-input bg-background px-1 text-center text-xs"
      />
      <span>页</span>
    </div>
  ) : null;

  // 一整行：左侧总数，右侧 条数 / 页码 / 跳页
  return (
    <div className="flex items-center justify-between gap-3 px-1 text-xs text-muted-foreground">
      <div className="min-w-0 shrink-0">
        {showTotalText && (
          <span className="whitespace-nowrap">
            共 <span className="pc-num text-foreground">{total}</span> 条 · 第{" "}
            <span className="pc-num text-foreground">{page}</span>/{totalPages} 页
          </span>
        )}
      </div>
      <div className="flex items-center gap-3 whitespace-nowrap">
        {sizeControl}
        {control}
        {jumpControl}
      </div>
    </div>
  );
}

