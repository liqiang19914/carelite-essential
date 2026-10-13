import { useState } from "react";
import { RotateCcw, Search, Trash2 } from "lucide-react";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
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
import DataTable, { type DataTableColumn } from "@/components/desktop/data/DataTable";
import ListPagination from "@/components/desktop/ListPagination";
import { useClientRecycleBin } from "@/hooks/useClientRecycleBin";
import type { DeletedClient } from "@/hooks/useClientRecycleBin";
import { toast } from "sonner";

interface ClientRecycleBinSheetProps {
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
}

function formatDeletedAt(value: string | null): string {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return date.toLocaleString("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export default function ClientRecycleBinSheet({
  open = false,
  onOpenChange,
}: ClientRecycleBinSheetProps) {
  const recycle = useClientRecycleBin({ enabled: open });
  const [purgeTarget, setPurgeTarget] = useState<DeletedClient | null>(null);

  const handleRestore = async (item: DeletedClient) => {
    try {
      await recycle.restore(item.relationId);
      toast.success(`已恢复客户「${item.customerName}」`);
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "恢复失败，请重试");
    }
  };

  const handlePurgeConfirm = async () => {
    if (!purgeTarget) return;
    try {
      await recycle.purge(purgeTarget.relationId);
      toast.success(`已彻底删除「${purgeTarget.customerName}」`);
      setPurgeTarget(null);
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "删除失败，请重试");
    }
  };

  const totalPages = Math.max(1, Math.ceil(recycle.total / recycle.pageSize));

  const columns: DataTableColumn<DeletedClient>[] = [
    {
      key: "client",
      header: "客户",
      cell: (row) => (
        <div className="flex items-center gap-2">
          <Avatar className="h-6 w-6">
            <AvatarFallback className="text-[10px]">
              {row.customerName.charAt(0) || "客"}
            </AvatarFallback>
          </Avatar>
          <span className="truncate font-medium">{row.customerName}</span>
        </div>
      ),
    },
    {
      key: "phone",
      header: "手机号",
      width: "w-[130px]",
      cell: (row) => <span className="pc-num text-muted-foreground">{row.phone || "—"}</span>,
    },
    {
      key: "deleted_at",
      header: "删除时间",
      width: "w-[150px]",
      cell: (row) => <span className="text-muted-foreground">{formatDeletedAt(row.deletedAt)}</span>,
    },
    {
      key: "actions",
      header: "操作",
      width: "w-[170px]",
      align: "right",
      cell: (row) => (
        <div className="flex items-center justify-end gap-1.5">
          <Button
            variant="outline"
            size="sm"
            className="h-7 text-xs"
            disabled={recycle.isRestoring}
            onClick={() => handleRestore(row)}
          >
            <RotateCcw className="mr-1 h-3 w-3" />
            恢复
          </Button>
          <Button
            variant="outline"
            size="sm"
            className="h-7 text-xs text-destructive hover:text-destructive"
            disabled={recycle.isPurging}
            onClick={() => setPurgeTarget(row)}
          >
            <Trash2 className="mr-1 h-3 w-3" />
            彻底删除
          </Button>
        </div>
      ),
    },
  ];

  return (
    <>
      <Sheet open={open} onOpenChange={onOpenChange}>
        <SheetContent side="right" className="w-full min-h-0 overflow-hidden p-0 sm:max-w-[640px]">
          <SheetHeader className="border-b px-5 py-4 text-left">
            <SheetTitle className="flex items-center gap-2">
              <Trash2 className="h-4 w-4" />
              回收站
            </SheetTitle>
            <SheetDescription>
              删除的客户会先到这里。恢复后回到客户列表；彻底删除将永久清除客户关系与跟进记录，客户本人的健康数据不受影响。
            </SheetDescription>
          </SheetHeader>
          <div className="flex min-h-0 flex-1 flex-col gap-3 px-5 pb-5">
            <div className="relative">
              <Search className="absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={recycle.search}
                onChange={(event) => {
                  recycle.setSearch(event.target.value);
                  recycle.setPage(1);
                }}
                placeholder="搜姓名"
                className="h-8 pl-8"
              />
            </div>
            <DataTable
              columns={columns}
              rows={recycle.items}
              rowKey={(row) => row.relationId}
              loading={recycle.isLoading}
              className="min-h-0 flex-1 [&>div]:h-full"
              emptySlot={
                recycle.isError ? (
                  <div className="space-y-2">
                    <p className="pc-body text-muted-foreground">回收站加载失败</p>
                    <Button size="sm" className="h-8" onClick={() => recycle.refetch()}>
                      重试
                    </Button>
                  </div>
                ) : (
                  <div className="space-y-2">
                    <p className="pc-body text-muted-foreground">
                      {recycle.search.trim() ? "没有符合条件的记录" : "回收站是空的"}
                    </p>
                    {!recycle.search.trim() && (
                      <p className="pc-caption text-muted-foreground">
                        删除客户后，客户会先出现在这里，误删可随时恢复。
                      </p>
                    )}
                  </div>
                )
              }
            />
            {recycle.total > 0 && (
              <ListPagination
                page={recycle.page}
                totalPages={totalPages}
                onPageChange={recycle.setPage}
                total={recycle.total}
                pageSize={recycle.pageSize}
                showFirstLast
                showPageJump
              />
            )}
          </div>
        </SheetContent>
      </Sheet>

      <AlertDialog open={Boolean(purgeTarget)} onOpenChange={(open) => !open && setPurgeTarget(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>彻底删除「{purgeTarget?.customerName ?? ""}」？</AlertDialogTitle>
            <AlertDialogDescription>
              将永久删除该客户的标签、跟进记录，无法恢复。客户本人的健康数据不受影响。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              disabled={recycle.isPurging}
              onClick={handlePurgeConfirm}
            >
              彻底删除
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}
