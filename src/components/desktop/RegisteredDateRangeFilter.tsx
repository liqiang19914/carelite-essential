import { useState, useMemo } from "react";
import { format } from "date-fns";
import { Calendar as CalendarIcon, X } from "lucide-react";
import type { DateRange } from "react-day-picker";

import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Calendar } from "@/components/ui/calendar";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Input } from "@/components/ui/input";

export interface DateRangeValue {
  from?: Date;
  to?: Date;
}

interface RegisteredDateRangeFilterProps {
  value?: DateRangeValue;
  onChange?: (value: DateRangeValue | undefined) => void;
  placeholder?: string;
  /** 字段名前缀，显示在触发器内部（如「建档」「提醒」），避免标签漂浮在控件外 */
  prefixLabel?: string;
  /** 显示按钮的高度（px） */
  triggerHeight?: number;
}

function formatDateCN(d: Date | undefined): string {
  if (!d) return "";
  return `${d.getMonth() + 1}月${d.getDate()}日`;
}

export default function RegisteredDateRangeFilter({
  value,
  onChange = () => {},
  placeholder = "全部时间",
  prefixLabel,
  triggerHeight = 32,
}: RegisteredDateRangeFilterProps) {
  const [open, setOpen] = useState(false);
  // 内部临时状态（弹层打开期间编辑，确定后才 commit）
  const [tempFrom, setTempFrom] = useState<Date | undefined>(value?.from);
  const [tempTo, setTempTo] = useState<Date | undefined>(value?.to);

  const hasValue = Boolean(value?.from);

  // 按钮显示文字
  const label = useMemo(() => {
    if (!value?.from) return placeholder;
    return `${formatDateCN(value.from)} ~ ${value.to ? formatDateCN(value.to) : "至今"}`;
  }, [value, placeholder]);

  const handleOpenChange = (v: boolean) => {
    setOpen(v);
    if (v) {
      // 打开弹层时同步当前值到临时态
      setTempFrom(value?.from);
      setTempTo(value?.to);
    }
  };

  const handleCalendarSelect = (range: DateRange | undefined) => {
    setTempFrom(range?.from);
    setTempTo(range?.to);
  };

  const handleConfirm = () => {
    if (!tempFrom) {
      onChange(undefined);
    } else {
      onChange({ from: tempFrom, to: tempTo });
    }
    setOpen(false);
  };

  const handleClear = (e?: React.MouseEvent) => {
    e?.stopPropagation();
    onChange(undefined);
    setOpen(false);
  };

  // 手动输入日期（yyyy-mm-dd 或 9/1 格式都接受）
  const handleManualInput = (field: "from" | "to", raw: string) => {
    if (!raw.trim()) {
      if (field === "from") setTempFrom(undefined);
      else setTempTo(undefined);
      return;
    }
    // 尝试多种格式解析
    let d: Date | undefined;
    // yyyy-mm-dd
    const m1 = raw.match(/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$/);
    if (m1) {
      d = new Date(parseInt(m1[1]), parseInt(m1[2]) - 1, parseInt(m1[3]));
    }
    // 9月1日 / 9-1 / 9/1 / 9.1
    const m2 = raw.match(/^(\d{1,2})\s*[月\-/.]\s*(\d{1,2})/);
    if (!d && m2) {
      d = new Date(new Date().getFullYear(), parseInt(m2[1]) - 1, parseInt(m2[2]));
    }
    if (d && !isNaN(d.getTime())) {
      if (field === "from") setTempFrom(d);
      else setTempTo(d);
    }
  };

  return (
    <Popover open={open} onOpenChange={handleOpenChange}>
      <PopoverTrigger asChild>
        <Button
          variant="outline"
          className={cn(
            "h-8 gap-1.5 px-2.5 text-xs font-normal transition-colors",
            hasValue ? "border-primary/30 bg-primary/[0.04] text-foreground" : "text-muted-foreground"
          )}
          style={{ height: triggerHeight }}
        >
          <CalendarIcon className="h-3.5 w-3.5 flex-none" />
          {prefixLabel && <span className="flex-none text-muted-foreground">{prefixLabel}</span>}
          <span className={cn("truncate", hasValue && "font-medium text-foreground")}>{label}</span>
          {hasValue && (
            <span
              role="button"
              tabIndex={0}
              className="ml-0.5 flex-none rounded-full p-0.5 text-muted-foreground/60 transition-colors hover:bg-muted hover:text-foreground"
              onClick={handleClear}
              onKeyDown={(e) => { if (e.key === "Enter") handleClear(); }}
            >
              <X className="h-3 w-3" />
            </span>
          )}
        </Button>
      </PopoverTrigger>
      <PopoverContent
        className="w-[460px] rounded-xl border-border bg-card p-0 shadow-xl overflow-hidden"
        align="start"
        sideOffset={6}
      >
        {/* 标题 */}
        <div className="border-b border-border px-4 py-2.5">
          <h4 className="text-sm font-medium text-foreground">选择日期范围</h4>
          <p className="mt-0.5 text-[11px] text-muted-foreground">点击日历选择开始和结束日期</p>
        </div>

        {/* 双输入框 + 分隔符 */}
        <div className="flex items-center gap-2 px-4 pt-3">
          <div className="relative flex-1">
            <Input
              value={tempFrom ? formatDateCN(tempFrom) : ""}
              onChange={(e) => handleManualInput("from", e.target.value)}
              placeholder="开始日期"
              className="h-8 border-border bg-background text-xs focus-visible:ring-primary/50"
            />
          </div>
          <span className="text-xs text-muted-foreground">~</span>
          <div className="relative flex-1">
            <Input
              value={tempTo ? formatDateCN(tempTo) : ""}
              onChange={(e) => handleManualInput("to", e.target.value)}
              placeholder="结束日期"
              className="h-8 border-border bg-background text-xs focus-visible:ring-primary/50"
            />
          </div>
        </div>

        {/* 快捷选项 */}
        <div className="flex flex-wrap gap-1.5 px-4 pt-2">
          {[
            { label: "今天", from: 0, to: 0 },
            { label: "近7天", from: -6, to: 0 },
            { label: "近30天", from: -29, to: 0 },
            { label: "本月", from: -1, to: -1 },
          ].map((q) => (
            <button
              key={q.label}
              type="button"
              className="rounded-full border border-border bg-background px-2 py-0.5 text-[10px] text-muted-foreground transition-colors hover:border-primary/50 hover:text-primary"
              onClick={() => {
                const now = new Date();
                const to = new Date(now);
                to.setHours(23, 59, 59, 999);
                if (q.label === "本月") {
                  const from = new Date(now.getFullYear(), now.getMonth(), 1);
                  setTempFrom(from);
                  setTempTo(to);
                } else {
                  const from = new Date(now);
                  from.setDate(now.getDate() + q.from);
                  from.setHours(0, 0, 0, 0);
                  // "近X天" 如果只选了 from 没选 to，就到今天
                  setTempFrom(from);
                  setTempTo(q.label === "今天" ? from : to);
                }
              }}
            >
              {q.label}
            </button>
          ))}
        </div>

        {/* 日历（双月） */}
        <div className="flex justify-center px-2 py-2">
          <Calendar
            mode="range"
            numberOfMonths={2}
            selected={{ from: tempFrom, to: tempTo } as DateRange | undefined}
            onSelect={handleCalendarSelect}
            showOutsideDays={true}
            initialFocus
            className="text-sm"
          />
        </div>

        {/* 底部操作栏 */}
        <div className="flex items-center justify-between border-t border-border bg-muted/30 px-4 py-2.5">
          <button
            type="button"
            className="text-[11px] text-muted-foreground hover:text-foreground"
            onClick={() => {
              onChange(undefined);
              setOpen(false);
            }}
          >
            清除
          </button>
          <Button
            size="sm"
            className="h-7 px-4 text-xs"
            onClick={handleConfirm}
            disabled={!tempFrom}
          >
            确定
          </Button>
        </div>
      </PopoverContent>
    </Popover>
  );
}

// 保留导出的 format 给外部可能的引用
export { format };

