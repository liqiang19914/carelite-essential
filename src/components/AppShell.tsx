import { NavLink, Outlet } from "react-router-dom";
import { brand } from "@/config/brand";
import { cn } from "@/lib/utils";

const NAV_ITEMS = [
  { to: "/merchant/clients", label: "客户管理" },
  { to: "/merchant/assistant", label: "健康师智能体" },
  { to: "/platform/users", label: "平台用户" },
  { to: "/settings", label: "设置" },
  { to: "/guide", label: "开发指南" },
];

export default function AppShell() {
  return (
    <div className="flex h-screen min-h-0 flex-col">
      <header className="border-b bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/80">
        <div className="mx-auto flex h-14 w-full max-w-[1440px] items-center gap-6 px-6 xl:px-8">
          <NavLink to="/guide" className="flex shrink-0 items-center gap-2.5">
            <img src="/logo.png" alt={brand.name} className="h-8 w-8 rounded-md object-contain" />
            <span className="hidden flex-col leading-tight sm:flex">
              <span className="text-[15px] font-semibold">{brand.name}</span>
              <span className="text-[11px] text-muted-foreground">{brand.tagline}</span>
            </span>
          </NavLink>
          <nav className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto">
            {NAV_ITEMS.map((item) => (
              <NavLink
                key={item.to}
                to={item.to}
                className={({ isActive }) =>
                  cn(
                    "shrink-0 rounded-md px-3 py-1.5 text-sm text-muted-foreground transition-colors hover:bg-accent hover:text-foreground",
                    isActive && "bg-accent font-medium text-foreground"
                  )
                }
              >
                {item.label}
              </NavLink>
            ))}
          </nav>
          <span className="hidden shrink-0 text-xs text-muted-foreground md:block">v{brand.version}</span>
        </div>
      </header>
      <main className="min-h-0 flex-1 overflow-y-auto">
        <Outlet />
      </main>
    </div>
  );
}
