import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/contexts/AuthContext";
import { restoreClientRelation, purgeClientRelation } from "@/services/clientRelations";
import { toast } from "sonner";
import { useState } from "react";

export interface DeletedClient {
  relationId: string;
  clientId: string;
  customerName: string;
  phone: string | null;
  deletedAt: string | null;
}

const PAGE_SIZE = 20;

export function useClientRecycleBin({ enabled = true }: { enabled?: boolean } = {}) {
  const { user } = useAuth();
  const queryClient = useQueryClient();
  const [page, setPage] = useState(1);
  const [search, setSearch] = useState("");

  const query = useQuery({
    queryKey: ["client-recycle-bin", user?.id, page, search],
    queryFn: async () => {
      if (!user) return { items: [] as DeletedClient[], total: 0 };

      let query = supabase
        .from("client_relations")
        .select("id, client_id, customer_name, created_at, updated_at, profiles!client_id(phone, nickname)")
        .eq("manager_id", user.id)
        .eq("status", "deleted")
        .order("updated_at", { ascending: false });

      if (search.trim()) {
        query = query.or(`customer_name.ilike.%${search.trim()}%`);
      }

      const { data, error } = await query.range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
      if (error) throw error;

      // 查总数
      let countQuery = supabase
        .from("client_relations")
        .select("id", { count: "exact", head: true })
        .eq("manager_id", user.id)
        .eq("status", "deleted");
      if (search.trim()) {
        countQuery = countQuery.or(`customer_name.ilike.%${search.trim()}%`);
      }
      const { count } = await countQuery;

      const items: DeletedClient[] = (data ?? []).map((row: Record<string, unknown>) => {
        const profile = row.profiles as { phone?: string; nickname?: string } | null;
        return {
          relationId: row.id as string,
          clientId: row.client_id as string,
          customerName: (row.customer_name as string) || profile?.nickname || "未知客户",
          phone: profile?.phone ?? null,
          deletedAt: row.updated_at as string | null,
        };
      });

      return { items, total: count ?? 0 };
    },
    enabled: enabled && !!user,
  });

  const restoreMutation = useMutation({
    mutationFn: restoreClientRelation,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["clients"] });
      queryClient.invalidateQueries({ queryKey: ["client-recycle-bin"] });
    },
  });

  const purgeMutation = useMutation({
    mutationFn: purgeClientRelation,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["client-recycle-bin"] });
      toast.success("已彻底删除");
    },
    onError: (error) => {
      toast.error(error.message);
    },
  });

  return {
    items: query.data?.items ?? [],
    total: query.data?.total ?? 0,
    isLoading: query.isLoading,
    isError: query.isError,
    refetch: query.refetch,
    page,
    setPage,
    pageSize: PAGE_SIZE,
    search,
    setSearch,
    restore: restoreMutation.mutateAsync,
    purge: purgeMutation.mutateAsync,
    isRestoring: restoreMutation.isPending,
    isPurging: purgeMutation.isPending,
  };
}
