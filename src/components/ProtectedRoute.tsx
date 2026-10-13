/**
 * ProtectedRoute — 开源版简化路由守卫
 *
 * 基于 localSupabase.auth 本地 session + profile.role 单角色判定。
 * 已移除：
 *   - mpNativeLoginFirst / MpNativeLoginGate（小程序原生登录壳）
 *   - identitySummary / canAccessManager / canAccessUser / fallbackRouteFor（双身份）
 *   - signingOut（退出流程状态）
 * 保留：
 *   - loading 占位（profile 未就绪时显示）
 *   - session 缺失跳 /login
 *   - profile 角色判定（user/manager/admin 单角色）
 *   - profile.id !== session.user.id 错配保护（账号切换瞬间）
 *   - 被禁用用户跳登录页
 *   - 长时间未就绪提供退出登录兜底
 */

import { Navigate, useLocation } from "react-router-dom";
import { useAuth } from "@/contexts/AuthContext";
import { Loader2 } from "lucide-react";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import type { UserRole } from "@/integrations/supabase/types";

type RouteSide = Exclude<UserRole, "user"> | "user";

interface ProtectedRouteProps {
  children: React.ReactNode;
  allowedRoles?: RouteSide[];
}

function ProfileLoadingFallback() {
  const { signOut } = useAuth();
  const [showEscape, setShowEscape] = useState(false);

  useEffect(() => {
    const t = setTimeout(() => setShowEscape(true), 6000);
    return () => clearTimeout(t);
  }, []);

  return (
    <div className="min-h-screen flex items-center justify-center bg-background">
      <div className="flex flex-col items-center gap-4 max-w-xs text-center">
        <Loader2 className="w-8 h-8 animate-spin text-primary" />
        <p className="text-muted-foreground">加载账号信息中...</p>
        {showEscape && (
          <>
            <p className="text-xs text-muted-foreground">
              账号信息加载较慢，如长时间停留请尝试退出后重新登录。
            </p>
            <Button
              size="sm"
              variant="outline"
              onClick={async () => {
                await signOut();
                window.location.href = "/login";
              }}
            >
              退出登录
            </Button>
          </>
        )}
      </div>
    </div>
  );
}

export function ProtectedRoute({ children, allowedRoles }: ProtectedRouteProps) {
  const { session, profile, loading } = useAuth();
  const location = useLocation();

  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-background">
        <div className="flex flex-col items-center gap-4">
          <Loader2 className="w-8 h-8 animate-spin text-primary" />
          <p className="text-muted-foreground">加载中...</p>
        </div>
      </div>
    );
  }

  if (!session) {
    return <Navigate to="/login" state={{ from: location }} replace />;
  }

  // 角色限定路由但 profile 还未拉到，或 profile 属于另一个账号（账号切换瞬间）：
  // 保持 loading，不拿旧角色做判定，避免 user↔manager↔login 重定向死循环。
  if (allowedRoles && (!profile || profile.id !== session.user.id)) {
    return <ProfileLoadingFallback />;
  }

  // 单角色判定：直接看 profile.role
  if (allowedRoles && profile) {
    if (profile.is_disabled) {
      return <Navigate to="/login" replace />;
    }
    const allowed = allowedRoles.includes(profile.role as RouteSide);
    if (!allowed) {
      // 跳到该角色对应的默认页
      const fallback =
        profile.role === "admin"
          ? "/platform/users"
          : profile.role === "manager"
            ? "/merchant/clients"
            : "/merchant/assistant";
      return <Navigate to={fallback} replace />;
    }
  }

  return <>{children}</>;
}
