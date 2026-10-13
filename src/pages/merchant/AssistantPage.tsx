import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/contexts/AuthContext";
import PageContainer from "@/components/desktop/shell/PageContainer";
import PageHeader from "@/components/desktop/shell/PageHeader";
import AssistantPanel from "@/components/merchant/AssistantPanel";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar";
import { UserRound } from "lucide-react";

export default function AssistantPage() {
  const { user } = useAuth();
  const [selectedClientId, setSelectedClientId] = useState<string>("");

  // 加载客户列表供选择
  const { data: clients = [] } = useQuery({
    queryKey: ["assistant-clients", user?.id],
    queryFn: async () => {
      if (!user) return [];
      const { data, error } = await supabase
        .from("client_relations")
        .select("id, client_id, customer_name, profiles!client_id(nickname, avatar_url)")
        .eq("manager_id", user.id)
        .eq("status", "active")
        .order("created_at", { ascending: false });
      if (error) throw error;
      return (data ?? []).map((row: Record<string, unknown>) => ({
        relationId: row.id as string,
        clientId: row.client_id as string,
        name: (row.customer_name as string) || (row.profiles as { nickname?: string })?.nickname || "未知客户",
        avatar: (row.profiles as { avatar_url?: string })?.avatar_url,
      }));
    },
    enabled: !!user,
  });

  const selectedClient = clients.find((c) => c.relationId === selectedClientId);

  return (
    <PageContainer width="data">
      <PageHeader
        crumbs={[{ label: "商户端", to: "/merchant" }, { label: "健康师智能体" }]}
        title="健康师智能体"
        actions={
          <Select value={selectedClientId} onValueChange={setSelectedClientId}>
            <SelectTrigger className="h-8 w-[200px] text-[13px]">
              <SelectValue placeholder="选择客户（可选）">
                {selectedClient && (
                  <span className="flex items-center gap-1.5">
                    <Avatar className="h-4 w-4">
                      <AvatarImage src={selectedClient.avatar} />
                      <AvatarFallback className="text-[8px]">
                        {selectedClient.name.charAt(0)}
                      </AvatarFallback>
                    </Avatar>
                    {selectedClient.name}
                  </span>
                )}
              </SelectValue>
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="">
                <span className="flex items-center gap-1.5 text-muted-foreground">
                  <UserRound className="h-3.5 w-3.5" />
                  不选择客户
                </span>
              </SelectItem>
              {clients.map((client) => (
                <SelectItem key={client.relationId} value={client.relationId}>
                  <span className="flex items-center gap-1.5">
                    <Avatar className="h-4 w-4">
                      <AvatarImage src={client.avatar} />
                      <AvatarFallback className="text-[8px]">
                        {client.name.charAt(0)}
                      </AvatarFallback>
                    </Avatar>
                    {client.name}
                  </span>
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        }
      />

      <div className="flex min-h-0 flex-1 flex-col">
        <AssistantPanel
          clientName={selectedClient?.name}
          clientContext={selectedClient ? JSON.stringify({ clientId: selectedClient.clientId }) : undefined}
        />
      </div>
    </PageContainer>
  );
}
