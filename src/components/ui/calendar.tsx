import * as React from "react"
import {
    ChevronDownIcon,
    ChevronLeftIcon,
    ChevronRightIcon,
} from "lucide-react"
import {
    DayPicker,
    getDefaultClassNames,
    type DayButton,
} from "react-day-picker"
import { zhCN } from "date-fns/locale"

import { cn } from "@/lib/utils"
import { Button, buttonVariants } from "@/components/ui/button"

function Calendar({
                      className,
                      classNames,
                      showOutsideDays = true,
                      captionLayout = "label",
                      buttonVariant = "ghost",
                      formatters,
                      components,
                      locale,
                      ...props
                  }: React.ComponentProps<typeof DayPicker> & {
    buttonVariant?: React.ComponentProps<typeof Button>["variant"]
}) {
    const defaultClassNames = getDefaultClassNames()
    const effectiveLocale = locale ?? zhCN

    return (
        <DayPicker
            showOutsideDays={showOutsideDays}
            locale={effectiveLocale}
            className={cn(
                "group/calendar [--cell-size:32px] p-1",
                className
            )}
            captionLayout={captionLayout}
            formatters={{
                formatMonthDropdown: (date) =>
                    date.toLocaleString("zh-CN", { month: "long" }),
                ...formatters,
            }}
            classNames={{
                root: cn("w-full", defaultClassNames.root),
                months: cn(
                    "flex gap-3 flex-col md:flex-row",
                    defaultClassNames.months
                ),
                month: cn("flex flex-col gap-2", defaultClassNames.month),

                // 月份标题 + 导航
                nav: cn(
                    "flex items-center gap-1 w-full absolute top-0 inset-x-0 justify-between px-1",
                    defaultClassNames.nav
                ),
                button_previous: cn(
                    "h-7 w-7 rounded-md text-muted-foreground hover:bg-muted hover:text-foreground transition-colors",
                    buttonVariants({ variant: "ghost", size: "icon" }),
                    "aria-disabled:opacity-30 aria-disabled:hover:bg-transparent",
                    defaultClassNames.button_previous
                ),
                button_next: cn(
                    "h-7 w-7 rounded-md text-muted-foreground hover:bg-muted hover:text-foreground transition-colors",
                    buttonVariants({ variant: "ghost", size: "icon" }),
                    "aria-disabled:opacity-30 aria-disabled:hover:bg-transparent",
                    defaultClassNames.button_next
                ),
                month_caption: cn(
                    "flex items-center justify-center h-8 w-full px-8 text-sm font-semibold text-foreground",
                    defaultClassNames.month_caption
                ),
                dropdowns: cn(
                    "w-full flex items-center text-sm font-semibold justify-center h-8 gap-1.5",
                    defaultClassNames.dropdowns
                ),
                dropdown_root: cn(
                    "relative rounded-md border border-input bg-background px-2 py-1 text-sm shadow-sm hover:border-primary/40 focus-within:border-primary focus-within:ring-2 focus-within:ring-primary/20 transition",
                    defaultClassNames.dropdown_root
                ),
                dropdown: cn(
                    "absolute bg-popover inset-0 opacity-0",
                    defaultClassNames.dropdown
                ),
                caption_label: cn(
                    "select-none font-semibold text-sm text-foreground",
                    captionLayout === "label"
                        ? ""
                        : "rounded-md pl-2 pr-1 flex items-center gap-1 text-sm h-8 [&>svg]:text-muted-foreground [&>svg]:w-3.5 [&>svg]:h-3.5",
                    defaultClassNames.caption_label
                ),

                // 表格 / 星期头
                table: "w-full border-collapse",
                weekdays: cn("flex border-b border-border/60 pb-1", defaultClassNames.weekdays),
                weekday: cn(
                    "text-muted-foreground flex-1 font-medium text-[11px] select-none py-1",
                    defaultClassNames.weekday
                ),
                week: cn("flex w-full", defaultClassNames.week),
                week_number_header: cn(
                    "select-none w-[var(--cell-size)]",
                    defaultClassNames.week_number_header
                ),
                week_number: cn(
                    "text-[11px] select-none text-muted-foreground",
                    defaultClassNames.week_number
                ),

                // 日期格子容器
                day: cn(
                    "relative w-full aspect-square select-none flex items-center justify-center",
                    defaultClassNames.day
                ),

                // 范围状态（背景条）— 用伪元素 + overflow clip 来约束高度
                range_start: cn(
                    "before:absolute before:inset-y-1 before:right-0 before:w-1/2 before:bg-primary/15 before:content-['']",
                    defaultClassNames.range_start
                ),
                range_middle: cn(
                    "before:absolute before:inset-y-1 before:bg-primary/15 before:content-['']",
                    defaultClassNames.range_middle
                ),
                range_end: cn(
                    "before:absolute before:inset-y-1 before:left-0 before:w-1/2 before:bg-primary/15 before:content-['']",
                    defaultClassNames.range_end
                ),

                // 今天（小圆点）
                today: cn(
                    "",
                    defaultClassNames.today
                ),

                // 外部月份（灰色）
                outside: cn(
                    "text-muted-foreground/40",
                    defaultClassNames.outside
                ),
                disabled: cn(
                    "text-muted-foreground opacity-40",
                    defaultClassNames.disabled
                ),
                hidden: cn("invisible", defaultClassNames.hidden),
                ...classNames,
            }}
            components={{
                Root: ({ className, rootRef, ...props }) => {
                    return (
                        <div
                            data-slot="calendar"
                            ref={rootRef}
                            className={cn("rounded-lg", className)}
                            {...props}
                        />
                    )
                },
                Chevron: ({ className, orientation, ...props }) => {
                    if (orientation === "left") {
                        return (
                            <ChevronLeftIcon className={cn("w-4 h-4", className)} {...props} />
                        )
                    }
                    if (orientation === "right") {
                        return (
                            <ChevronRightIcon
                                className={cn("w-4 h-4", className)}
                                {...props}
                            />
                        )
                    }
                    return (
                        <ChevronDownIcon className={cn("w-4 h-4", className)} {...props} />
                    )
                },
                DayButton: CalendarDayButton,
                WeekNumber: ({ children, ...props }) => {
                    return (
                        <td {...props}>
                            <div className="flex w-[var(--cell-size)] h-[var(--cell-size)] items-center justify-center text-center">
                                {children}
                            </div>
                        </td>
                    )
                },
                ...components,
            }}
            {...props}
        />
    )
}

function CalendarDayButton({
                               className,
                               day,
                               modifiers,
                               ...props
                           }: React.ComponentProps<typeof DayButton>) {
    const ref = React.useRef<HTMLButtonElement>(null)
    React.useEffect(() => {
        if (modifiers.focused) ref.current?.focus()
    }, [modifiers.focused])

    const isToday = modifiers.today
    const isSelectedSingle = modifiers.selected && !modifiers.range_start && !modifiers.range_end && !modifiers.range_middle
    const isRangeStart = modifiers.range_start
    const isRangeEnd = modifiers.range_end
    const isRangeMiddle = modifiers.range_middle
    const isRangeEdge = isRangeStart || isRangeEnd

    // 计算按钮的视觉样式
    let btnBase =
        "relative flex h-[28px] w-[28px] items-center justify-center rounded-md text-[12px] font-normal transition-all duration-150 " +
        "hover:bg-muted hover:text-foreground " +
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40 " +
        "aria-disabled:cursor-not-allowed aria-disabled:opacity-40 aria-disabled:hover:bg-transparent "

    // 选中状态：统一主色圆形
    if (isSelectedSingle) {
        btnBase += " bg-primary text-primary-foreground font-medium shadow-sm "
    }
    if (isRangeEdge) {
        btnBase += " bg-primary text-primary-foreground font-medium shadow-sm "
    }
    if (isRangeMiddle && !isToday) {
        btnBase += " text-foreground hover:bg-primary/10 "
    }
    // 今天：未选中时底部小点 + 字体加粗
    if (isToday && !isSelectedSingle && !isRangeEdge) {
        btnBase += " font-semibold text-foreground after:absolute after:bottom-1 after:left-1/2 after:-translate-x-1/2 after:h-1 after:w-1 after:rounded-full after:bg-primary "
    }
    // 今天在范围内：保持加粗
    if (isToday && !isSelectedSingle && !isRangeEdge) {
        // 已经加了 after 圆点
    }

    return (
        <button
            ref={ref}
            type="button"
            {...props}
            data-range-start={isRangeStart}
            data-range-end={isRangeEnd}
            data-range-middle={isRangeMiddle}
            data-today={isToday}
            data-selected={isSelectedSingle}
            className={cn(btnBase, className)}
        >
            {day.date.getDate()}
        </button>
    )
}

export { Calendar, CalendarDayButton }

