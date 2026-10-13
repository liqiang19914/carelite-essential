import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Textarea } from "@/components/ui/textarea";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { FieldGrid, Field } from "@/components/desktop/form/FieldGrid";
import { Calendar } from "@/components/ui/calendar";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Loader2, CalendarClock } from "lucide-react";
import { cn } from "@/lib/utils";
import { format } from "date-fns";
import { useState } from "react";

const FOLLOW_UP_TYPES = [
  { value: "phone", label: "电话沟通" },
  { value: "wechat", label: "微信沟通" },
  { value: "visit", label: "到店/上门" },
  { value: "other", label: "其他" },
];

interface ClientFollowUpDialogProps {
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  clientName?: string;
  type?: string;
  onTypeChange?: (value: string) => void;
  content?: string;
  onContentChange?: (value: string) => void;
  nextFollowUpAt?: string;
  onNextFollowUpAtChange?: (value: string) => void;
  reminder?: boolean;
  onReminderChange?: (value: boolean) => void;
  reminderWecom?: boolean;
  onReminderWecomChange?: (value: boolean) => void;
  onSubmit?: () => void;
  submitting?: boolean;
  submitLabel?: string;
  mode?: "create" | "edit";
  description?: string;
}

function parseDateTimeLocal(s: string): { date?: Date; hour: number; minute: number } {
  if (!s) return { hour: 9, minute: 0 };
  const [datePart, timePart] = s.split("T");
  const date = datePart ? new Date(datePart + "T00:00:00") : undefined;
  const hour = timePart ? parseInt(timePart.slice(0, 2), 10) : 9;
  const minute = timePart ? parseInt(timePart.slice(3, 5), 10) : 0;
  return { date, hour: isNaN(hour) ? 9 : hour, minute: isNaN(minute) ? 0 : minute };
}

function buildDateTimeLocal(date: Date | undefined, hour: number, minute: number): string {
  if (!date) return "";
  const d = new Date(date);
  d.setHours(hour, minute, 0, 0);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(hour)}:${pad(minute)}`;
}

export default function ClientFollowUpDialog({
  open = false,
  onOpenChange,
  clientName,
  type = "phone",
  onTypeChange,
  content = "",
  onContentChange,
  nextFollowUpAt = "",
  onNextFollowUpAtChange,
  reminder = false,
  onReminderChange,
  onSubmit,
  submitting = false,
  submitLabel,
  mode = "create",
  description,
}: ClientFollowUpDialogProps) {
  const isEdit = mode === "edit";
  const reminderNeedsTime = reminder && !nextFollowUpAt;

  const parsed = parseDateTimeLocal(nextFollowUpAt);
  const [tempDate, setTempDate] = useState<Date | undefined>(parsed.date);
  const [tempHour, setTempHour] = useState(parsed.hour);
  const [tempMinute, setTempMinute] = useState(parsed.minute);

  const commitDateTime = (d: Date | undefined, h: number, m: number) => {
    onNextFollowUpAtChange?.(buildDateTimeLocal(d, h, m));
  };

  const handleClearTime = () => {
    setTempDate(undefined);
    setTempHour(9);
    setTempMinute(0);
    onNextFollowUpAtChange?.("");
  };

  const displayDate = parseDateTimeLocal(nextFollowUpAt);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-[540px]">
        <DialogHeader>
          <DialogTitle className="pc-section-title">
            {isEdit ? "调整跟进提醒" : "记一条跟进"}
            {clientName ? ` · ${clientName}` : ""}
          </DialogTitle>
          <p className="pc-caption">
            {description ??
              (isEdit
                ? "修改下次跟进时间或重新开启提醒后，会重新计时提醒"
                : "保存后会同时刷新这位客户的最近联系时间")}
          </p>
          <DialogDescription className="sr-only">
            {isEdit ? "调整跟进提醒" : "记录客户跟进"}
            {clientName ? ` · ${clientName}` : ""}
          </DialogDescription>
        </DialogHeader>

        <FieldGrid cols={1}>
          <Field label="沟通方式">
            <Select value={type} onValueChange={onTypeChange}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {FOLLOW_UP_TYPES.map((item) => (
                  <SelectItem key={item.value} value={item.value}>
                    {item.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Field>
          <Field label="跟进内容">
            <Textarea
              value={content}
              onChange={(event) => onContentChange?.(event.target.value)}
              placeholder="聊了什么、客户反馈、下一步安排……"
              rows={4}
            />
          </Field>

          <Field label="下次跟进时间（选填）">
            <div className="flex items-center gap-2">
              <Popover>
                <PopoverTrigger asChild>
                  <button
                    type="button"
                    className={cn(
                      "flex h-9 flex-1 items-center justify-between rounded-md border border-border bg-background px-3 text-left text-sm transition-colors hover:border-primary/50",
                      !displayDate.date && "text-muted-foreground"
                    )}
                  >
                    <span className="inline-flex items-center gap-2">
                      <CalendarClock className="h-4 w-4 text-muted-foreground" />
                      {displayDate.date ? (
                        <span className="font-medium text-foreground">
                          {format(displayDate.date, "yyyy年M月d日")}
                        </span>
                      ) : (
                        <span>选择日期</span>
                      )}
                    </span>
                    {displayDate.date && (
                      <span
                        role="button"
                        tabIndex={0}
                        className="rounded-full p-0.5 text-muted-foreground/60 hover:bg-muted hover:text-foreground"
                        onClick={(e) => {
                          e.stopPropagation();
                          handleClearTime();
                        }}
                      >
                        ✕
                      </span>
                    )}
                  </button>
                </PopoverTrigger>
                <PopoverContent className="w-auto rounded-xl border-border bg-card p-0 shadow-xl" align="start" sideOffset={4}>
                  <div className="p-2">
                    <Calendar
                      mode="single"
                      selected={displayDate.date}
                      onSelect={(d) => {
                        setTempDate(d);
                        commitDateTime(d, tempHour, tempMinute);
                      }}
                      showOutsideDays={true}
                      initialFocus
                      className="text-sm"
                    />
                  </div>
                </PopoverContent>
              </Popover>

              <Select
                value={String(displayDate.hour)}
                onValueChange={(v) => {
                  const h = parseInt(v, 10);
                  setTempHour(h);
                  commitDateTime(displayDate.date, h, tempMinute);
                }}
              >
                <SelectTrigger className="h-9 w-[78px]">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {Array.from({ length: 24 }, (_, i) => i).map((h) => (
                    <SelectItem key={h} value={String(h)}>
                      {String(h).padStart(2, "0")} 时
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>

              <Select
                value={String(Math.floor(displayDate.minute / 5) * 5)}
                onValueChange={(v) => {
                  const m = parseInt(v, 10);
                  setTempMinute(m);
                  commitDateTime(displayDate.date, tempHour, m);
                }}
              >
                <SelectTrigger className="h-9 w-[78px]">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {Array.from({ length: 12 }, (_, i) => i * 5).map((m) => (
                    <SelectItem key={m} value={String(m)}>
                      {String(m).padStart(2, "0")} 分
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </Field>

          <Field label="到期提醒">
            <div className="flex items-center justify-between rounded-md border border-border px-3 py-2.5">
              <div className="space-y-0.5 pr-3">
                <p className="text-sm">到时间站内提醒</p>
                <p className="pc-caption">当天上午会收到站内消息，点开直达这位客户</p>
              </div>
              <Switch checked={reminder} onCheckedChange={(value) => onReminderChange?.(value)} />
            </div>
            {reminderNeedsTime && (
              <p className="pc-caption text-destructive">开启提醒需要先设置下次跟进时间</p>
            )}
          </Field>
        </FieldGrid>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange?.(false)}>
            取消
          </Button>
          <Button onClick={onSubmit} disabled={!content.trim() || submitting || reminderNeedsTime}>
            {submitting && <Loader2 className="mr-1 h-3.5 w-3.5 animate-spin" />}
            {submitLabel ?? (isEdit ? "保存修改" : "保存跟进")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
