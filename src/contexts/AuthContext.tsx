/**
 * AuthContext — 开源版简化认证上下文
 *
 * 基于 localSupabase.auth（PGlite + bcryptjs 本地认证）
 * 已移除：
 *   - mp_token / mp_bridge / mp_manager URL 转交（小程序 web-view 场景）
 *   - identitySummary / listMyEmployments / hasActiveClientRelation（双身份）
 *   - switchSession（关联账号互跳）
 *   - mpBootstrapError / signingOut（小程序启动失败状态）
 * 保留：
 *   - session / user / profile 三元组
 *   - onAuthStateChange 订阅 + 竞态防护（loadSeqRef / prevUserIdRef）
 *   - signOut / refreshProfile
 *   - AUTH_FALLBACK（HMR/未挂载时安全降级）
 */

import {
  createContext,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { supabase } from "@/integrations/supabase/client";
import { useQueryClient } from "@tanstack/react-query";
import type { Profile } from "@/integrations/supabase/types";
import type { AuthSession, AuthUser } from "@/lib/supabase-adapter";

interface AuthContextType {
  session: AuthSession | null;
  user: AuthUser | null;
  profile: Profile | null;
  loading: boolean;
  signOut: () => Promise<void>;
  refreshProfile: () => Promise<void>;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

interface AuthProviderProps {
  children: ReactNode;
}

export function AuthProvider({ children }: AuthProviderProps) {
  const [session, setSession] = useState<AuthSession | null>(null);
  const [user, setUser] = useState<AuthUser | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [loading, setLoading] = useState(true);
  // 身份加载竞态序号：每次会话变化 ++，只有最后一次加载允许落 state。
  const loadSeqRef = useRef(0);
  // 上一次会话的用户 ID：仅在账号真正切换时才作废旧 profile，
  // 同账号的 TOKEN_REFRESHED / INITIAL_SESSION 不清空，避免定时刷新导致界面闪烁。
  const prevUserIdRef = useRef<string | null>(null);

  const fetchProfile = async (userId: string) => {
    const { data, error } = await supabase
      .from("profiles")
      .select("*")
      .eq("id", userId)
      .single();

    if (error) {
      console.error("Error fetching profile:", error);
      return null;
    }
    return data as Profile;
  };

  const refreshProfile = async () => {
    if (user) {
      const profileData = await fetchProfile(user.id);
      setProfile(profileData);
    }
  };

  // 按账号加载 profile，带竞态防护：账号快速切换时只有最后一次生效。
  const hydrateProfile = async (userId: string) => {
    const seq = ++loadSeqRef.current;
    const profileData = await fetchProfile(userId);
    if (loadSeqRef.current !== seq) return;
    setProfile(profileData);
  };

  useEffect(() => {
    // 只通过 onAuthStateChange 管理会话状态
    // INITIAL_SESSION 事件会在会话恢复完成后触发
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((event, session) => {
      setSession(session);
      setUser(session?.user ?? null);

      if (session?.user) {
        const nextUserId = session.user.id;
        const accountChanged = prevUserIdRef.current !== nextUserId;
        prevUserIdRef.current = nextUserId;
        if (accountChanged) {
          // 账号切换时旧 profile 立即作废，避免「新会话 + 旧角色」错配窗口
          loadSeqRef.current++;
          setProfile(null);
        }
        // setTimeout 避免 onAuthStateChange 内部死锁
        setTimeout(() => {
          void hydrateProfile(nextUserId);
        }, 0);
      } else {
        prevUserIdRef.current = null;
        loadSeqRef.current++;
        setProfile(null);
      }

      setLoading(false);
    });

    return () => subscription.unsubscribe();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const queryClient = useQueryClient();

  const signOut = async () => {
    // Optimistic: clear local state immediately for instant UI response
    prevUserIdRef.current = null;
    loadSeqRef.current++;
    setSession(null);
    setUser(null);
    setProfile(null);
    queryClient.clear();
    try {
      await supabase.auth.signOut({ scope: "local" });
    } catch (err) {
      console.error("本地登出失败:", err);
    }
  };

  return (
    <AuthContext.Provider
      value={{
        session,
        user,
        profile,
        loading,
        signOut,
        refreshProfile,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

const AUTH_FALLBACK: AuthContextType = {
  session: null,
  user: null,
  profile: null,
  loading: true,
  signOut: async () => {},
  refreshProfile: async () => {},
};

export function useAuth(): AuthContextType {
  const context = useContext(AuthContext);
  if (context === undefined) {
    // During HMR transitions or before AuthProvider mounts, return safe loading state
    return AUTH_FALLBACK;
  }
  return context;
}
