import { AlertTriangle, Loader2, RotateCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { rpcErrorMessage } from "@/lib/rpc-error";

interface Props {
  error?: unknown;
  title?: string;
  hint?: string;
  onRetry?: () => void;
  retrying?: boolean;
  compact?: boolean;
  className?: string;
}

/**
 * 取数失败的显式故障态：区分「请求失败」与「真的没有数据」。
 */
export default function QueryErrorState({
  error = null,
  title = "数据没有加载出来",
  hint,
  onRetry,
  retrying = false,
  compact = false,
  className,
}: Props) {
  const reason = rpcErrorMessage(error, "网络或服务暂时不可用，请稍后重试。");

  if (compact) {
    return (
      <div
        className={cn(
          "flex flex-col items-center gap-2 rounded-lg border border-destructive/30 bg-destructive/5 px-3 py-5 text-center",
          className,
        )}
      >
        <AlertTriangle className="h-4 w-4 text-destructive" />
        <p className="text-xs font-medium">{title}</p>
        <p className="max-w-xs text-[11px] text-muted-foreground">{reason}</p>
        {onRetry && (
          <Button variant="outline" size="sm" className="h-7 text-xs" disabled={retrying} onClick={onRetry}>
            {retrying ? (
              <Loader2 className="mr-1 h-3 w-3 animate-spin" />
            ) : (
              <RotateCw className="mr-1 h-3 w-3" />
            )}
            重新加载
          </Button>
        )}
      </div>
    );
  }

  return (
    <div
      className={cn(
        "flex flex-col items-center gap-3 rounded-xl border border-destructive/40 bg-destructive/5 px-4 py-10 text-center",
        className,
      )}
    >
      <AlertTriangle className="h-7 w-7 text-destructive" />
      <div className="space-y-1.5">
        <p className="text-sm font-medium">{title}</p>
        <p className="mx-auto max-w-sm text-xs text-muted-foreground">{reason}</p>
        {hint && <p className="mx-auto max-w-sm text-xs text-muted-foreground">{hint}</p>}
      </div>
      {onRetry && (
        <Button variant="outline" size="sm" disabled={retrying} onClick={onRetry}>
          {retrying ? (
            <Loader2 className="mr-1.5 h-4 w-4 animate-spin" />
          ) : (
            <RotateCw className="mr-1.5 h-4 w-4" />
          )}
          重新加载
        </Button>
      )}
    </div>
  );
}
