import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import bcrypt from "bcryptjs";
import { supabase } from "@/integrations/supabase/client";
import { getDb } from "@/lib/pglite-db";
import type { Profile, UserRole } from "@/integrations/supabase/types";

export interface UserWithStats extends Profile {
  health_record_count: number;
}

interface UsersStats {
  userCount: number;
  activeCount: number;
  disabledCount: number;
}

interface UseUsersOptions {
  role?: UserRole;
}

/**
 * 平台端用户管理（本地 PGlite 版）
 * 数据源：profiles + health_records 聚合，无 Edge Functions。
 */
export function useUsers(options: UseUsersOptions = {}) {
  const { role = "user" } = options;
  const queryClient = useQueryClient();

  const usersQuery = useQuery({
    queryKey: ["admin_users", role],
    queryFn: async (): Promise<UserWithStats[]> => {
      let query = supabase
        .from("profiles")
        .select("*")
        .order("created_at", { ascending: false });
      if (role) query = query.eq("role", role);

      const { data: profiles, error } = await query;
      if (error) throw error;
      if (!profiles || profiles.length === 0) return [];

      // 本地库无 URL 长度限制，一次 GROUP BY 拿全部档案数
      const db = await getDb();
      const counts = await db.query<{ user_id: string; cnt: number | string }>(
        `SELECT user_id, count(*)::int AS cnt FROM health_records GROUP BY user_id`
      );
      const countMap = new Map(counts.rows.map((r) => [r.user_id, Number(r.cnt)]));

      return profiles.map((p) => ({
        ...p,
        health_record_count: countMap.get(p.id) ?? 0,
      }));
    },
  });

  const statsQuery = useQuery({
    queryKey: ["admin_users_stats", role],
    queryFn: async (): Promise<UsersStats> => {
      let query = supabase.from("profiles").select("id, is_disabled");
      if (role) query = query.eq("role", role);
      const { data, error } = await query;
      if (error) throw error;
      const rows = data ?? [];
      const disabledCount = rows.filter((r) => r.is_disabled).length;
      return {
        userCount: rows.length,
        activeCount: rows.length - disabledCount,
        disabledCount,
      };
    },
  });

  const invalidate = () => {
    queryClient.invalidateQueries({ queryKey: ["admin_users"] });
    queryClient.invalidateQueries({ queryKey: ["admin_users_stats"] });
  };

  // 启用/禁用用户
  const toggleUserStatusMutation = useMutation({
    mutationFn: async ({
      userId,
      isDisabled,
      reason,
    }: {
      userId: string;
      isDisabled: boolean;
      reason?: string;
    }) => {
      const { error } = await supabase
        .from("profiles")
        .update({
          is_disabled: isDisabled,
          disabled_at: isDisabled ? new Date().toISOString() : null,
          disabled_reason: isDisabled ? reason || null : null,
        })
        .eq("id", userId);
      if (error) throw error;
    },
    onSuccess: invalidate,
  });

  // 重置密码：bcrypt 加密后直接写 auth.users
  const resetPasswordMutation = useMutation({
    mutationFn: async ({
      userId,
      newPassword,
    }: {
      userId: string;
      newPassword: string;
    }) => {
      const hashed = await bcrypt.hash(newPassword, 10);
      const db = await getDb();
      await db.query(
        `UPDATE auth.users SET encrypted_password = $1 WHERE id = $2`,
        [hashed, userId]
      );
    },
  });

  // 删除账号：连同档案与体征数据一起清理
  const deleteUserMutation = useMutation({
    mutationFn: async ({ userId }: { userId: string }) => {
      const db = await getDb();
      await db.transaction(async (tx) => {
        await tx.query(
          `DELETE FROM vital_signs WHERE record_id IN (SELECT id FROM health_records WHERE user_id = $1)`,
          [userId]
        );
        await tx.query(`DELETE FROM health_records WHERE user_id = $1`, [userId]);
        await tx.query(`DELETE FROM profiles WHERE id = $1`, [userId]);
        await tx.query(`DELETE FROM auth.users WHERE id = $1`, [userId]);
      });
    },
    onSuccess: invalidate,
  });

  return {
    users: usersQuery.data ?? [],
    stats: statsQuery.data ?? { userCount: 0, activeCount: 0, disabledCount: 0 },
    isLoading: usersQuery.isLoading || statsQuery.isLoading,
    isUsersError: usersQuery.isError,
    isStatsError: statsQuery.isError,
    error: usersQuery.error ?? statsQuery.error,
    refetch: () => {
      usersQuery.refetch();
      statsQuery.refetch();
    },
    toggleUserStatus: toggleUserStatusMutation.mutate,
    resetPassword: resetPasswordMutation.mutateAsync,
    deleteUser: deleteUserMutation.mutate,
    isUpdating: toggleUserStatusMutation.isPending,
    isDeleting: deleteUserMutation.isPending,
  };
}
