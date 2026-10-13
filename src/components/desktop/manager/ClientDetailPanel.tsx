import { useMemo, useState } from "react";
import { Bell, Check, ChevronRight, Pencil, Plus, Trash2, X } from "lucide-react";
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import PanelCard from "@/components/desktop/shell/PanelCard";
import StatusBadge from "@/components/desktop/data/StatusBadge";
import ClientFollowUpDialog from "@/components/desktop/manager/ClientFollowUpDialog";
import { useFollowUpRecords, type ClientWithProfile, type FollowUpRecord } from "@/hooks/useClients";
import { cn } from "@/lib/utils";

export const TAG_CHIP_CLASS: Record<string, string> = {
  blue: "bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-300",
  green: "bg-green-100 text-green-700 dark:bg-green-900/40 dark:text-green-300",
  red: "bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-300",
  yellow: "bg-yellow-100 text-yellow-700 dark:bg-yellow-900/40 dark:text-yellow-300",
  purple: "bg-purple-100 text-purple-700 dark:bg-purple-900/40 dark:text-purple-300",
};

export const REMINDER_STATUS_LABEL: Record<string, string> = {
  overdue: "提醒已逾期",
  today: "今天到期",
  upcoming: "未到期",
  none: "无提醒",
};

function toDatetimeLocal(iso: string | null): string {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

interface ClientDetailPanelProps {
  client?: ClientWithProfile | null;
  allTags?: { id: string; name: string; color: string }[];
  phoneText?: string;
  lastContactText?: string;
  onToggleTag?: (tagId: string) => void;
  onCreateTag?: () => void;
  onFollowUp?: () => void;
  onEdit?: () => void;
  onDelete?: () => void;
  onOpenProfile?: () => void;
  onClose?: () => void;
  onUpdateReminder?: (input: {
    recordId: string;
    content?: string | null;
    followUpType?: string | null;
    nextFollowUpAt?: string | null;
    reminder?: boolean | null;
    reminderWecom?: boolean | null;
  }) => Promise<unknown>;
  updatingReminder?: boolean;
}

export default function ClientDetailPanel({
  client,
  allTags = [],
  phoneText,
  lastContactText,
  onToggleTag,
  onCreateTag,
  onFollowUp,
  onEdit,
  onDelete,
  onOpenProfile,
  onClose,
  onUpdateReminder,
  updatingReminder = false,
}: ClientDetailPanelProps) {
  const { data: followUps = [] } = useFollowUpRecords(client?.id ?? null);
  const [editingReminder, setEditingReminder] = useState(false);
  const [reminderForm, setReminderForm] = useState({
    content: "",
    type: "phone",
    nextAt: "",
    reminder: true,
    reminderWecom: false,
  });

  // 当前生效的提醒 = 开启提醒且下次跟进时间最晚的一条
  const latestReminder = useMemo<FollowUpRecord | null>(() => {
    let latest: FollowUpRecord | null = null;
    for (const record of followUps) {
      if (!record.reminder || !record.next_follow_up_at) continue;
      if (!latest || record.next_follow_up_at > latest.next_follow_up_at) {
        latest = record;
      }
    }
    return latest;
  }, [followUps]);

  const openReminderEditor = () => {
    if (!latestReminder) return;
    setReminderForm({
      content: latestReminder.content,
      type: latestReminder.follow_up_type || "phone",
      nextAt: toDatetimeLocal(latestReminder.next_follow_up_at),
      reminder: true,
      reminderWecom: latestReminder.reminder_wecom,
    });
    setEditingReminder(true);
  };

  const submitReminderEdit = async () => {
    if (!latestReminder || !onUpdateReminder) return;
    try {
      await onUpdateReminder({
        recordId: latestReminder.id,
        content: reminderForm.content,
        followUpType: reminderForm.type,
        nextFollowUpAt: reminderForm.nextAt
          ? new Date(reminderForm.nextAt).toISOString()
          : null,
        reminder: reminderForm.reminder,
        reminderWecom: reminderForm.reminderWecom,
      });
      setEditingReminder(false);
    } catch {
      // 错误提示已由 mutation 弹出
    }
  };

  if (!client) return null;

  const assigned = new Set(client.tags.map((tag) => tag.id));
  const displayName = client.customer_name || client.profile?.nickname || "未知客户";
  const reminderStatus = client.reminder_status;

  return (
    <PanelCard
      padded={false}
      className="h-full min-h-0"
      bodyClassName="min-h-0 overflow-y-auto"
      title={
        <span className="flex items-center gap-2">
          <Avatar className="h-7 w-7">
            <AvatarImage src={client.profile?.avatar_url || undefined} />
            <AvatarFallback className="text-xs">
              {displayName.charAt(0) || "客"}
            </AvatarFallback>
          </Avatar>
          <span className="truncate">{displayName}</span>
        </span>
      }
      action={
        onClose && (
          <button
            type="button"
            onClick={onClose}
            className="rounded p-1 text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
            aria-label="关闭详情"
          >
            <X className="h-3.5 w-3.5" />
          </button>
        )
      }
    >
      <div className="space-y-4 p-4">
        <div className="flex flex-wrap items-center gap-2">
          <span className="pc-num pc-body">{phoneText}</span>
          {reminderStatus === "overdue" && <StatusBadge tone="danger" label="提醒已逾期" icon={Bell} />}
          {reminderStatus === "today" && <StatusBadge tone="warning" label="今天到期" icon={Bell} />}
          {reminderStatus === "upcoming" && (
            <StatusBadge
              tone="primary"
              label={`下次跟进 ${new Date(client.next_reminder_at!).toLocaleDateString("zh-CN", { month: "2-digit", day: "2-digit" })}`}
              icon={Bell}
            />
          )}
        </div>

        <div className="flex flex-wrap gap-1.5">
          <Button size="sm" className="h-8" onClick={onOpenProfile}>
            进入健康档案
            <ChevronRight className="ml-0.5 h-3.5 w-3.5" />
          </Button>
          <Button size="sm" variant="outline" className="h-8" onClick={onFollowUp}>
            记跟进
          </Button>
          {latestReminder && onUpdateReminder && (
            <Button size="sm" variant="outline" className="h-8" onClick={openReminderEditor}>
              <Bell className="mr-1 h-3 w-3" />
              调整提醒
            </Button>
          )}
          <Button size="sm" variant="outline" className="h-8" onClick={onEdit}>
            <Pencil className="mr-1 h-3 w-3" />
            编辑
          </Button>
          <Button
            size="sm"
            variant="ghost"
            className="h-8 text-destructive hover:bg-destructive/10 hover:text-destructive"
            onClick={onDelete}
          >
            <Trash2 className="mr-1 h-3 w-3" />
            删除
          </Button>
        </div>

        <div>
          <p className="pc-field-label mb-1.5">标签</p>
          <div className="flex flex-wrap items-center gap-1.5">
            {client.tags.map((tag) => (
              <span
                key={tag.id}
                className={cn("pc-badge group", TAG_CHIP_CLASS[tag.color] ?? TAG_CHIP_CLASS.blue)}
              >
                {tag.name}
                <button type="button" onClick={() => onToggleTag?.(tag.id)} aria-label={`移除 ${tag.name}`}>
                  <X className="h-2.5 w-2.5 opacity-50 transition-opacity hover:opacity-100" />
                </button>
              </span>
            ))}
            <Popover>
              <PopoverTrigger asChild>
                <button
                  type="button"
                  className="pc-badge pc-badge-neutral border border-dashed border-border transition-colors hover:text-foreground"
                >
                  <Plus className="h-2.5 w-2.5" />
                  加标签
                </button>
              </PopoverTrigger>
              <PopoverContent align="start" className="w-52 p-1.5">
                <div className="max-h-56 space-y-0.5 overflow-y-auto">
                  {allTags.length === 0 && <p className="pc-caption px-2 py-3 text-center">还没有标签</p>}
                  {allTags.map((tag) => (
                    <button
                      key={tag.id}
                      type="button"
                      onClick={() => onToggleTag?.(tag.id)}
                      className="flex w-full items-center justify-between gap-2 rounded px-2 py-1.5 text-[13px] transition-colors hover:bg-muted"
                    >
                      <span className="truncate">{tag.name}</span>
                      {assigned.has(tag.id) && <Check className="h-3.5 w-3.5 text-primary" />}
                    </button>
                  ))}
                </div>
                {onCreateTag && (
                  <button
                    type="button"
                    onClick={onCreateTag}
                    className="mt-1 flex w-full items-center gap-1.5 border-t border-border px-2 pt-2 text-[13px] text-primary"
                  >
                    <Plus className="h-3 w-3" />
                    新建标签
                  </button>
                )}
              </PopoverContent>
            </Popover>
          </div>
        </div>

        <div>
          <p className="pc-field-label mb-1">备注</p>
          <p className="pc-body whitespace-pre-wrap text-muted-foreground">{client.notes || "暂无备注"}</p>
        </div>

        <div>
          <p className="pc-field-label mb-1.5">最近跟进</p>
          {followUps.length === 0 ? (
            <p className="pc-caption">还没有跟进记录</p>
          ) : (
            <ul className="space-y-2">
              {followUps.slice(0, 4).map((record) => (
                <li key={record.id} className="pc-surface-muted px-2.5 py-2">
                  <p className="pc-body line-clamp-3">{record.content}</p>
                  <p className="pc-caption mt-1">
                    {new Date(record.created_at).toLocaleString("zh-CN", {
                      month: "2-digit",
                      day: "2-digit",
                      hour: "2-digit",
                      minute: "2-digit",
                    })}
                    {record.creator_nickname ? ` · ${record.creator_nickname}` : ""}
                    {record.reminder && record.next_follow_up_at && (
                      <span className="ml-2 inline-flex items-center gap-0.5 text-primary">
                        <Bell className="h-2.5 w-2.5" />
                        下次跟进{" "}
                        {new Date(record.next_follow_up_at).toLocaleString("zh-CN", {
                          month: "2-digit",
                          day: "2-digit",
                          hour: "2-digit",
                          minute: "2-digit",
                        })}
                      </span>
                    )}
                  </p>
                </li>
              ))}
            </ul>
          )}
        </div>

        <dl className="grid grid-cols-2 gap-y-2 border-t border-border pt-3">
          <dt className="pc-field-label">最近联系</dt>
          <dd className="pc-body text-right">{lastContactText}</dd>
          <dt className="pc-field-label">建档时间</dt>
          <dd className="pc-body text-right">
            {new Date(client.created_at).toLocaleDateString("zh-CN")}
          </dd>
          <dt className="pc-field-label">客户 ID</dt>
          <dd className="pc-num pc-caption truncate text-right" title={client.client_id}>
            {client.client_id.slice(0, 8)}
          </dd>
        </dl>
      </div>

      {latestReminder && (
        <ClientFollowUpDialog
          open={editingReminder}
          onOpenChange={setEditingReminder}
          clientName={displayName}
          mode="edit"
          type={reminderForm.type}
          onTypeChange={(value) => setReminderForm((prev) => ({ ...prev, type: value }))}
          content={reminderForm.content}
          onContentChange={(value) => setReminderForm((prev) => ({ ...prev, content: value }))}
          nextFollowUpAt={reminderForm.nextAt}
          onNextFollowUpAtChange={(value) => setReminderForm((prev) => ({ ...prev, nextAt: value }))}
          reminder={reminderForm.reminder}
          onReminderChange={(value) => setReminderForm((prev) => ({ ...prev, reminder: value }))}
          reminderWecom={reminderForm.reminderWecom}
          onReminderWecomChange={(value) =>
            setReminderForm((prev) => ({ ...prev, reminderWecom: value }))
          }
          onSubmit={submitReminderEdit}
          submitting={updatingReminder}
        />
      )}
    </PanelCard>
  );
}
