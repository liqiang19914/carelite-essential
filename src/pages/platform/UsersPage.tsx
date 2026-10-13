import { useState, useMemo, useEffect } from "react";
import { useNavigate } from "react-router-dom";
import {
  Search,
  MoreHorizontal,
  UserCheck,
  UserX,
  Eye,
  Loader2,
  KeyRound,
  Trash2,
} from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
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
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";
import { useIsMobile } from "@/hooks/useIsMobile";
import { useUsers, UserWithStats } from "@/hooks/useUsers";
import ListPagination from "@/components/desktop/ListPagination";
import RegisteredDateRangeFilter, { type DateRangeValue } from "@/components/desktop/RegisteredDateRangeFilter";
import { usePagination } from "@/hooks/usePagination";
import { toast } from "sonner";
import QueryErrorState from "@/components/QueryErrorState";

function formatPhone(phone: string | null): string {
  if (!phone) return "-";
  const cleanPhone = phone.replace("+86", "");
  if (cleanPhone.length >= 11) {
    return `${cleanPhone.slice(0, 3)}****${cleanPhone.slice(-4)}`;
  }
  return phone;
}

function formatDate(dateString: string): string {
  const date = new Date(dateString);
  return date.toLocaleDateString("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
}

function getStatusLabel(isDisabled: boolean): string {
  return isDisabled ? "已禁用" : "正常";
}

export default function UsersPage() {
  const navigate = useNavigate();
  const {
    users,
    stats,
    isLoading,
    isUsersError,
    error,
    isStatsError,
    refetch,
    toggleUserStatus,
    resetPassword,
    deleteUser,
    isUpdating,
    isDeleting,
  } = useUsers({ role: "user" });

  const [searchQuery, setSearchQuery] = useState("");
  const [dateRange, setDateRange] = useState<DateRangeValue | undefined>(undefined);

  const [selectedUser, setSelectedUser] = useState<UserWithStats | null>(null);
  const [showDisableDialog, setShowDisableDialog] = useState(false);
  const [showEnableDialog, setShowEnableDialog] = useState(false);
  const [showDeleteDialog, setShowDeleteDialog] = useState(false);
  const [disableReason, setDisableReason] = useState("");

  const [showResetPassword, setShowResetPassword] = useState(false);
  const [resetPasswordValue, setResetPasswordValue] = useState("");
  const [isResetting, setIsResetting] = useState(false);

  const filteredUsers = useMemo(() => {
    return users.filter((user) => {
      const matchesSearch =
        (user.nickname?.toLowerCase() || "").includes(searchQuery.toLowerCase()) ||
        (user.phone || "").includes(searchQuery);

      const createdAt = new Date(user.created_at);
      const matchesDateFrom = !dateRange?.from || createdAt >= dateRange.from;
      const matchesDateTo =
        !dateRange?.to || createdAt <= new Date(dateRange.to.getTime() + 24 * 60 * 60 * 1000 - 1);

      return matchesSearch && matchesDateFrom && matchesDateTo;
    });
  }, [users, searchQuery, dateRange]);

  const { page, setPage, totalPages, pageItems: pagedUsers } = usePagination(filteredUsers, { pageSize: 20 });

  useEffect(() => {
    setPage(1);
  }, [searchQuery, dateRange, setPage]);

  const handleDisableUser = () => {
    if (!selectedUser) return;
    toggleUserStatus(
      { userId: selectedUser.id, isDisabled: true, reason: disableReason },
      {
        onSuccess: () => {
          toast.success("已禁用该用户");
          setShowDisableDialog(false);
          setSelectedUser(null);
          setDisableReason("");
        },
        onError: () => toast.error("操作失败，请重试"),
      }
    );
  };

  const handleEnableUser = () => {
    if (!selectedUser) return;
    toggleUserStatus(
      { userId: selectedUser.id, isDisabled: false },
      {
        onSuccess: () => {
          toast.success("已启用该用户");
          setShowEnableDialog(false);
          setSelectedUser(null);
        },
        onError: () => toast.error("操作失败，请重试"),
      }
    );
  };

  const handleResetPassword = async () => {
    if (!selectedUser || !resetPasswordValue) return;
    setIsResetting(true);
    try {
      await resetPassword({ userId: selectedUser.id, newPassword: resetPasswordValue });
      toast.success("密码重置成功");
      setShowResetPassword(false);
      setResetPasswordValue("");
      setSelectedUser(null);
    } catch (e: any) {
      toast.error(e?.message || "重置失败");
    } finally {
      setIsResetting(false);
    }
  };

  const handleDeleteUser = () => {
    if (!selectedUser) return;
    deleteUser(
      { userId: selectedUser.id },
      {
        onSuccess: () => {
          toast.success("账号已删除");
          setShowDeleteDialog(false);
          setSelectedUser(null);
        },
        onError: (error: Error) => toast.error(error.message || "删除失败，请重试"),
      }
    );
  };

  const isMobile = useIsMobile();

  return (
    <div className="space-y-4 md:space-y-6 animate-fade-up px-4 md:px-0">
      {/* Page Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-display text-xl md:text-2xl font-bold">用户管理</h1>
          <p className="text-muted-foreground mt-1 text-sm md:text-base">
            管理平台注册用户账号
          </p>
        </div>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-3 gap-3 md:gap-4">
        {isLoading ? (
          Array.from({ length: 3 }).map((_, i) => (
            <Card key={i}>
              <CardContent className="p-4">
                <Skeleton className="h-8 w-20 mb-1" />
                <Skeleton className="h-4 w-16" />
              </CardContent>
            </Card>
          ))
        ) : isStatsError ? (
          Array.from({ length: 3 }).map((_, i) => (
            <Card key={i}>
              <CardContent className="p-4">
                <p className="text-display text-2xl font-bold text-muted-foreground">—</p>
                <p className="text-sm text-muted-foreground">加载失败</p>
              </CardContent>
            </Card>
          ))
        ) : (
          [
            { label: "用户总数", value: stats.userCount.toLocaleString() },
            { label: "正常", value: stats.activeCount.toLocaleString() },
            { label: "已禁用", value: stats.disabledCount.toLocaleString() },
          ].map((stat) => (
            <Card key={stat.label}>
              <CardContent className="p-4">
                <p className="text-display text-2xl font-bold">{stat.value}</p>
                <p className="text-sm text-muted-foreground">{stat.label}</p>
              </CardContent>
            </Card>
          ))
        )}
      </div>

      {/* Search + Filters */}
      <div className="relative">
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-muted-foreground" />
        <Input
          placeholder="搜索用户姓名、手机号..."
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          className="pl-9"
        />
      </div>

      <div className="flex flex-wrap gap-2">
        <RegisteredDateRangeFilter value={dateRange} onChange={setDateRange} placeholder="注册时间" />
      </div>

      {/* User List - Responsive */}
      {isUsersError ? (
        <QueryErrorState error={error} onRetry={refetch} />
      ) : isMobile ? (
        <div className="space-y-3">
          {isLoading ? (
            Array.from({ length: 4 }).map((_, cardIdx) => (
              <Card key={cardIdx}>
                <CardContent className="p-4">
                  <div className="flex items-center gap-3">
                    <Skeleton className="w-10 h-10 rounded-full" />
                    <div className="flex-1">
                      <Skeleton className="h-4 w-28 mb-1" />
                      <Skeleton className="h-3 w-20" />
                    </div>
                  </div>
                </CardContent>
              </Card>
            ))
          ) : filteredUsers.length === 0 ? (
            <Card>
              <CardContent className="p-8 text-center">
                <p className="text-muted-foreground">暂无用户账号</p>
              </CardContent>
            </Card>
          ) : (
            pagedUsers.map((user) => {
              const displayName = user.nickname || "未设置昵称";
              return (
                <Card
                  key={user.id}
                  className="cursor-pointer active:bg-muted/50 transition-colors"
                  onClick={() => navigate(`/platform/users/${user.id}`)}
                >
                  <CardContent className="p-4">
                    <div className="flex items-center gap-3">
                      <Avatar className="w-10 h-10">
                        <AvatarImage src={user.avatar_url || undefined} />
                        <AvatarFallback className="text-xs font-medium bg-muted">
                          {displayName.slice(0, 1)}
                        </AvatarFallback>
                      </Avatar>
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center gap-2">
                          <p className="font-medium text-sm truncate">{displayName}</p>
                          <span
                            className={cn(
                              "status-tag text-[10px] py-0 px-1.5",
                              user.is_disabled ? "status-tag-danger" : "status-tag-success"
                            )}
                          >
                            {getStatusLabel(!!user.is_disabled)}
                          </span>
                        </div>
                        <div className="flex items-center gap-3 mt-0.5">
                          <p className="text-xs text-muted-foreground">{formatPhone(user.phone)}</p>
                          <p className="text-xs text-muted-foreground">{user.health_record_count} 份档案</p>
                        </div>
                      </div>
                      <MoreHorizontal className="w-4 h-4 text-muted-foreground flex-shrink-0" />
                    </div>
                  </CardContent>
                </Card>
              );
            })
          )}
        </div>
      ) : (
        <Card>
          <CardContent className="p-0">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>用户</TableHead>
                  <TableHead>状态</TableHead>
                  <TableHead>数据</TableHead>
                  <TableHead>注册时间</TableHead>
                  <TableHead className="w-12"></TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {isLoading ? (
                  Array.from({ length: 5 }).map((_, tableIdx) => (
                    <TableRow key={tableIdx}>
                      <TableCell>
                        <div className="flex items-center gap-3">
                          <Skeleton className="w-9 h-9 rounded-full" />
                          <div>
                            <Skeleton className="h-4 w-24 mb-1" />
                            <Skeleton className="h-3 w-20" />
                          </div>
                        </div>
                      </TableCell>
                      <TableCell><Skeleton className="h-5 w-14" /></TableCell>
                      <TableCell><Skeleton className="h-4 w-24" /></TableCell>
                      <TableCell><Skeleton className="h-4 w-20" /></TableCell>
                      <TableCell><Skeleton className="h-8 w-8" /></TableCell>
                    </TableRow>
                  ))
                ) : filteredUsers.length === 0 ? (
                  <TableRow>
                    <TableCell colSpan={5} className="text-center py-12">
                      <p className="text-muted-foreground">暂无用户账号</p>
                    </TableCell>
                  </TableRow>
                ) : (
                  pagedUsers.map((user) => {
                    const displayName = user.nickname || "未设置昵称";
                    return (
                      <TableRow key={user.id} className="cursor-pointer" onClick={() => navigate(`/platform/users/${user.id}`)}>
                        <TableCell>
                          <div className="flex items-center gap-3">
                            <Avatar className="w-9 h-9">
                              <AvatarImage src={user.avatar_url || undefined} />
                              <AvatarFallback className="text-xs font-medium bg-muted">
                                {displayName.slice(0, 1)}
                              </AvatarFallback>
                            </Avatar>
                            <div>
                              <p className="font-medium">{displayName}</p>
                              <p className="text-xs text-muted-foreground">{formatPhone(user.phone)}</p>
                            </div>
                          </div>
                        </TableCell>
                        <TableCell>
                          <span className={cn("status-tag", user.is_disabled ? "status-tag-danger" : "status-tag-success")}>
                            {getStatusLabel(!!user.is_disabled)}
                          </span>
                        </TableCell>
                        <TableCell>
                          <span className="text-sm text-muted-foreground">
                            {user.health_record_count} 份档案
                          </span>
                        </TableCell>
                        <TableCell className="text-muted-foreground">{formatDate(user.created_at)}</TableCell>
                        <TableCell onClick={(e) => e.stopPropagation()}>
                          <DropdownMenu>
                            <DropdownMenuTrigger asChild>
                              <Button variant="ghost" size="icon" className="w-8 h-8">
                                <MoreHorizontal className="w-4 h-4" />
                              </Button>
                            </DropdownMenuTrigger>
                            <DropdownMenuContent align="end">
                              <DropdownMenuItem onClick={() => navigate(`/platform/users/${user.id}`)}>
                                <Eye className="w-4 h-4 mr-2" />查看详情
                              </DropdownMenuItem>
                              <DropdownMenuItem onClick={() => { setSelectedUser(user); setResetPasswordValue(""); setShowResetPassword(true); }}>
                                <KeyRound className="w-4 h-4 mr-2" />重置密码
                              </DropdownMenuItem>
                              <DropdownMenuSeparator />
                              {user.is_disabled ? (
                                <DropdownMenuItem onClick={() => { setSelectedUser(user); setShowEnableDialog(true); }}>
                                  <UserCheck className="w-4 h-4 mr-2" />启用账户
                                </DropdownMenuItem>
                              ) : (
                                <DropdownMenuItem className="text-destructive" onClick={() => { setSelectedUser(user); setShowDisableDialog(true); }}>
                                  <UserX className="w-4 h-4 mr-2" />禁用账户
                                </DropdownMenuItem>
                              )}
                              <DropdownMenuSeparator />
                              <DropdownMenuItem className="text-destructive" onClick={() => { setSelectedUser(user); setShowDeleteDialog(true); }}>
                                <Trash2 className="w-4 h-4 mr-2" />删除账号
                              </DropdownMenuItem>
                            </DropdownMenuContent>
                          </DropdownMenu>
                        </TableCell>
                      </TableRow>
                    );
                  })
                )}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      )}

      <ListPagination
        page={page}
        totalPages={totalPages}
        onPageChange={setPage}
        total={filteredUsers.length}
        pageSize={20}
        showFirstLast
      />

      {/* 禁用账户确认对话框 */}
      <Dialog open={showDisableDialog} onOpenChange={setShowDisableDialog}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>禁用账户</DialogTitle>
            <DialogDescription>
              确定要禁用用户「{selectedUser?.nickname || "该用户"}」的账户吗？禁用后该用户将无法登录。
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-4">
            <div>
              <Label htmlFor="reason">禁用原因（可选）</Label>
              <Textarea
                id="reason"
                placeholder="请输入禁用原因..."
                value={disableReason}
                onChange={(e) => setDisableReason(e.target.value)}
                className="mt-1.5"
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => { setShowDisableDialog(false); setDisableReason(""); }}>
              取消
            </Button>
            <Button variant="destructive" onClick={handleDisableUser} disabled={isUpdating}>
              {isUpdating && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
              确认禁用
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* 启用账户确认对话框 */}
      <AlertDialog open={showEnableDialog} onOpenChange={setShowEnableDialog}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>启用账户</AlertDialogTitle>
            <AlertDialogDescription>
              确定要启用用户「{selectedUser?.nickname || "该用户"}」的账户吗？
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction onClick={handleEnableUser} disabled={isUpdating}>
              {isUpdating && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
              确认启用
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* 重置密码对话框 */}
      <Dialog open={showResetPassword} onOpenChange={setShowResetPassword}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>重置密码</DialogTitle>
            <DialogDescription>
              为用户「{selectedUser?.nickname || "该用户"}」重置登录密码。
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-4">
            <div>
              <Label>新密码</Label>
              <Input
                type="text"
                placeholder="请输入新密码"
                value={resetPasswordValue}
                onChange={(e) => setResetPasswordValue(e.target.value)}
                className="mt-1.5"
              />
              <p className="text-xs text-muted-foreground mt-1">密码至少6位，请告知用户新密码</p>
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setShowResetPassword(false)}>
              取消
            </Button>
            <Button
              onClick={handleResetPassword}
              disabled={isResetting || !resetPasswordValue || resetPasswordValue.length < 6}
            >
              {isResetting && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
              确认重置
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* 删除账号确认对话框 */}
      <AlertDialog open={showDeleteDialog} onOpenChange={setShowDeleteDialog}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>删除账号</AlertDialogTitle>
            <AlertDialogDescription>
              确定要删除用户「{selectedUser?.nickname || "该用户"}」的账号吗？此操作不可恢复，将永久删除该账号及其所有关联数据（健康档案、体征记录等）。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>取消</AlertDialogCancel>
            <AlertDialogAction
              onClick={handleDeleteUser}
              disabled={isDeleting}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
            >
              {isDeleting && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
              确认删除
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
