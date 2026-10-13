import { useEffect, useMemo, useState } from "react";
import { useClients, type ClientFilters } from "@/hooks/useClients";
import { useAuth } from "@/contexts/AuthContext";
import { maskPhone } from "@/lib/phone-mask";

type ClientRow = ReturnType<typeof useClients>["clients"][number];

export const CLIENTS_PAGE_SIZE = 20;

/**
 * 客户管理的业务控制器（开源单健康师版）：
 * 筛选、标签、跟进、增删改的全部状态与动作。
 */
export function useClientsWorkbench() {
  const { user } = useAuth();

  const [searchQuery, setSearchQuery] = useState("");
  const [createdFrom, setCreatedFrom] = useState("");
  const [createdTo, setCreatedTo] = useState("");
  const [reminderFrom, setReminderFrom] = useState("");
  const [reminderTo, setReminderTo] = useState("");
  const [bmiFilter, setBmiFilter] = useState("");

  const filters: ClientFilters = useMemo(
    () => ({
      createdFrom: createdFrom || null,
      createdTo: createdTo || null,
      reminderFrom: reminderFrom || null,
      reminderTo: reminderTo || null,
      bmiStatus: bmiFilter || null,
      search: searchQuery,
    }),
    [createdFrom, createdTo, reminderFrom, reminderTo, bmiFilter, searchQuery],
  );

  const [page, setPage] = useState(1);
  const [pageSize, setPageSizeState] = useState(CLIENTS_PAGE_SIZE);
  const {
    clients,
    total,
    tags,
    isLoading,
    addFollowUp,
    isAddingFollowUp,
    updateFollowUpReminder,
    isUpdatingFollowUpReminder,
    createTag,
    addTagToClient,
    removeTagFromClient,
    deleteClient,
    createClient,
    isCreating,
    updateClient,
    isUpdating,
  } = useClients(filters, { page, pageSize });

  const [selectedFilter, setSelectedFilter] = useState("全部");
  const [showFollowUpDialog, setShowFollowUpDialog] = useState(false);
  const [showCreateTagDialog, setShowCreateTagDialog] = useState(false);
  const [showAddDialog, setShowAddDialog] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [selectedClient, setSelectedClient] = useState<string | null>(null);
  const [followUpContent, setFollowUpContent] = useState("");
  const [followUpType, setFollowUpType] = useState("phone");
  const [followUpNextAt, setFollowUpNextAt] = useState("");
  const [followUpReminder, setFollowUpReminder] = useState(false);
  const [followUpWecom, setFollowUpWecom] = useState(false);
  const [newTagName, setNewTagName] = useState("");
  const [newTagColor, setNewTagColor] = useState("blue");
  const [deleteTargetId, setDeleteTargetId] = useState<string | null>(null);

  const hasActiveFilters =
    Boolean(searchQuery) ||
    selectedFilter !== "全部" ||
    Boolean(createdFrom) ||
    Boolean(createdTo) ||
    Boolean(reminderFrom) ||
    Boolean(reminderTo) ||
    Boolean(bmiFilter);

  const resetFilters = () => {
    setSearchQuery("");
    setSelectedFilter("全部");
    setCreatedFrom("");
    setCreatedTo("");
    setReminderFrom("");
    setReminderTo("");
    setBmiFilter("");
  };

  // 筛选条件一变就回第一页
  useEffect(() => {
    setPage(1);
  }, [searchQuery, createdFrom, createdTo, reminderFrom, reminderTo, selectedFilter, bmiFilter]);

  // 标签筛选（客户端过滤，标签数据在客户端）
  const tagFilteredClients = useMemo(() => {
    if (selectedFilter === "全部") return clients;
    return clients.filter((client) =>
      client.tags.some((tagItem) => tagItem.name === selectedFilter),
    );
  }, [clients, selectedFilter]);

  const totalRows = total;
  const totalPages = Math.max(1, Math.ceil(totalRows / pageSize));

  // 空页回退
  useEffect(() => {
    if (page > totalPages) setPage(totalPages);
  }, [page, totalPages]);

  // 动态标签筛选列表
  const dynamicTagFilters = useMemo(() => {
    return ["全部", ...tags.map((tag) => tag.name)];
  }, [tags]);

  // 当前选中客户
  const selectedClientData = useMemo(() => {
    if (!selectedClient) return null;
    return clients.find((c) => c.id === selectedClient) || null;
  }, [selectedClient, clients]);

  // 新增/编辑表单状态
  const [clientForm, setClientForm] = useState({
    nickname: "",
    phone: "",
    notes: "",
  });
  const [editingClient, setEditingClient] = useState<{
    relationId: string;
    clientId: string;
  } | null>(null);

  const formatPhoneRaw = (phone: string | null | undefined) => {
    if (!phone) return "未绑定";
    const clean = phone.replace("+86", "");
    return clean || "未绑定";
  };

  const formatClientPhoneList = (client: ClientRow | null | undefined) => {
    if (!client) return "未绑定";
    const raw = formatPhoneRaw(client.profile?.phone);
    if (raw === "未绑定") return raw;
    return maskPhone(raw);
  };

  const formatClientPhoneDetail = (client: ClientRow | null | undefined) => {
    if (!client) return "未绑定";
    const raw = formatPhoneRaw(client.profile?.phone);
    if (raw === "未绑定") return raw;
    return maskPhone(raw);
  };

  const formatTime = (time: string | null) => {
    if (!time) return "暂无记录";
    const date = new Date(time);
    const now = new Date();
    const diff = now.getTime() - date.getTime();
    const days = Math.floor(diff / (1000 * 60 * 60 * 24));

    if (days === 0) {
      return (
        "今天 " +
        date.toLocaleTimeString("zh-CN", {
          hour: "2-digit",
          minute: "2-digit",
        })
      );
    } else if (days === 1) {
      return "昨天";
    } else if (days < 7) {
      return `${days}天前`;
    } else {
      return date.toLocaleDateString("zh-CN");
    }
  };

  // 新增客户
  const handleAddClient = async () => {
    if (!clientForm.nickname.trim() && !clientForm.phone.trim()) return;
    await createClient({
      nickname: clientForm.nickname.trim(),
      phone: clientForm.phone.trim() || undefined,
      notes: clientForm.notes.trim() || undefined,
    });
    setShowAddDialog(false);
    setClientForm({ nickname: "", phone: "", notes: "" });
  };

  // 编辑客户
  const handleEditClient = async () => {
    if (!editingClient) return;
    await updateClient({
      clientRelationId: editingClient.relationId,
      clientId: editingClient.clientId,
      nickname: clientForm.nickname.trim(),
      notes: clientForm.notes.trim() || undefined,
    });
    setEditingClient(null);
    setClientForm({ nickname: "", phone: "", notes: "" });
  };

  // 打开编辑弹窗
  const openEditDialog = (client: ClientRow) => {
    setEditingClient({
      relationId: client.id,
      clientId: client.client_id,
    });
    setClientForm({
      nickname: client.customer_name || client.profile?.nickname || "",
      phone: formatPhoneRaw(client.profile?.phone),
      notes: client.notes || "",
    });
  };

  // 确认删除
  const handleConfirmDelete = () => {
    if (deleteTargetId) {
      deleteClient(deleteTargetId);
      setDeleteTargetId(null);
      setShowDeleteConfirm(false);
    }
  };

  // 添加跟进记录
  const handleAddFollowUp = async () => {
    if (!selectedClient || !followUpContent.trim()) return;
    try {
      await addFollowUp({
        clientRelationId: selectedClient,
        content: followUpContent,
        followUpType,
        nextFollowUpAt: followUpNextAt
          ? new Date(followUpNextAt).toISOString()
          : null,
        reminder: followUpReminder,
        reminderWecom: followUpWecom,
      });
      setShowFollowUpDialog(false);
      setFollowUpContent("");
      setFollowUpNextAt("");
      setFollowUpReminder(false);
      setFollowUpWecom(false);
      setSelectedClient(null);
    } catch {
      // 错误提示已由 mutation onError 弹出
    }
  };

  // 创建标签
  const handleCreateTag = () => {
    if (!newTagName.trim()) return;
    createTag({ name: newTagName, color: newTagColor });
    setShowCreateTagDialog(false);
    setNewTagName("");
  };

  // 切换客户标签
  const handleToggleClientTag = (tagId: string) => {
    if (!selectedClient) return;
    const hasTag = selectedClientData?.tags.some((t) => t.id === tagId);
    if (hasTag) {
      removeTagFromClient({ clientRelationId: selectedClient, tagId });
    } else {
      addTagToClient({ clientRelationId: selectedClient, tagId });
    }
  };

  return {
    clients,
    total,
    page,
    setPage,
    pageSize,
    setPageSize: (next: number) => {
      setPageSizeState(next);
      setPage(1);
    },
    totalRows,
    totalPages,
    visibleClients: tagFilteredClients,
    tags,
    isLoading,
    isCreating,
    isUpdating,
    isAddingFollowUp,
    isUpdatingFollowUpReminder,
    deleteClient,
    addTagToClient,
    removeTagFromClient,
    updateFollowUpReminder,
    searchQuery,
    setSearchQuery,
    selectedFilter,
    setSelectedFilter,
    createdFrom,
    setCreatedFrom,
    createdTo,
    setCreatedTo,
    reminderFrom,
    setReminderFrom,
    reminderTo,
    setReminderTo,
    bmiFilter,
    setBmiFilter,
    hasActiveFilters,
    resetFilters,
    showFollowUpDialog,
    setShowFollowUpDialog,
    showCreateTagDialog,
    setShowCreateTagDialog,
    showAddDialog,
    setShowAddDialog,
    showDeleteConfirm,
    setShowDeleteConfirm,
    selectedClient,
    setSelectedClient,
    followUpContent,
    setFollowUpContent,
    followUpType,
    setFollowUpType,
    followUpNextAt,
    setFollowUpNextAt,
    followUpReminder,
    setFollowUpReminder,
    followUpWecom,
    setFollowUpWecom,
    newTagName,
    setNewTagName,
    newTagColor,
    setNewTagColor,
    deleteTargetId,
    setDeleteTargetId,
    user,
    dynamicTagFilters,
    selectedClientData,
    clientForm,
    setClientForm,
    editingClient,
    setEditingClient,
    filteredClients: tagFilteredClients,
    formatPhoneRaw,
    formatClientPhoneList,
    formatClientPhoneDetail,
    formatTime,
    handleAddClient,
    handleEditClient,
    openEditDialog,
    handleConfirmDelete,
    handleAddFollowUp,
    handleCreateTag,
    handleToggleClientTag,
  };
}

export type ClientsWorkbench = ReturnType<typeof useClientsWorkbench>;
export type { ClientRow };
