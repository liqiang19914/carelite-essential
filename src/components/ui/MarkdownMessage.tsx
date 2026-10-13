import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import type { ReactNode } from "react";

interface Props {
  content: string;
  className?: string;
  /** 是否是用户消息（用户消息可能有 [图片]URL 这种非 markdown 格式） */
  isUser?: boolean;
}

/**
 * 把 OSS / chat 图片的 URL 转成 markdown 图片语法。
 * 支持的格式：
 *   [图片]https://xxx.jpg
 *   [image]https://xxx.png
 *   直接裸露的 https://xxx.jpg（作为图片处理）
 */
function preprocessImageUrls(input: string): string {
  let s = input;

  // 1) [图片]URL / [image]URL → ![图片](URL)
  s = s.replace(
    /\[图片\]\s*(https?:\/\/[^\s)]+\.(?:jpg|jpeg|png|gif|webp|avif|bmp))/gi,
    "![图片]($1)"
  );
  s = s.replace(
    /\[image\]\s*(https?:\/\/[^\s)]+\.(?:jpg|jpeg|png|gif|webp|avif|bmp))/gi,
    "![图片]($1)"
  );

  return s;
}

/**
 * 判断 fenced code block 的内容是否是 JSON。
 * 把 JSON 渲染成结构化卡片（JSONInsightCard），而不是显示原始代码。
 */
function tryParseJson(text: string): unknown | null {
  const trimmed = text.trim();
  if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) return null;
  try {
    return JSON.parse(trimmed);
  } catch {
    // 容错：AI 有时会在 JSON 前后加解释文字，尝试提取第一个 {...} 或 [...]
    const brace = trimmed.indexOf("{");
    const bracket = trimmed.indexOf("[");
    let start = -1;
    if (brace >= 0 && bracket >= 0) start = Math.min(brace, bracket);
    else start = Math.max(brace, bracket);
    if (start < 0) return null;
    try {
      // 尝试找到匹配的闭合
      let depth = 0;
      let end = start;
      const opener = trimmed[start];
      const closer = opener === "{" ? "}" : "]";
      for (let i = start; i < trimmed.length; i++) {
        if (trimmed[i] === opener) depth++;
        else if (trimmed[i] === closer) depth--;
        if (depth === 0) { end = i + 1; break; }
      }
      const extracted = trimmed.slice(start, end);
      return JSON.parse(extracted);
    } catch {
      return null;
    }
  }
}

/**
 * 把 JSON 渲染成一个简洁的结构化卡片。
 * 针对常见的 AI 图片识别 / 营养分析 JSON 字段做特殊展示。
 */
function JsonInsightCard({ data }: { data: unknown }) {
  if (typeof data !== "object" || data === null) return null;
  const obj = data as Record<string, unknown>;

  // 特殊识别：foods 数组（AI 食物识别）
  const foods = Array.isArray(obj.foods) ? (obj.foods as Array<Record<string, unknown>>) : null;
  // health_analysis / ingredients 数组
  const ingredients = Array.isArray(obj.ingredients) ? (obj.ingredients as Array<Record<string, unknown>>) : null;

  const title =
    typeof obj.title === "string" ? obj.title :
    foods ? "识别结果" :
    ingredients ? "成分分析" :
    "结构化数据";

  return (
    <div className="my-2 rounded-lg border border-primary/20 bg-primary/5 p-3">
      {/* 头部 */}
      <div className="mb-2 flex items-center gap-1.5">
        <div className="h-1.5 w-1.5 rounded-full bg-primary" />
        <span className="text-[11px] font-semibold text-primary">{title}</span>
      </div>

      {/* 食物列表 */}
      {foods && (
        <div className="space-y-1.5">
          {foods.map((f, i) => (
            <div key={i} className="rounded-md bg-background/70 px-2 py-1.5">
              <p className="text-[12px] font-medium text-foreground">
                {String(f.name ?? f.commonName ?? `物品 ${i + 1}`)}
              </p>
              <div className="mt-0.5 flex flex-wrap gap-x-3 gap-y-0.5 text-[10px] text-muted-foreground">
                {typeof f.calories === "number" && (
                  <span>热量 <b className="text-foreground">{f.calories}</b> kcal</span>
                )}
                {typeof f.protein === "number" && (
                  <span>蛋白 <b className="text-foreground">{f.protein}g</b></span>
                )}
                {typeof f.fat === "number" && (
                  <span>脂肪 <b className="text-foreground">{f.fat}g</b></span>
                )}
                {typeof f.carbs === "number" && (
                  <span>碳水 <b className="text-foreground">{f.carbs}g</b></span>
                )}
                {typeof f.fiber === "number" && (
                  <span>纤维 <b className="text-foreground">{f.fiber}g</b></span>
                )}
              </div>
            </div>
          ))}
        </div>
      )}

      {/* 成分列表 */}
      {ingredients && (
        <div className="space-y-1">
          {ingredients.map((ing, i) => (
            <div key={i} className="rounded-md bg-background/70 px-2 py-1.5 text-[11px]">
              <span className="font-medium text-foreground">
                {String(ing.name ?? `成分 ${i + 1}`)}
              </span>
              {ing.amount && <span className="ml-1 text-muted-foreground">{String(ing.amount)}</span>}
              {ing.risk && (
                <span className={`ml-1 rounded px-1 text-[10px] ${
                  String(ing.risk) === "高" ? "bg-destructive/10 text-destructive" :
                  String(ing.risk) === "低" ? "bg-emerald-500/10 text-emerald-600" :
                  "bg-muted text-muted-foreground"
                }`}>
                  {String(ing.risk)}
                </span>
              )}
            </div>
          ))}
        </div>
      )}

      {/* 通用字段渲染（顶层非对象/非数组字段） */}
      {!foods && !ingredients && (
        <div className="flex flex-wrap gap-x-4 gap-y-1 text-[11px]">
          {Object.entries(obj).map(([k, v]) => {
            if (Array.isArray(v) || (typeof v === "object" && v !== null)) return null;
            return (
              <span key={k} className="text-muted-foreground">
                {k}: <b className="text-foreground">{String(v)}</b>
              </span>
            );
          })}
        </div>
      )}

      {/* advice / summary 文本字段 */}
      {typeof obj.advice === "string" && obj.advice && (
        <p className="mt-2 border-t border-primary/10 pt-2 text-[11px] leading-relaxed text-foreground/80">
          💡 {obj.advice}
        </p>
      )}
      {typeof obj.summary === "string" && obj.summary && (
        <p className="mt-2 border-t border-primary/10 pt-2 text-[11px] leading-relaxed text-foreground/80">
          {obj.summary}
        </p>
      )}
    </div>
  );
}

/** 图片安全显示：OSS / chat-images URL 可直接渲染，外部 URL 也走 onError 兜底 */
function SafeImage({ src, alt }: { src: string; alt?: string }) {
  return (
    <img
      src={src}
      alt={alt || ""}
      loading="lazy"
      referrerPolicy="no-referrer"
      className="max-h-64 max-w-full rounded-md object-contain shadow-sm"
      onError={(e) => {
        // 加载失败：显示 URL 而不是 broken image
        const el = e.currentTarget;
        el.style.display = "none";
        const parent = el.parentElement;
        if (parent && !parent.querySelector(".img-fallback")) {
          const span = document.createElement("span");
          span.className = "img-fallback text-[10px] text-muted-foreground truncate";
          span.textContent = `(图片加载失败: ${src.slice(0, 60)}...)`;
          parent.appendChild(span);
        }
      }}
    />
  );
}

export default function MarkdownMessage({ content, className, isUser }: Props) {
  // 预处理：把 [图片]URL 转成 markdown 图片语法
  const processed = isUser ? preprocessImageUrls(content) : content;

  return (
    <div className={cn("break-words text-[12px] leading-relaxed", className)}>
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          p: ({ children }) => (
            <p className="mb-1.5 last:mb-0">{children}</p>
          ),
          strong: ({ children }) => (
            <strong className="font-semibold text-foreground">{children}</strong>
          ),
          em: ({ children }) => <em className="italic">{children}</em>,
          del: ({ children }) => <del className="text-muted-foreground">{children}</del>,
          a: ({ href, children }) => (
            <a
              href={href}
              target="_blank"
              rel="noopener noreferrer"
              className="text-primary underline-offset-2 hover:underline"
            >
              {children}
            </a>
          ),
          // 行内 code
          code: ({ children, className: langClass, ...props }: { children: ReactNode; className?: string; [key: string]: unknown }) => {
            const text = typeof children === "string" ? children : "";
            const isInline = !text.includes("\n");
            if (isInline) {
              return (
                <code className="rounded bg-muted px-1 py-0.5 font-mono text-[11px] text-primary">
                  {children}
                </code>
              );
            }
            // 块级 code 也尝试 JSON 解析（ReactMarkdown 有时不把非 fenced 的 code 包进 pre）
            const parsed = tryParseJson(text);
            if (parsed) return <JsonInsightCard data={parsed} />;
            return (
              <pre className="my-2 overflow-x-auto rounded-md bg-muted p-2.5">
                <code className="block font-mono text-[11px] text-muted-foreground">
                  {children}
                </code>
              </pre>
            );
          },
          // fenced code block（```json ... ```）
          pre: ({ children }) => {
            // 从 children 里提取文本（ReactMarkdown 会把 code tag 塞进去）
            let text = "";
            const extract = (c: ReactNode) => {
              if (typeof c === "string") text += c;
              else if (Array.isArray(c)) c.forEach(extract);
              else if (c && typeof c === "object" && "props" in (c as { props?: { children?: ReactNode } })) {
                const p = (c as { props?: { children?: ReactNode } }).props;
                if (p?.children) extract(p.children);
              }
            };
            extract(children);

            const parsed = tryParseJson(text);
            if (parsed) return <JsonInsightCard data={parsed} />;

            return (
              <pre className="my-2 overflow-x-auto rounded-md bg-muted p-2.5 text-[11px] leading-relaxed text-muted-foreground">
                {children}
              </pre>
            );
          },
          h1: ({ children }) => (
            <h1 className="mb-2 mt-2 text-base font-bold text-foreground">{children}</h1>
          ),
          h2: ({ children }) => (
            <h2 className="mb-1.5 mt-2 text-sm font-semibold text-foreground">{children}</h2>
          ),
          h3: ({ children }) => (
            <h3 className="mb-1 mt-1.5 text-[13px] font-semibold text-foreground">{children}</h3>
          ),
          h4: ({ children }) => (
            <h4 className="mb-1 mt-1 text-[12px] font-semibold text-foreground/90">{children}</h4>
          ),
          ul: ({ children }) => (
            <ul className="mb-1.5 ml-5 list-disc space-y-0.5 marker:text-muted-foreground">
              {children}
            </ul>
          ),
          ol: ({ children }) => (
            <ol className="mb-1.5 ml-5 list-decimal space-y-0.5 marker:text-muted-foreground">
              {children}
            </ol>
          ),
          li: ({ children }) => <li className="leading-relaxed">{children}</li>,
          blockquote: ({ children }) => (
            <blockquote className="my-1.5 border-l-2 border-primary/40 bg-primary/5 py-1 pl-3 pr-2 text-[11px] text-muted-foreground">
              {children}
            </blockquote>
          ),
          hr: () => <hr className="my-2 border-border" />,
          img: ({ src, alt }) => (
            <figure className="my-2 flex flex-col items-center">
              <SafeImage src={src!} alt={alt} />
              {alt && alt !== "图片" && alt !== "image" && (
                <figcaption className="mt-1 text-[10px] text-muted-foreground">
                  {alt}
                </figcaption>
              )}
            </figure>
          ),
          table: ({ children }) => (
            <div className="my-2 overflow-x-auto rounded-md border border-border">
              <table className="min-w-full border-collapse text-[11px]">
                {children}
              </table>
            </div>
          ),
          thead: ({ children }) => (
            <thead className="bg-muted/60 text-foreground/90">{children}</thead>
          ),
          th: ({ children }) => (
            <th className="border-b border-border px-2 py-1 text-left font-semibold">
              {children}
            </th>
          ),
          td: ({ children }) => (
            <td className="border-b border-border/60 px-2 py-1.5 align-top">{children}</td>
          ),
          input: ({ type, checked, readOnly }) =>
            type === "checkbox" ? (
              <input
                type="checkbox"
                checked={checked}
                readOnly={readOnly}
                disabled
                className="mr-1 h-3 w-3 rounded border-muted-foreground/40"
              />
            ) : null,
        }}
      >
        {processed}
      </ReactMarkdown>
    </div>
  );
}

function cn(...args: (string | false | null | undefined)[]) {
  return args.filter(Boolean).join(" ");
}

