import { useParams, useNavigate } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { ArrowLeft, Loader2, FileText, User as UserIcon } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";
import { supabase } from "@/integrations/supabase/client";
import type { Profile, HealthRecord, VitalSign } from "@/integrations/supabase/types";
import QueryErrorState from "@/components/QueryErrorState";

function formatDate(dateString: string | null): string {
  if (!dateString) return "-";
  return new Date(dateString).toLocaleDateString("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
}

function formatPhone(phone: string | null): string {
  if (!phone) return "-";
  const clean = phone.replace("+86", "");
  if (clean.length >= 11) return `${clean.slice(0, 3)}****${clean.slice(-4)}`;
  return phone;
}

function calcAge(birthDate: string | null): string {
  if (!birthDate) return "-";
  const birth = new Date(birthDate);
  const now = new Date();
  let age = now.getFullYear() - birth.getFullYear();
  if (
    now.getMonth() < birth.getMonth() ||
    (now.getMonth() === birth.getMonth() && now.getDate() < birth.getDate())
  ) {
    age--;
  }
  return age >= 0 ? `${age} 岁` : "-";
}

const RELATIONSHIP_LABELS: Record<string, string> = {
  self: "本人",
  spouse: "配偶",
  parent: "父母",
  child: "子女",
  sibling: "兄弟姐妹",
  other: "其他",
};

export default function UserProfilePage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();

  const profileQuery = useQuery({
    queryKey: ["user_profile", id],
    enabled: !!id,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("profiles")
        .select("*")
        .eq("id", id!)
        .maybeSingle();
      if (error) throw error;
      return data as Profile | null;
    },
  });

  const recordsQuery = useQuery({
    queryKey: ["user_health_records", id],
    enabled: !!id,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("health_records")
        .select("*")
        .eq("user_id", id!)
        .order("is_default", { ascending: false })
        .order("created_at", { ascending: false });
      if (error) throw error;
      return (data ?? []) as HealthRecord[];
    },
  });

  const vitalsQuery = useQuery({
    queryKey: ["user_vital_signs", id, recordsQuery.data?.map((r) => r.id).join(",")],
    enabled: !!id && !!recordsQuery.data && recordsQuery.data.length > 0,
    queryFn: async () => {
      const recordIds = recordsQuery.data!.map((r) => r.id);
      const { data, error } = await supabase
        .from("vital_signs")
        .select("*")
        .in("record_id", recordIds)
        .order("recorded_at", { ascending: false })
        .limit(10);
      if (error) throw error;
      return (data ?? []) as VitalSign[];
    },
  });

  const profile = profileQuery.data;
  const records = recordsQuery.data ?? [];
  const vitals = vitalsQuery.data ?? [];

  if (profileQuery.isLoading) {
    return (
      <div className="space-y-4 px-4 md:px-0 animate-fade-up">
        <Skeleton className="h-8 w-32" />
        <Skeleton className="h-40 w-full" />
        <Skeleton className="h-60 w-full" />
      </div>
    );
  }

  if (profileQuery.isError) {
    return (
      <div className="px-4 md:px-0">
        <QueryErrorState error={profileQuery.error} onRetry={() => profileQuery.refetch()} />
      </div>
    );
  }

  if (!profile) {
    return (
      <div className="px-4 md:px-0 space-y-4">
        <Button variant="ghost" size="sm" onClick={() => navigate(-1)}>
          <ArrowLeft className="w-4 h-4 mr-1" /> 返回
        </Button>
        <Card>
          <CardContent className="p-12 text-center text-muted-foreground">
            用户不存在或已被删除
          </CardContent>
        </Card>
      </div>
    );
  }

  const displayName = profile.nickname || "未设置昵称";

  return (
    <div className="space-y-4 md:space-y-6 px-4 md:px-0 animate-fade-up">
      <div className="flex items-center gap-3">
        <Button variant="ghost" size="sm" onClick={() => navigate(-1)}>
          <ArrowLeft className="w-4 h-4 mr-1" /> 返回
        </Button>
        <h1 className="text-display text-xl md:text-2xl font-bold">用户档案</h1>
      </div>

      {/* 基本信息 */}
      <Card>
        <CardContent className="p-5">
          <div className="flex items-start gap-4">
            <Avatar className="w-16 h-16">
              <AvatarImage src={profile.avatar_url || undefined} />
              <AvatarFallback className="text-lg bg-muted">
                {displayName.slice(0, 1)}
              </AvatarFallback>
            </Avatar>
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-2 flex-wrap">
                <h2 className="text-lg font-semibold">{displayName}</h2>
                <span
                  className={cn(
                    "status-tag",
                    profile.is_disabled ? "status-tag-danger" : "status-tag-success"
                  )}
                >
                  {profile.is_disabled ? "已禁用" : "正常"}
                </span>
              </div>
              <p className="text-sm text-muted-foreground mt-0.5">{formatPhone(profile.phone)}</p>
            </div>
          </div>

          <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mt-5 text-sm">
            <div>
              <p className="pc-field-label">用户 ID</p>
              <p className="font-mono text-xs mt-0.5 break-all">{profile.id}</p>
            </div>
            <div>
              <p className="pc-field-label">注册时间</p>
              <p className="mt-0.5">{formatDate(profile.created_at)}</p>
            </div>
            <div>
              <p className="pc-field-label">档案数</p>
              <p className="mt-0.5">{records.length} 份</p>
            </div>
            <div>
              <p className="pc-field-label">角色</p>
              <p className="mt-0.5">{profile.role === "admin" ? "管理员" : profile.role === "manager" ? "商户" : "用户"}</p>
            </div>
            {profile.is_disabled && profile.disabled_reason && (
              <div className="col-span-2">
                <p className="pc-field-label">禁用原因</p>
                <p className="mt-0.5 text-destructive">{profile.disabled_reason}</p>
              </div>
            )}
          </div>
        </CardContent>
      </Card>

      {/* 健康档案 */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="pc-section-title flex items-center gap-2">
            <FileText className="w-4 h-4" /> 健康档案（{records.length}）
          </CardTitle>
        </CardHeader>
        <CardContent>
          {recordsQuery.isLoading ? (
            <div className="space-y-2">
              <Skeleton className="h-16 w-full" />
              <Skeleton className="h-16 w-full" />
            </div>
          ) : records.length === 0 ? (
            <p className="text-sm text-muted-foreground text-center py-8">该用户还没有建立健康档案</p>
          ) : (
            <div className="space-y-3">
              {records.map((rec) => (
                <div
                  key={rec.id}
                  className="pc-surface-muted p-4 flex items-start gap-3"
                >
                  <div className="w-9 h-9 rounded-full bg-primary/10 flex items-center justify-center flex-none">
                    <UserIcon className="w-4 h-4 text-primary" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 flex-wrap">
                      <p className="font-medium">{rec.name}</p>
                      {rec.is_default && (
                        <span className="pc-badge pc-badge-primary">默认档案</span>
                      )}
                      <span className="pc-badge pc-badge-neutral">
                        {RELATIONSHIP_LABELS[rec.relationship] ?? rec.relationship}
                      </span>
                    </div>
                    <p className="pc-caption mt-1">
                      {rec.gender === "male" ? "男" : rec.gender === "female" ? "女" : "性别未填"}
                      {" · "}{calcAge(rec.birth_date)}
                      {rec.height ? ` · ${rec.height}cm` : ""}
                      {rec.weight ? ` · ${rec.weight}kg` : ""}
                      {rec.blood_type ? ` · ${rec.blood_type}型` : ""}
                    </p>
                    {(rec.medical_history || rec.allergy_history) && (
                      <p className="pc-caption mt-1 line-clamp-2">
                        {rec.medical_history && `既往史：${rec.medical_history}`}
                        {rec.medical_history && rec.allergy_history && "；"}
                        {rec.allergy_history && `过敏史：${rec.allergy_history}`}
                      </p>
                    )}
                  </div>
                  <p className="pc-caption flex-none">{formatDate(rec.created_at)}</p>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      {/* 最近体征 */}
      {vitals.length > 0 && (
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="pc-section-title">最近体征记录</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="space-y-2">
              {vitals.map((v) => {
                const rec = records.find((r) => r.id === v.record_id);
                return (
                  <div key={v.id} className="flex items-center justify-between text-sm border-b border-border last:border-0 pb-2 last:pb-0">
                    <span className="text-muted-foreground">{rec?.name ?? "未知档案"}</span>
                    <span className="pc-num text-xs">
                      {v.systolic_pressure && v.diastolic_pressure && `血压 ${v.systolic_pressure}/${v.diastolic_pressure} `}
                      {v.heart_rate && `心率 ${v.heart_rate} `}
                      {v.blood_sugar && `血糖 ${v.blood_sugar} `}
                      {v.weight && `体重 ${v.weight}kg `}
                    </span>
                    <span className="pc-caption">{formatDate(v.recorded_at)}</span>
                  </div>
                );
              })}
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
