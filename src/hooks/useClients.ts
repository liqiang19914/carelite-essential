import { useEffect, useMemo, useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { getDb } from "@/lib/pglite-db";
import { useAuth } from "@/contexts/AuthContext";
import { softDeleteClientRelation } from "@/services/clientRelations";
import type { BmiStatus } from "@/types/app/bmiStatus";
import { toast } from "sonner";
import { rpcErrorMessage } from "@/lib/rpc-error";

export type ReminderStatus = "none" | "overdue" | "today" | "upcoming";

export interface ClientWithProfile {
  id: string;
  client_id: string;
  status: string;
  notes: string | null;
  last_contact_at: string | null;
  created_at: string;
  customer_name: string | null;
  profile: {
    nickname: string | null;
    phone: string | null;
    avatar_url: string | null;
  } | null;
  tags: { id: string; name: string; color: string }[];
  canManage: boolean;
  canFollowUp: boolean;
  next_reminder_at: string | null;
  reminder_status: ReminderStatus;
  bmi_status: BmiStatus;
  profileName: string | null;
}

export interface FollowUpRecord {
  id: string;
  client_relation_id: string;
  content: string;
  follow_up_type: string | null;
  next_follow_up_at: string | null;
  reminder: boolean;
  reminder_wecom: boolean;
  reminded_at: string | null;
  created_by: string | null;
  created_at: string;
  creator_nickname: string | null;
}

export interface ClientFilters {
  createdFrom?: string | null;
  createdTo?: string | null;
  reminderFrom?: string | null;
  reminderTo?: string | null;
  bmiStatus?: string | null;
  search?: string | null;
  enabled?: boolean;
}

export interface ClientPagination {
  page?: number;
  pageSize?: number;
}

export interface ClientPage {
  clients: ClientWithProfile[];
  total: number;
}

const DEFAULT_PAGE_SIZE = 20;

function useDebouncedValue<T>(value: T, delay = 300): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), delay);
    return () => clearTimeout(timer);
  }, [value, delay]);
  return debounced;
}

export function useClients(filters: ClientFilters = {}, pagination?: ClientPagination) {
  const { user } = useAuth();
  const queryClient = useQueryClient();

  const debouncedSearch = useDebouncedValue(filters.search ?? null);
  const paged = Boolean(pagination);
  const pageSize = pagination?.pageSize ?? DEFAULT_PAGE_SIZE;
  const page = pagination?.page ?? 1;

  // 获取客户列表：单健康师视角，PGlite 直查
  const clientsQuery = useQuery({
    queryKey: [
      "clients",
      user?.id,
      debouncedSearch,
      filters.createdFrom ?? null,
      filters.createdTo ?? null,
      filters.reminderFrom ?? null,
      filters.reminderTo ?? null,
      filters.bmiStatus ?? null,
      paged ? page : null,
      paged ? pageSize : null,
    ],
    queryFn: async (): Promise<ClientPage> => {
      if (!user) return { clients: [], total: 0 };

      const db = await getDb();

      // 构建 WHERE 条件
      const conditions: string[] = [`cr.manager_id = $1`, `cr.status != 'deleted'`];
      const params: unknown[] = [user.id];
      let paramIndex = 2;

      if (debouncedSearch) {
        conditions.push(`(cr.customer_name ILIKE $${paramIndex} OR p.nickname ILIKE $${paramIndex} OR p.phone ILIKE $${paramIndex})`);
        params.push(`%${debouncedSearch}%`);
        paramIndex++;
      }
      if (filters.createdFrom) {
        conditions.push(`cr.created_at >= $${paramIndex}`);
        params.push(filters.createdFrom);
        paramIndex++;
      }
      if (filters.createdTo) {
        conditions.push(`cr.created_at <= $${paramIndex}::date + interval '1 day'`);
        params.push(filters.createdTo);
        paramIndex++;
      }
      if (filters.reminderFrom) {
        conditions.push(`EXISTS (
          SELECT 1 FROM follow_up_records fr
          WHERE fr.client_relation_id = cr.id
            AND fr.reminder = true
            AND fr.next_follow_up_at >= $${paramIndex}
        )`);
        params.push(filters.reminderFrom);
        paramIndex++;
      }
      if (filters.reminderTo) {
        conditions.push(`EXISTS (
          SELECT 1 FROM follow_up_records fr
          WHERE fr.client_relation_id = cr.id
            AND fr.reminder = true
            AND fr.next_follow_up_at <= $${paramIndex}::date + interval '1 day'
        )`);
        params.push(filters.reminderTo);
        paramIndex++;
      }

      const whereClause = conditions.join(" AND ");

      // 先查总数
      const countResult = await db.query<{ cnt: string }>(
        `SELECT COUNT(*) AS cnt FROM client_relations cr
         LEFT JOIN profiles p ON p.id = cr.client_id
         WHERE ${whereClause}`,
        params,
      );
      const total = Number(countResult.rows[0]?.cnt ?? 0);

      // 再查分页数据
      const limit = paged ? pageSize : 1000;
      const offset = paged ? (page - 1) * pageSize : 0;

      const rowsResult = await db.query<{
        id: string;
        client_id: string;
        status: string;
        notes: string | null;
        last_contact_at: string | null;
        created_at: string;
        customer_name: string | null;
        nickname: string | null;
        phone: string | null;
        avatar_url: string | null;
      }>(
        `SELECT cr.id, cr.client_id, cr.status, cr.notes, cr.last_contact_at, cr.created_at, cr.customer_name,
                p.nickname, p.phone, p.avatar_url
         FROM client_relations cr
         LEFT JOIN profiles p ON p.id = cr.client_id
         WHERE ${whereClause}
         ORDER BY cr.created_at DESC
         LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`,
        [...params, limit, offset],
      );

      const rows = rowsResult.rows;
      if (rows.length === 0) return { clients: [], total };

      // 查标签关联
      const relationIds = rows.map((r) => r.id);
      const { data: tagRelations } = await supabase
        .from("client_tag_relations")
        .select(`client_relation_id, tag:client_tags(id, name, color)`)
        .in("client_relation_id", relationIds);

      // 查每个客户的最近提醒
      const reminderResult = await db.query<{
        client_relation_id: string;
        next_follow_up_at: string;
      }>(
        `SELECT DISTINCT ON (client_relation_id) client_relation_id, next_follow_up_at
         FROM follow_up_records
         WHERE client_relation_id = ANY($1)
           AND reminder = true
           AND next_follow_up_at IS NOT NULL
         ORDER BY client_relation_id, next_follow_up_at DESC`,
        [relationIds],
      );
      const reminderMap = new Map(
        reminderResult.rows.map((r) => [r.client_relation_id, r.next_follow_up_at]),
      );

      // 查 BMI 状态（户主档案身高 + 最新体重）
      const clientIds = rows.map((r) => r.client_id);
      const bmiResult = await db.query<{
        user_id: string;
        bmi_status: string;
      }>(
        `SELECT hr.user_id,
           CASE
             WHEN hr.height IS NULL OR hr.height <= 0 THEN 'no_data'
             WHEN latest.weight IS NULL OR latest.weight <= 0 THEN 'no_data'
             WHEN latest.weight / POWER(hr.height / 100.0, 2) < 18.5 THEN 'underweight'
             WHEN latest.weight / POWER(hr.height / 100.0, 2) < 24 THEN 'normal'
             WHEN latest.weight / POWER(hr.height / 100.0, 2) < 28 THEN 'overweight'
             ELSE 'obese'
           END AS bmi_status
         FROM health_records hr
         LEFT JOIN LATERAL (
           SELECT weight FROM vital_signs vs
           WHERE vs.record_id = hr.id AND vs.weight IS NOT NULL AND vs.weight > 0
           ORDER BY vs.created_at DESC LIMIT 1
         ) latest ON true
         WHERE hr.user_id = ANY($1) AND hr.is_head = true`,
        [clientIds],
      );
      const bmiMap = new Map(bmiResult.rows.map((r) => [r.user_id, r.bmi_status]));

      // 查档案姓名（户主档案的 name）
      const profileNameResult = await db.query<{
        user_id: string;
        name: string;
      }>(
        `SELECT user_id, name FROM health_records
         WHERE user_id = ANY($1) AND is_head = true`,
        [clientIds],
      );
      const profileNameMap = new Map(
        profileNameResult.rows.map((r) => [r.user_id, r.name]),
      );

      const now = new Date();
      const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
      const todayEnd = new Date(todayStart.getTime() + 24 * 60 * 60 * 1000);

      const clients: ClientWithProfile[] = rows.map((row) => {
        const nextReminderAt = reminderMap.get(row.id) ?? null;
        let reminderStatus: ReminderStatus = "none";
        if (nextReminderAt) {
          const d = new Date(nextReminderAt);
          if (d < todayStart) reminderStatus = "overdue";
          else if (d < todayEnd) reminderStatus = "today";
          else reminderStatus = "upcoming";
        }

        const bmiStatus = (bmiMap.get(row.client_id) ?? "no_data") as BmiStatus;

        // BMI 筛选（在内存中做，因为 SQL 已经比较复杂）
        if (filters.bmiStatus && bmiStatus !== filters.bmiStatus) {
          return null;
        }

        return {
          id: row.id,
          client_id: row.client_id,
          status: row.status,
          notes: row.notes,
          last_contact_at: row.last_contact_at,
          created_at: row.created_at,
          customer_name: row.customer_name,
          profile: {
            nickname: row.nickname,
            phone: row.phone,
            avatar_url: row.avatar_url,
          },
          tags:
            tagRelations
              ?.filter((tr) => tr.client_relation_id === row.id)
              .map((tr) => tr.tag as { id: string; name: string; color: string })
              .filter(Boolean) || [],
          canManage: true,
          canFollowUp: true,
          next_reminder_at: nextReminderAt,
          reminder_status: reminderStatus,
          bmi_status: bmiStatus,
          profileName: profileNameMap.get(row.client_id) ?? null,
        };
      }).filter(Boolean) as ClientWithProfile[];

      // 如果做了 BMI 筛选，total 需要重算
      let finalTotal = total;
      if (filters.bmiStatus) {
        finalTotal = clients.length;
      }

      return { clients, total: finalTotal };
    },
    enabled: !!user && (filters.enabled ?? true),
  });

  // 获取标签列表
  const tagsQuery = useQuery({
    queryKey: ["client_tags", user?.id],
    queryFn: async () => {
      if (!user) return [];
      const { data, error } = await supabase
        .from("client_tags")
        .select("*")
        .eq("manager_id", user.id)
        .order("created_at");
      if (error) throw error;
      return data;
    },
    enabled: !!user,
  });

  // 添加跟进记录
  const addFollowUpMutation = useMutation({
    mutationFn: async ({
      clientRelationId,
      content,
      followUpType,
      nextFollowUpAt,
      reminder,
      reminderWecom,
    }: {
      clientRelationId: string;
      content: string;
      followUpType?: string;
      nextFollowUpAt?: string | null;
      reminder?: boolean;
      reminderWecom?: boolean;
    }) => {
      if (!user) throw new Error("未登录");
      const { error } = await supabase.from("follow_up_records").insert({
        client_relation_id: clientRelationId,
        content,
        follow_up_type: followUpType || null,
        next_follow_up_at: nextFollowUpAt || null,
        reminder: Boolean(reminder),
        reminder_wecom: Boolean(reminderWecom),
        created_by: user.id,
      });
      if (error) throw error;

      // 更新最近联系时间
      await supabase
        .from("client_relations")
        .update({ last_contact_at: new Date().toISOString() })
        .eq("id", clientRelationId);
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["clients"] });
      queryClient.invalidateQueries({ queryKey: ["follow_up_records"] });
      toast.success("跟进记录已添加");
    },
    onError: (error) => {
      toast.error(error.message);
    },
  });

  // 修改跟进提醒
  const updateFollowUpReminderMutation = useMutation({
    mutationFn: async ({
      recordId,
      content,
      followUpType,
      nextFollowUpAt,
      reminder,
      reminderWecom,
    }: {
      recordId: string;
      content?: string | null;
      followUpType?: string | null;
      nextFollowUpAt?: string | null;
      reminder?: boolean | null;
      reminderWecom?: boolean | null;
    }) => {
      const updates: Record<string, unknown> = {};
      if (content !== undefined) updates.content = content;
      if (followUpType !== undefined) updates.follow_up_type = followUpType;
      if (nextFollowUpAt !== undefined) updates.next_follow_up_at = nextFollowUpAt;
      if (reminder !== undefined) updates.reminder = reminder;
      if (reminderWecom !== undefined) updates.reminder_wecom = reminderWecom;

      const { error } = await supabase
        .from("follow_up_records")
        .update(updates)
        .eq("id", recordId);
      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["clients"] });
      queryClient.invalidateQueries({ queryKey: ["follow_up_records"] });
      toast.success("提醒设置已更新");
    },
    onError: (error) => {
      toast.error(error.message);
    },
  });

  // 创建标签
  const createTagMutation = useMutation({
    mutationFn: async ({ name, color }: { name: string; color?: string }) => {
      if (!user) throw new Error("未登录");
      const { data, error } = await supabase
        .from("client_tags")
        .insert({ manager_id: user.id, name, color: color || "blue" })
        .select()
        .single();
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["client_tags"] });
      toast.success("标签创建成功");
    },
    onError: (error) => {
      toast.error("创建失败: " + error.message);
    },
  });

  // 给客户添加标签
  const addTagToClientMutation = useMutation({
    mutationFn: async ({ clientRelationId, tagId }: { clientRelationId: string; tagId: string }) => {
      const { error } = await supabase
        .from("client_tag_relations")
        .insert({ client_relation_id: clientRelationId, tag_id: tagId });
      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["clients"] });
      toast.success("标签已添加");
    },
    onError: (error) => {
      toast.error("添加失败: " + error.message);
    },
  });

  // 移除客户标签
  const removeTagFromClientMutation = useMutation({
    mutationFn: async ({ clientRelationId, tagId }: { clientRelationId: string; tagId: string }) => {
      const { error } = await supabase
        .from("client_tag_relations")
        .delete()
        .eq("client_relation_id", clientRelationId)
        .eq("tag_id", tagId);
      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["clients"] });
      toast.success("标签已移除");
    },
    onError: (error) => {
      toast.error("移除失败: " + error.message);
    },
  });

  // 新增客户：建档 + 建立归属关系
  const createClientMutation = useMutation({
    mutationFn: async ({ nickname, phone, notes }: {
      nickname: string;
      phone?: string;
      notes?: string;
    }) => {
      if (!user) throw new Error("未登录");

      const digits = phone ? phone.replace(/\D/g, "").replace(/^(?:86)+/, "") : "";

      // 先检查是否已有该手机号的用户
      let clientId: string;
      if (digits) {
        const { data: existing } = await supabase
          .from("profiles")
          .select("id")
          .eq("phone", digits)
          .single();
        if (existing) {
          clientId = existing.id;
        } else {
          // 创建新用户档案
          const { data: newProfile, error: profileError } = await supabase
            .from("profiles")
            .insert({
              id: crypto.randomUUID(),
              nickname: nickname || "未命名客户",
              phone: digits,
              role: "user",
            })
            .select("id")
            .single();
          if (profileError) throw profileError;
          clientId = newProfile.id;
        }
      } else {
        // 无手机号，直接创建档案
        const { data: newProfile, error: profileError } = await supabase
          .from("profiles")
          .insert({
            id: crypto.randomUUID(),
            nickname: nickname || "未命名客户",
            role: "user",
          })
          .select("id")
          .single();
        if (profileError) throw profileError;
        clientId = newProfile.id;
      }

      // 检查是否已存在关系
      const { data: existingRelation } = await supabase
        .from("client_relations")
        .select("id")
        .eq("manager_id", user.id)
        .eq("client_id", clientId)
        .single();

      if (existingRelation) {
        // 如果已存在且被删除，恢复它
        const { error: restoreError } = await supabase
          .from("client_relations")
          .update({ status: "active", notes: notes || "" })
          .eq("id", existingRelation.id);
        if (restoreError) throw restoreError;
        return existingRelation.id;
      }

      // 创建关系
      const { data: relation, error: relationError } = await supabase
        .from("client_relations")
        .insert({
          manager_id: user.id,
          client_id: clientId,
          customer_name: nickname || "未命名客户",
          notes: notes || "",
        })
        .select("id")
        .single();
      if (relationError) throw relationError;
      return relation.id;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["clients"] });
      queryClient.invalidateQueries({ queryKey: ["client-recycle-bin"] });
      toast.success("客户添加成功");
    },
    onError: (error) => {
      const isGuideError = /已达上限|负责/.test(error.message);
      toast.error(isGuideError ? error.message : rpcErrorMessage(error, "添加失败，请稍后重试"));
    },
  });

  // 更新客户信息
  const updateClientMutation = useMutation({
    mutationFn: async ({ clientRelationId, nickname, notes }: {
      clientRelationId: string;
      clientId: string;
      nickname: string;
      phone?: string;
      notes?: string;
    }) => {
      const { error } = await supabase
        .from("client_relations")
        .update({
          customer_name: nickname.trim() || "未命名客户",
          notes: notes || "",
        })
        .eq("id", clientRelationId);
      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["clients"] });
      toast.success("客户信息已更新");
    },
    onError: (error) => {
      toast.error("更新失败：" + error.message);
    },
  });

  // 删除客户：软删除进回收站
  const deleteClientMutation = useMutation({
    mutationFn: async (clientRelationId: string) => {
      await softDeleteClientRelation(clientRelationId);
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["clients"] });
      queryClient.invalidateQueries({ queryKey: ["client-recycle-bin"] });
      toast.success("客户已移入回收站");
    },
    onError: (error) => {
      toast.error("移入回收站失败：" + error.message);
    },
  });

  return {
    clients: clientsQuery.data?.clients ?? [],
    total: clientsQuery.data?.total ?? 0,
    tags: tagsQuery.data ?? [],
    isLoading: clientsQuery.isLoading,
    isError: clientsQuery.isError,
    refetch: clientsQuery.refetch,
    createClient: createClientMutation.mutateAsync,
    isCreating: createClientMutation.isPending,
    updateClient: updateClientMutation.mutateAsync,
    isUpdating: updateClientMutation.isPending,
    addFollowUp: addFollowUpMutation.mutateAsync,
    isAddingFollowUp: addFollowUpMutation.isPending,
    updateFollowUpReminder: updateFollowUpReminderMutation.mutateAsync,
    isUpdatingFollowUpReminder: updateFollowUpReminderMutation.isPending,
    createTag: createTagMutation.mutate,
    addTagToClient: addTagToClientMutation.mutate,
    removeTagFromClient: removeTagFromClientMutation.mutate,
    deleteClient: deleteClientMutation.mutate,
  };
}

// 获取单个客户的跟进记录
export function useFollowUpRecords(clientRelationId: string | null) {
  return useQuery({
    queryKey: ["follow_up_records", clientRelationId],
    queryFn: async (): Promise<FollowUpRecord[]> => {
      if (!clientRelationId) return [];

      const { data, error } = await supabase
        .from("follow_up_records")
        .select("id, client_relation_id, content, follow_up_type, next_follow_up_at, reminder, reminder_wecom, reminded_at, created_by, created_at")
        .eq("client_relation_id", clientRelationId)
        .order("created_at", { ascending: false });

      if (error) throw error;
      const rows = (data ?? []) as unknown as FollowUpRecord[];

      const creatorIds = [
        ...new Set(rows.map((row) => row.created_by).filter(Boolean)),
      ] as string[];
      let nicknameById = new Map<string, string>();
      if (creatorIds.length > 0) {
        const { data: profiles } = await supabase
          .from("profiles")
          .select("id, nickname")
          .in("id", creatorIds);
        nicknameById = new Map(
          (profiles ?? []).map((p: { id: string; nickname: string }) => [p.id, p.nickname]),
        );
      }

      return rows.map((row) => ({
        ...row,
        creator_nickname: row.created_by
          ? nicknameById.get(row.created_by) ?? null
          : null,
      }));
    },
    enabled: !!clientRelationId,
  });
}
