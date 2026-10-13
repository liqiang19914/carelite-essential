import { useCallback, useRef, useState } from "react";
import { callDeepSeekStream, type DeepSeekMessage } from "@/lib/deepseek";

export interface AssistantChatMessage {
  id: string;
  role: "user" | "assistant";
  content: string;
}

let msgSeq = 0;
function localId(): string {
  msgSeq += 1;
  return `local_${Date.now().toString(36)}_${msgSeq}`;
}

const SYSTEM_PROMPT = `你是一位专业的健康管理师 AI 助手。你的职责是帮助健康师分析客户健康档案、提供跟进建议、解答健康管理相关问题。

规则：
1. 基于客户档案数据进行分析，不要编造数据
2. 建议要具体、可执行，避免空泛
3. 涉及医疗建议时，提醒用户咨询专业医生
4. 保持专业、友善、简洁的沟通风格
5. 用中文回答`;

export function useAssistantChat() {
  const [messages, setMessages] = useState<AssistantChatMessage[]>([]);
  const [streamingText, setStreamingText] = useState("");
  const [isStreaming, setIsStreaming] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const abort = useCallback(() => {
    abortRef.current?.abort();
    abortRef.current = null;
  }, []);

  const reset = useCallback(() => {
    abort();
    setMessages([]);
    setStreamingText("");
    setError(null);
  }, [abort]);

  const send = useCallback(
    async (args: { message: string; context?: string }) => {
      const trimmed = args.message.trim();
      if (!trimmed || isStreaming) return;

      abortRef.current = new AbortController();
      setIsStreaming(true);
      setError(null);
      setStreamingText("");

      const userMsg: AssistantChatMessage = { id: localId(), role: "user", content: trimmed };
      const assistantId = localId();
      let assistantContent = "";

      const upsertAssistant = () => {
        setMessages((prev) => {
          const without = prev.filter((m) => m.id !== assistantId);
          return [
            ...without,
            { id: assistantId, role: "assistant" as const, content: assistantContent },
          ];
        });
      };

      setMessages((prev) => [...prev, userMsg]);

      try {
        // 构建消息历史
        const history: DeepSeekMessage[] = [
          { role: "system", content: SYSTEM_PROMPT },
          ...messages
            .filter((m) => m.content)
            .slice(-10)
            .map((m) => ({ role: m.role, content: m.content })),
          { role: "user" as const, content: trimmed },
        ];

        // 如果有客户档案上下文，注入到 system prompt
        if (args.context) {
          history[0].content += `\n\n当前客户档案上下文：\n${args.context}`;
        }

        await callDeepSeekStream(history, {
          onDelta: (delta) => {
            assistantContent += delta;
            setStreamingText(assistantContent);
            upsertAssistant();
          },
          onDone: () => {
            // 流结束，确保最终状态已更新
            upsertAssistant();
          },
          onError: (err) => {
            setError(err.message);
          },
        });

        // 流里没有任何内容时补一条占位
        if (!assistantContent) {
          assistantContent = "抱歉，我暂时无法回答这个问题。";
          upsertAssistant();
        }
      } catch (e) {
        const aborted = e instanceof Error && e.name === "AbortError";
        if (!aborted) {
          setError(e instanceof Error ? e.message : "网络异常，请重试");
        }
      } finally {
        setIsStreaming(false);
        setStreamingText("");
        abortRef.current = null;
      }
    },
    [messages, isStreaming],
  );

  return { messages, streamingText, isStreaming, error, send, abort, reset, setError };
}
