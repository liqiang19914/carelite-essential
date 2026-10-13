import { useMemo, useState, type ReactNode } from "react";
import { ArrowDown, ArrowUp, ChevronsUpDown } from "lucide-react";
import { Checkbox } from "@/components/ui/checkbox";
import { TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { cn } from "@/lib/utils";

export interface DataTableColumn<T> {
  key: string;
  header?: ReactNode;
  cell?: (row: T, index: number) => ReactNode;
  sortable?: boolean;
  sortValue?: (row: T) => string | number | null | undefined;
  align?: "left" | "center" | "right";
  width?: string;
  headClassName?: string;
  cellClassName?: string;
  sticky?: "left";
}

interface DataTableProps<T> {
  columns?: DataTableColumn<T>[];
  rows?: T[];
  rowKey?: (row: T, index: number) => string;
  loading?: boolean;
  emptyText?: string;
  emptySlot?: ReactNode;
  selectable?: boolean;
  selectedKeys?: string[];
  onToggleRow?: (key: string, row: T) => void;
  onToggleAll?: () => void;
  allSelected?: boolean;
  someSelected?: boolean;
  activeKey?: string;
  onRowClick?: (row: T, key: string) => void;
  stickyHeader?: boolean;
  maxBodyHeight?: string;
  skeletonRows?: number;
  className?: string;
  size?: "compact" | "comfortable";
}

const ALIGN_CLASS = { left: "text-left", center: "text-center", right: "text-right" } as const;

export default function DataTable<T>({
  columns = [],
  rows = [],
  rowKey = (_row, index) => String(index),
  loading = false,
  emptyText = "还没有数据",
  emptySlot,
  selectable = false,
  selectedKeys = [],
  onToggleRow,
  onToggleAll,
  allSelected = false,
  someSelected = false,
  activeKey,
  onRowClick,
  stickyHeader = true,
  maxBodyHeight,
  skeletonRows = 6,
  className,
  size = "compact",
}: DataTableProps<T>) {
  const [sort, setSort] = useState<{ key: string; dir: "asc" | "desc" } | null>(null);
  const selectedSet = useMemo(() => new Set(selectedKeys), [selectedKeys]);
  const rowCls = size === "comfortable" ? "h-[52px]" : "h-10";

  const sortedRows = useMemo(() => {
    if (!sort) return rows;
    const column = columns.find((item) => item.key === sort.key);
    if (!column?.sortValue) return rows;
    const read = column.sortValue;
    return [...rows].sort((a, b) => {
      const av = read(a);
      const bv = read(b);
      if (av === bv) return 0;
      if (av === null || av === undefined) return 1;
      if (bv === null || bv === undefined) return -1;
      const result =
        typeof av === "number" && typeof bv === "number"
          ? av - bv
          : String(av).localeCompare(String(bv), "zh-CN");
      return sort.dir === "asc" ? result : -result;
    });
  }, [rows, sort, columns]);

  const toggleSort = (key: string) => {
    setSort((prev) => {
      if (prev?.key !== key) return { key, dir: "asc" };
      if (prev.dir === "asc") return { key, dir: "desc" };
      return null;
    });
  };

  const totalCols = columns.length + (selectable ? 1 : 0);
  const stickyLeftOffset = selectable ? "left-[40px]" : "left-0";
  const stickyBgBase = "bg-background group-hover:bg-muted/50 group-data-[state=selected]:bg-muted";
  const stickyShadow = "shadow-[2px_0_4px_-2px_rgba(0,0,0,0.08)]";

  return (
    <div className={cn("pc-surface overflow-hidden", className)}>
      <div className="overflow-auto" style={maxBodyHeight ? { maxHeight: maxBodyHeight } : undefined}>
        <table className="min-w-full caption-bottom border-collapse">
          <TableHeader>
            <TableRow
              className={cn(
                "border-b border-border hover:bg-transparent",
                stickyHeader && "sticky top-0 z-10 bg-muted",
              )}
            >
              {selectable && (
                <TableHead className="sticky left-0 z-[3] h-9 w-10 bg-muted px-3">
                  <Checkbox
                    checked={allSelected ? true : someSelected ? "indeterminate" : false}
                    onCheckedChange={() => onToggleAll?.()}
                    aria-label="全选"
                  />
                </TableHead>
              )}
              {columns.map((column) => {
                const isSticky = column.sticky === "left";
                return (
                <TableHead
                  key={column.key}
                  className={cn(
                    "pc-table-head h-9 whitespace-nowrap px-3 font-medium",
                    ALIGN_CLASS[column.align ?? "left"],
                    column.width,
                    column.headClassName,
                    isSticky && cn("sticky z-[3] bg-muted", stickyLeftOffset, stickyShadow),
                  )}
                >
                  {column.sortable && column.sortValue ? (
                    <button
                      type="button"
                      onClick={() => toggleSort(column.key)}
                      className="inline-flex items-center gap-1 transition-colors hover:text-foreground"
                    >
                      {column.header}
                      {sort?.key === column.key ? (
                        sort.dir === "asc" ? (
                          <ArrowUp className="h-3 w-3" />
                        ) : (
                          <ArrowDown className="h-3 w-3" />
                        )
                      ) : (
                        <ChevronsUpDown className="h-3 w-3 opacity-40" />
                      )}
                    </button>
                  ) : (
                    column.header
                  )}
                </TableHead>
                );
              })}
            </TableRow>
          </TableHeader>

          <TableBody>
            {loading &&
              Array.from({ length: skeletonRows }).map((_, index) => (
                <TableRow key={`skeleton-${index}`} className="h-10 border-b border-border/60">
                  {Array.from({ length: totalCols }).map((__, cellIndex) => (
                    <TableCell key={`skeleton-cell-${cellIndex}`} className="px-3 py-0">
                      <div className="h-3 w-full max-w-[120px] animate-pulse rounded bg-muted" />
                    </TableCell>
                  ))}
                </TableRow>
              ))}

            {!loading && sortedRows.length === 0 && (
              <TableRow className="hover:bg-transparent">
                <TableCell colSpan={totalCols} className="px-3 py-12 text-center">
                  {emptySlot ?? <p className="pc-caption">{emptyText}</p>}
                </TableCell>
              </TableRow>
            )}

            {!loading &&
              sortedRows.map((row, index) => {
                const key = rowKey(row, index);
                const active = key === activeKey;
                const picked = selectedSet.has(key);
                return (
                  <TableRow
                    key={key}
                    data-state={picked ? "selected" : undefined}
                    onClick={onRowClick ? () => onRowClick(row, key) : undefined}
                    className={cn(
                      "group",
                      rowCls,
                      "border-b border-border/60 transition-colors",
                      onRowClick && "cursor-pointer",
                      active && "bg-primary/5 shadow-[inset_2px_0_0_0_hsl(var(--primary))]",
                    )}
                  >
                    {selectable && (
                      <TableCell
                        className={cn("sticky left-0 z-[2] w-10 px-3 py-0", stickyBgBase)}
                        onClick={(event) => event.stopPropagation()}
                      >
                        <Checkbox
                          checked={picked}
                          onCheckedChange={() => onToggleRow?.(key, row)}
                          aria-label="选择这一行"
                        />
                      </TableCell>
                    )}
                    {columns.map((column) => {
                      const isSticky = column.sticky === "left";
                      return (
                      <TableCell
                        key={column.key}
                        className={cn(
                          "whitespace-nowrap px-3 py-0 text-[13px]",
                          ALIGN_CLASS[column.align ?? "left"],
                          column.cellClassName,
                          isSticky && cn("sticky z-[2]", stickyLeftOffset, stickyBgBase, stickyShadow),
                        )}
                      >
                        {column.cell?.(row, index)}
                      </TableCell>
                      );
                    })}
                  </TableRow>
                );
              })}
          </TableBody>
        </table>
      </div>
    </div>
  );
}
