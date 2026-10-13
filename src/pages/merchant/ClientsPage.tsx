import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Bell, Columns, Download, Loader2, Plus, Tag, Trash2 } from "lucide-react";
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import RegisteredDateRangeFilter from "@/components/desktop/RegisteredDateRangeFilter";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import PageContainer from "@/components/desktop/shell/PageContainer";
import PageHeader from "@/components/desktop/shell/PageHeader";
import { Sheet, SheetContent, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import DataTable, { type DataTableColumn } from "@/components/desktop/data/DataTable";
import FilterBar from "@/components/desktop/data/FilterBar";
import BulkActionBar from "@/components/desktop/data/BulkActionBar";
import ClientDetailPanel, { TAG_CHIP_CLASS } from "@/components/desktop/manager/ClientDetailPanel";
import ClientFormDialog from "@/components/desktop/manager/ClientFormDialog";
import ClientEditSheet from "@/components/desktop/manager/ClientEditSheet";
import UnsavedLeaveDialog from "@/components/desktop/form/UnsavedLeaveDialog";
import ClientFollowUpDialog from "@/components/desktop/manager/ClientFollowUpDialog";
import ClientTagCreateDialog from "@/components/desktop/manager/ClientTagCreateDialog";
import ClientRecycleBinSheet from "@/components/desktop/manager/ClientRecycleBinSheet";
import { useClientsWorkbench } from "@/hooks/controllers/useClientsWorkbench";
import { useDesktopTableSelection } from "@/hooks/useDesktopTableSelection";
import ListPagination from "@/components/desktop/ListPagination";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import type { ClientWithProfile } from "@/hooks/useClients";
import { convertToCSV, downloadCSV } from "@/lib/csv-download";
import { cn } from "@/lib/utils";
import { BMI_FILTER_OPTIONS } from "@/lib/bmiStatus";
import BmiStatusBadge from "@/components/BmiStatusBadge";

function reminderCellText(client: ClientWithProfile): string {
  if (client.reminder_status === "none") return "—";
  if (!client.next_reminder_at) return "—";
  return new Date(client.next_reminder_at).toLocaleDateString("zh-CN", {
    month: "2-digit",
    day: "2-digit",
  });
}

const COLUMN_TOGGLES: { key: string; label: string }[] = [
  { key: "phone", label: "手机号" },
  { key: "profile_name", label: "档案姓名" },
  { key: "bmi", label: "BMI" },
  { key: "tags", label: "标签" },
  { key: "status", label: "状态" },
  { key: "created_at", label: "添加时间" },
  { key: "reminder", label: "下次跟进" },
  { key: "notes", label: "备注" },
  { key: "last_contact", label: "最近联系" },
];

const HIDDEN_COLUMNS_KEY = "client-table-hidden-columns";

function loadHiddenColumns(): Set<string> {
  try {
    const stored = localStorage.getItem(HIDDEN_COLUMNS_KEY);
    return stored ? new Set(JSON.parse(stored) as string[]) : new Set();
  } catch {
    return new Set();
  }
}

export default function ClientsPage() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const w = useClientsWorkbench();
  const rowKeys = useMemo(() => w.filteredClients.map((client) => client.id), [w.filteredClients]);
  const selection = useDesktopTableSelection(rowKeys);

  const [sheetMode, setSheetMode] = useState<"detail" | "edit">("detail");
  const [editInitial, setEditInitial] = useState({ nickname: "", phone: "", notes: "" });
  const [showUnsavedConfirm, setShowUnsavedConfirm] = useState(false);
  const [showRecycleBin, setShowRecycleBin] = useState(false);
  const [hiddenColumns, setHiddenColumns] = useState<Set<string>>(loadHiddenColumns);

  const toggleColumn = (key: string) => {
    setHiddenColumns((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      try {
        localStorage.setItem(HIDDEN_COLUMNS_KEY, JSON.stringify([...next]));
      } catch {
        // localStorage 写入失败静默忽略
      }
      return next;
    });
  };

  const closeClientSheet = () => {
    w.setSelectedClient(null);
    setSheetMode("detail");
    w.setEditingClient(null);
    w.setClientForm({ nickname: "", phone: "", notes: "" });
  };

  const openEditInSheet = (client: ClientWithProfile) => {
    w.openEditDialog(client);
    setEditInitial({
      nickname: client.customer_name || client.profile?.nickname || "",
      phone: w.formatClientPhoneDetail(client),
      notes: client.notes || "",
    });
    setSheetMode("edit");
  };

  const editDirty =
    w.clientForm.nickname !== editInitial.nickname ||
    w.clientForm.phone !== editInitial.phone ||
    w.clientForm.notes !== editInitial.notes;

  const handleSheetCloseRequest = () => {
    if (w.isUpdating) return;
    if (sheetMode === "edit" && editDirty) {
      setShowUnsavedConfirm(true);
      return;
    }
    closeClientSheet();
  };

  useEffect(() => {
    if (!w.selectedClient || w.isLoading) return;
    if (!w.selectedClientData) {
      handleSheetCloseRequest();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [w.selectedClient, w.selectedClientData, w.isLoading]);

  const handleSheetEditSave = async () => {
    try {
      await w.handleEditClient();
      closeClientSheet();
    } catch {
      // 错误提示已由保存动作弹出，保留抽屉与已填内容
    }
  };

  const columns: DataTableColumn<ClientWithProfile>[] = [
    {
      key: "client",
      header: "客户",
      sticky: "left",
      sortable: true,
      sortValue: (row) => row.customer_name ?? row.profile?.nickname ?? "",
      cell: (row) => (
        <div className="flex items-center gap-2">
          <Avatar className="h-6 w-6">
            <AvatarImage src={row.profile?.avatar_url || undefined} />
            <AvatarFallback className="text-[10px]">
              {(row.customer_name || row.profile?.nickname)?.charAt(0) || "客"}
            </AvatarFallback>
          </Avatar>
          <span className="truncate font-medium">{row.customer_name || row.profile?.nickname || "未知客户"}</span>
        </div>
      ),
    },
    {
      key: "phone",
      header: "手机号",
      width: "w-[130px]",
      cell: (row) => <span className="pc-num text-muted-foreground">{w.formatClientPhoneList(row)}</span>,
    },
    {
      key: "profile_name",
      header: "档案姓名",
      width: "w-[110px]",
      cell: (row) =>
        row.profileName ? (
          <span className="truncate">{row.profileName}</span>
        ) : (
          <span className="text-muted-foreground/60">—</span>
        ),
    },
    {
      key: "bmi",
      header: "BMI",
      width: "w-[80px]",
      sortable: true,
      sortValue: (row) => row.bmi_status ?? "",
      cell: (row) => <BmiStatusBadge status={row.bmi_status} />,
    },
    {
      key: "tags",
      header: "标签",
      width: "w-[190px]",
      cell: (row) => (
        <div className="flex items-center gap-1">
          {row.tags.slice(0, 2).map((tag) => (
            <span key={tag.id} className={cn("pc-badge", TAG_CHIP_CLASS[tag.color] ?? TAG_CHIP_CLASS.blue)}>
              {tag.name}
            </span>
          ))}
          {row.tags.length > 2 && <span className="pc-caption">+{row.tags.length - 2}</span>}
          {row.tags.length === 0 && <span className="pc-caption">—</span>}
        </div>
      ),
    },
    {
      key: "status",
      header: (
        <span className="inline-flex items-center gap-1">
          状态
        </span>
      ),
      width: "w-[90px]",
      cell: (row) => {
        const map: Record<string, { label: string; cls: string }> = {
          active: { label: "活跃", cls: "text-emerald-600" },
          inactive: { label: "非活跃", cls: "text-muted-foreground" },
          pending: { label: "待跟进", cls: "text-amber-600" },
        };
        const item = map[row.status] ?? { label: row.status, cls: "text-muted-foreground" };
        return <span className={cn("text-sm font-medium", item.cls)}>{item.label}</span>;
      },
    },
    {
      key: "created_at",
      header: "添加时间",
      width: "w-[110px]",
      sortable: true,
      sortValue: (row) => new Date(row.created_at).getTime(),
      cell: (row) => (
        <span className="text-muted-foreground">
          {new Date(row.created_at).toLocaleDateString("zh-CN")}
        </span>
      ),
    },
    {
      key: "reminder",
      header: "下次跟进",
      width: "w-[110px]",
      sortable: true,
      sortValue: (row) => (row.next_reminder_at ? new Date(row.next_reminder_at).getTime() : null),
      cell: (row) => {
        if (row.reminder_status === "overdue") {
          return (
            <span className="inline-flex items-center gap-1 text-destructive">
              <Bell className="h-3 w-3" />
              {reminderCellText(row)} · 已逾期
            </span>
          );
        }
        if (row.reminder_status === "today") {
          return (
            <span className="inline-flex items-center gap-1 text-amber-600 dark:text-amber-400">
              <Bell className="h-3 w-3" />
              今天到期
            </span>
          );
        }
        if (row.reminder_status === "upcoming") {
          return (
            <span className="inline-flex items-center gap-1 text-muted-foreground">
              <Bell className="h-3 w-3" />
              {reminderCellText(row)}
            </span>
          );
        }
        return <span className="text-muted-foreground">—</span>;
      },
    },
    {
      key: "notes",
      header: "备注",
      cell: (row) => (
        <span className="line-clamp-1 text-muted-foreground" title={row.notes ?? ""}>
          {row.notes || "—"}
        </span>
      ),
    },
    {
      key: "last_contact",
      header: "最近联系",
      width: "w-[130px]",
      align: "right",
      sortable: true,
      sortValue: (row) => (row.last_contact_at ? new Date(row.last_contact_at).getTime() : null),
      cell: (row) => <span className="text-muted-foreground">{w.formatTime(row.last_contact_at)}</span>,
    },
  ];

  const visibleColumns = columns.filter((col) => !hiddenColumns.has(col.key));

  const bulkAddTag = (tagId: string) => {
    selection.selectedKeys.forEach((relationId) => {
      w.addTagToClient({ clientRelationId: relationId, tagId });
    });
    selection.clear();
  };

  const exportSelected = () => {
    const picked = w.filteredClients.filter((client) => selection.selectedKeys.includes(client.id));
    const csv = convertToCSV(
      picked.map((client) => ({
        nickname: client.customer_name || client.profile?.nickname || "",
        phone: w.formatClientPhoneDetail(client),
        profile_name: client.profileName || "",
        status: client.status,
        created_at: new Date(client.created_at).toLocaleDateString("zh-CN"),
        notes: client.notes ?? "",
        last_contact_at: w.formatTime(client.last_contact_at),
      })),
      {
        nickname: "客户姓名",
        phone: "手机号",
        profile_name: "档案姓名",
        status: "状态",
        created_at: "建档时间",
        notes: "备注",
        last_contact_at: "最近联系",
      },
    );
    downloadCSV(csv, `客户名单_${new Date().toISOString().slice(0, 10)}.csv`);
    toast.success(`已导出 ${picked.length} 位客户`);
  };

  return (
    <PageContainer width="data">
      <PageHeader
        crumbs={[{ label: "商户端", to: "/merchant" }, { label: "客户管理" }]}
        title="客户管理"
        actions={
          <>
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="outline" size="sm" className="h-8">
                  <Columns className="mr-1 h-3.5 w-3.5" />
                  列设置
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" className="w-44">
                <DropdownMenuLabel className="text-xs text-muted-foreground">显示/隐藏列</DropdownMenuLabel>
                {COLUMN_TOGGLES.map((col) => {
                  const visible = !hiddenColumns.has(col.key);
                  return (
                    <DropdownMenuItem
                      key={col.key}
                      onClick={(e) => {
                        e.preventDefault();
                        toggleColumn(col.key);
                      }}
                      className="cursor-pointer"
                    >
                      <span className={cn("mr-2 inline-flex h-4 w-4 items-center justify-center rounded border", visible ? "border-primary bg-primary text-primary-foreground" : "border-muted-foreground/30")}>
                        {visible && "✓"}
                      </span>
                      {col.label}
                    </DropdownMenuItem>
                  );
                })}
              </DropdownMenuContent>
            </DropdownMenu>
            <Button variant="outline" size="sm" className="h-8" onClick={() => setShowRecycleBin(true)}>
              <Trash2 className="mr-1 h-3.5 w-3.5" />
              回收站
            </Button>
            <Button variant="outline" size="sm" className="h-8" onClick={() => w.setShowCreateTagDialog(true)}>
              <Tag className="mr-1 h-3.5 w-3.5" />
              新建标签
            </Button>
            <Button size="sm" className="h-8" onClick={() => w.setShowAddDialog(true)}>
              <Plus className="mr-1 h-3.5 w-3.5" />
              新增客户
            </Button>
          </>
        }
      />

      <div className="flex min-h-0 flex-1 flex-col gap-4">
        <div className="flex min-h-0 min-w-0 flex-1 flex-col gap-4">
          <FilterBar
            searchValue={w.searchQuery}
            onSearchChange={w.setSearchQuery}
            searchPlaceholder="搜姓名或手机号"
            searchWidth="w-[260px]"
            activeCount={w.hasActiveFilters ? 1 : 0}
            onReset={w.resetFilters}
            right={
              <span className="pc-caption">
                {w.selectedFilter !== "全部" ? (
                  <>
                    本页匹配 <span className="pc-num text-foreground">{w.filteredClients.length}</span> 位
                  </>
                ) : (
                  <>
                    共 <span className="pc-num text-foreground">{w.totalRows}</span> 位
                  </>
                )}
              </span>
            }
          >
            <RegisteredDateRangeFilter
              prefixLabel="建档"
              value={{
                from: w.createdFrom ? new Date(w.createdFrom) : undefined,
                to: w.createdTo ? new Date(w.createdTo) : undefined,
              }}
              onChange={(v) => {
                w.setCreatedFrom(v?.from ? `${v.from.getFullYear()}-${String(v.from.getMonth() + 1).padStart(2, "0")}-${String(v.from.getDate()).padStart(2, "0")}` : "");
                w.setCreatedTo(v?.to ? `${v.to.getFullYear()}-${String(v.to.getMonth() + 1).padStart(2, "0")}-${String(v.to.getDate()).padStart(2, "0")}` : "");
              }}
              placeholder="全部时间"
              triggerHeight={32}
            />
            <RegisteredDateRangeFilter
              prefixLabel="提醒"
              value={{
                from: w.reminderFrom ? new Date(w.reminderFrom) : undefined,
                to: w.reminderTo ? new Date(w.reminderTo) : undefined,
              }}
              onChange={(v) => {
                w.setReminderFrom(v?.from ? `${v.from.getFullYear()}-${String(v.from.getMonth() + 1).padStart(2, "0")}-${String(v.from.getDate()).padStart(2, "0")}` : "");
                w.setReminderTo(v?.to ? `${v.to.getFullYear()}-${String(v.to.getMonth() + 1).padStart(2, "0")}-${String(v.to.getDate()).padStart(2, "0")}` : "");
              }}
              placeholder="全部时间"
              triggerHeight={32}
            />
            <Select value={w.bmiFilter} onValueChange={(value) => w.setBmiFilter(value === "__all__" ? "" : value)}>
              <SelectTrigger className="h-8 w-[120px] text-[13px]">
                <SelectValue placeholder="按 BMI 筛选" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="__all__">全部 BMI</SelectItem>
                {BMI_FILTER_OPTIONS.map((option) => (
                  <SelectItem key={option.value} value={option.value}>
                    {option.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Select value={w.selectedFilter} onValueChange={w.setSelectedFilter}>
              <SelectTrigger className="h-8 w-[140px] text-[13px]">
                <SelectValue placeholder="按标签筛选" />
              </SelectTrigger>
              <SelectContent>
                {w.dynamicTagFilters.map((name) => (
                  <SelectItem key={name} value={name}>
                    {name === "全部" ? "全部标签" : name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </FilterBar>

          <div className="flex min-h-0 min-w-0 flex-1 flex-col space-y-3">
            <DataTable
              columns={visibleColumns}
              rows={w.filteredClients}
              rowKey={(row) => row.id}
              loading={w.isLoading}
              selectable
              selectedKeys={selection.selectedKeys}
              onToggleRow={(key) => selection.toggle(key)}
              onToggleAll={selection.toggleAll}
              allSelected={selection.allSelected}
              someSelected={selection.someSelected}
              activeKey={w.selectedClient ?? undefined}
              onRowClick={(row) => {
                w.setSelectedClient(row.id);
                setSheetMode("detail");
              }}
              emptySlot={
                <div className="space-y-2">
                  <p className="pc-body text-muted-foreground">
                    {w.hasActiveFilters ? "没有符合条件的客户" : "还没有客户"}
                  </p>
                  {!w.hasActiveFilters && (
                    <Button size="sm" className="h-8" onClick={() => w.setShowAddDialog(true)}>
                      <Plus className="mr-1 h-3.5 w-3.5" />
                      新增第一位客户
                    </Button>
                  )}
                </div>
              }
              className="min-h-0 flex-1 [&>div]:h-full"
            />

            {w.totalRows > 0 && (
              <ListPagination
                page={w.page}
                totalPages={w.totalPages}
                onPageChange={w.setPage}
                total={w.totalRows}
                pageSize={w.pageSize}
                pageSizeOptions={[10, 20, 50]}
                onPageSizeChange={w.setPageSize}
                showFirstLast
                showPageJump
              />
            )}
          </div>
        </div>

        <Sheet open={Boolean(w.selectedClient)} onOpenChange={(open) => !open && handleSheetCloseRequest()}>
          <SheetContent
            side="right"
            className="w-full min-h-0 overflow-hidden bg-background p-0 sm:max-w-[560px] [&>button]:hidden [&>section]:rounded-none [&>section]:border-0"
          >
            <SheetHeader className="sr-only">
              <SheetTitle>{sheetMode === "edit" ? "编辑客户" : "客户详情"}</SheetTitle>
            </SheetHeader>
            {w.selectedClientData &&
              (sheetMode === "edit" ? (
                <ClientEditSheet
                  value={w.clientForm}
                  onChange={w.setClientForm}
                  submitting={w.isUpdating}
                  onSubmit={handleSheetEditSave}
                  onCancel={() => {
                    if (editDirty) setShowUnsavedConfirm(true);
                    else setSheetMode("detail");
                  }}
                />
              ) : (
                <ClientDetailPanel
                  client={w.selectedClientData}
                  allTags={w.tags}
                  phoneText={w.formatClientPhoneDetail(w.selectedClientData)}
                  lastContactText={w.formatTime(w.selectedClientData?.last_contact_at ?? null)}
                  onToggleTag={w.handleToggleClientTag}
                  onCreateTag={() => w.setShowCreateTagDialog(true)}
                  onFollowUp={() => w.setShowFollowUpDialog(true)}
                  onEdit={() => w.selectedClientData && openEditInSheet(w.selectedClientData)}
                  onDelete={() => {
                    if (!w.selectedClientData) return;
                    w.setDeleteTargetId(w.selectedClientData.id);
                    w.setShowDeleteConfirm(true);
                  }}
                  onOpenProfile={() =>
                    w.selectedClientData && navigate(`/merchant/clients/${w.selectedClientData.client_id}`)
                  }
                  onClose={() => w.setSelectedClient(null)}
                  onUpdateReminder={w.updateFollowUpReminder}
                  updatingReminder={w.isUpdatingFollowUpReminder}
                />
              ))}
          </SheetContent>
        </Sheet>

        <UnsavedLeaveDialog
          open={showUnsavedConfirm}
          title="放弃未保存的修改？"
          description="现在离开，刚才填的客户信息会丢掉。"
          stayLabel="继续编辑"
          leaveLabel="不保存，离开"
          onStay={() => setShowUnsavedConfirm(false)}
          onLeave={closeClientSheet}
        />
      </div>

      <BulkActionBar count={selection.count} noun="位客户" onClear={selection.clear}>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button size="sm" variant="outline" className="h-8">
              <Tag className="mr-1 h-3.5 w-3.5" />
              批量打标签
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="center">
            <DropdownMenuLabel className="text-xs">给已选客户加上</DropdownMenuLabel>
            {w.tags.length === 0 && <DropdownMenuItem disabled>还没有标签</DropdownMenuItem>}
            {w.tags.map((tag) => (
              <DropdownMenuItem key={tag.id} onClick={() => bulkAddTag(tag.id)}>
                {tag.name}
              </DropdownMenuItem>
            ))}
          </DropdownMenuContent>
        </DropdownMenu>
        <Button size="sm" variant="outline" className="h-8" onClick={exportSelected}>
          <Download className="mr-1 h-3.5 w-3.5" />
          导出所选
        </Button>
      </BulkActionBar>

      <ClientFormDialog
        open={w.showAddDialog}
        onOpenChange={w.setShowAddDialog}
        title="新增客户"
        description="昵称或手机号填一个就能建档"
        submitLabel="添加客户"
        submitting={w.isCreating}
        value={w.clientForm}
        onChange={w.setClientForm}
        onSubmit={w.handleAddClient}
      />

      <ClientFollowUpDialog
        open={w.showFollowUpDialog}
        onOpenChange={w.setShowFollowUpDialog}
        clientName={
          w.selectedClientData
            ? w.selectedClientData.customer_name || w.selectedClientData.profile?.nickname
            : undefined
        }
        type={w.followUpType}
        onTypeChange={w.setFollowUpType}
        content={w.followUpContent}
        onContentChange={w.setFollowUpContent}
        nextFollowUpAt={w.followUpNextAt}
        onNextFollowUpAtChange={w.setFollowUpNextAt}
        reminder={w.followUpReminder}
        onReminderChange={w.setFollowUpReminder}
        reminderWecom={w.followUpWecom}
        onReminderWecomChange={w.setFollowUpWecom}
        onSubmit={w.handleAddFollowUp}
        submitting={w.isAddingFollowUp}
      />

      <ClientTagCreateDialog
        open={w.showCreateTagDialog}
        onOpenChange={w.setShowCreateTagDialog}
        name={w.newTagName}
        onNameChange={w.setNewTagName}
        color={w.newTagColor}
        onColorChange={w.setNewTagColor}
        onSubmit={w.handleCreateTag}
      />

      <AlertDialog open={w.showDeleteConfirm} onOpenChange={w.setShowDeleteConfirm}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>将客户移入回收站？</AlertDialogTitle>
            <AlertDialogDescription>
              移入回收站不会删除标签、跟进记录或健康数据。可在回收站恢复或彻底删除。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                w.handleConfirmDelete();
                w.setSelectedClient(null);
              }}
            >
              移入回收站
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <ClientRecycleBinSheet open={showRecycleBin} onOpenChange={setShowRecycleBin} />
    </PageContainer>
  );
}
