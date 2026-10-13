import { useEffect, useRef, useState } from "react";
import { ArrowUp, Check, Copy, Loader2, Sparkles, Square, UserRound } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { cn } from "@/lib/utils";
import { useAssistantChat } from "@/hooks/useAssistantChat";

const MAX_MESSAGE_LEN = 2000;

function TypingDots() {
  return (
    <span className="flex items-center gap-1 py-1">
      {[0, 1, 2].map((i) => (
        <span
          key={i}
          className="h-1.5 w-1.5 animate-bounce rounded-full bg-muted-foreground/50"
          style={{ animationDelay: `${i * 0.15}s`, animationDuration: "0.9s" }}
        />
      ))}
    </span>
  );
}

const QUICK_PROMPTS = [
  "帮我分析这位客户的健康数据趋势",
  "根据档案给出下周的跟进建议",
  "客户最近体重上升，可能的原因有哪些？",
  "帮我写一段给客户的饮食建议文案",
];

interface AssistantPanelProps {
  /** 当前选中的客户档案上下文（JSON 字符串） */
  clientContext?: string;
  /** 当前客户姓名，用于展示 */
  clientName?: string;
}

export default function AssistantPanel({ clientContext, clientName }: AssistantPanelProps) {
  const { messages, streamingText, isStreaming, error, send, abort, setError } = useAssistantChat();
  const [input, setInput] = useState("");
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const el = scrollRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages, streamingText]);

  async function handleSend(text?: string) {
    const content = (text ?? input).trim();
    if (!content || isStreaming) return;
    setInput("");
    await send({ message: content, context: clientContext });
  }

  async function handleCopy(m: { id: string; content: string }) {
    try {
      await navigator.clipboard.writeText(m.content);
      setCopiedId(m.id);
      setTimeout(() => setCopiedId((c) => (c === m.id ? null : c)), 1500);
    } catch {
      // 剪贴板不可用时静默
    }
  }

  const showThinking = isStreaming && streamingText === "";
  const overLimit = input.length > MAX_MESSAGE_LEN;

  return (
    <div className="flex h-full min-h-[480px] flex-col">
      {/* 头部 */}
      <div className="flex items-center gap-2.5 px-0.5">
        <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-primary/10 text-primary">
          <Sparkles className="h-4 w-4" />
        </div>
        <div className="min-w-0">
          <p className="text-sm font-semibold leading-tight">健康师智能体</p>
          <p className="truncate text-[11px] leading-tight text-muted-foreground">
            {clientName ? `正在分析：${clientName}` : "分析客户档案，生成跟进建议"}
          </p>
        </div>
      </div>

      {/* 消息区 */}
      <div ref={scrollRef} className="mt-3 min-h-0 flex-1 space-y-4 overflow-y-auto px-0.5 pb-1">
        {messages.length === 0 ? (
          <div className="flex h-full flex-col justify-center gap-4">
            <div className="rounded-2xl border border-border/80 bg-muted/20 p-3.5">
              <p className="text-[13px] font-semibold">健康师 AI 助手</p>
              <p className="mt-1 text-[11px] text-muted-foreground">
                我可以帮你分析客户健康档案、生成跟进建议、解答健康管理问题。
                {clientName ? `当前已加载客户「${clientName}」的档案。` : "选择一位客户后，我可以基于其档案进行分析。"}
              </p>
            </div>

            <div className="space-y-1.5">
              <p className="px-0.5 text-[10px] uppercase tracking-wide text-muted-foreground/70">
                试试这样问
              </p>
              {QUICK_PROMPTS.map((text) => (
                <button
                  key={text}
                  type="button"
                  disabled={isStreaming}
                  onClick={() => void handleSend(text)}
                  className="group flex w-full items-center gap-2.5 rounded-xl px-2 py-1.5 text-left transition hover:bg-muted/50 disabled:opacity-50"
                >
                  <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-lg bg-muted text-muted-foreground transition group-hover:bg-primary/10 group-hover:text-primary">
                    <UserRound className="h-3 w-3" />
                  </span>
                  <span className="min-w-0 flex-1 text-xs leading-relaxed text-muted-foreground transition group-hover:text-foreground">
                    {text}
                  </span>
                </button>
              ))}
            </div>
          </div>
        ) : (
          messages.map((m) => (
            <div
              key={m.id}
              className={`group/msg animate-fade-up flex flex-col gap-1.5 ${
                m.role === "user" ? "items-end" : "items-start"
              }`}
            >
              {m.role === "assistant" ? (
                <div className="flex w-full gap-2.5">
                  <div className="mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary">
                    <Sparkles className="h-3 w-3" />
                  </div>
                  <div className="min-w-0 max-w-[88%] space-y-1.5 pt-0.5">
                    <p className="whitespace-pre-wrap text-[13px] leading-6">{m.content}</p>
                    <button
                      type="button"
                      onClick={() => void handleCopy(m)}
                      className="flex items-center gap-1 text-[10px] text-muted-foreground/70 opacity-0 transition hover:text-foreground group-hover/msg:opacity-100"
                    >
                      {copiedId === m.id ? (
                        <>
                          <Check className="h-3 w-3 text-primary" /> 已复制
                        </>
                      ) : (
                        <>
                          <Copy className="h-3 w-3" /> 复制
                        </>
                      )}
                    </button>
                  </div>
                </div>
              ) : (
                <div className="max-w-[85%] whitespace-pre-wrap rounded-[18px] rounded-br-md bg-primary px-3.5 py-2.5 text-[13px] leading-6 text-primary-foreground shadow-sm">
                  {m.content}
                </div>
              )}
            </div>
          ))
        )}

        {/* 流式输出 */}
        {isStreaming && streamingText &&
        messages[messages.length - 1]?.role !== "assistant" ? (
          <div className="flex w-full gap-2.5">
            <div className="mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary">
              <Sparkles className="h-3 w-3" />
            </div>
            <p className="max-w-[88%] whitespace-pre-wrap pt-0.5 text-[13px] leading-6">
              {streamingText}
              <span className="ml-0.5 inline-block h-3.5 w-0.5 animate-pulse rounded-full bg-primary align-middle" />
            </p>
          </div>
        ) : null}

        {showThinking ? (
          <div className="flex items-center gap-2.5">
            <div className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary">
              <Sparkles className="h-3 w-3" />
            </div>
            <TypingDots />
          </div>
        ) : null}
      </div>

      {/* 错误条 */}
      {error ? (
        <div className="mt-2 flex items-start justify-between gap-2 rounded-xl border border-destructive/20 bg-destructive/5 px-3 py-2 text-[11px] leading-relaxed text-destructive">
          <span>{error}</span>
          <button
            type="button"
            className="shrink-0 font-medium underline-offset-2 hover:underline"
            onClick={() => setError(null)}
          >
            知道了
          </button>
        </div>
      ) : null}

      {/* 输入区 */}
      <div
        className={cn(
          "mt-2 rounded-2xl border bg-card shadow-sm transition focus-within:ring-4",
          overLimit
            ? "border-destructive/50 focus-within:ring-destructive/10"
            : "border-border focus-within:border-primary/40 focus-within:ring-primary/[0.07]",
        )}
      >
        <Textarea
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              void handleSend();
            }
          }}
          placeholder="描述你的问题，或输入 / 选择客户后分析档案…"
          rows={2}
          className="min-h-0 resize-none rounded-b-none border-0 bg-transparent px-3.5 pt-3 text-[13px] shadow-none focus-visible:ring-0"
        />
        <div className="flex items-center gap-0.5 px-1.5 pb-1.5">
          <div className="ml-auto flex items-center gap-2">
            {input.length > 0 ? (
              <span
                className={cn(
                  "text-[10px] tabular-nums",
                  overLimit ? "font-medium text-destructive" : "text-muted-foreground/60",
                )}
              >
                {input.length}/{MAX_MESSAGE_LEN}
              </span>
            ) : (
              <span className="hidden text-[10px] text-muted-foreground/50 sm:inline">
                Enter 发送 · Shift+Enter 换行
              </span>
            )}
            {isStreaming ? (
              <Button
                variant="outline"
                size="icon"
                className="h-8 w-8 shrink-0 rounded-full"
                onClick={abort}
                title="停止生成"
              >
                <Square className="h-3.5 w-3.5 fill-current" />
              </Button>
            ) : (
              <Button
                size="icon"
                className="h-8 w-8 shrink-0 rounded-full"
                disabled={!input.trim() || overLimit}
                onClick={() => void handleSend()}
              >
                {isStreaming ? <Loader2 className="h-4 w-4 animate-spin" /> : <ArrowUp className="h-4 w-4" />}
              </Button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
