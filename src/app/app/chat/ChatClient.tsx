"use client";

import {
  FormEvent,
  KeyboardEvent,
  useEffect,
  useRef,
  useState,
} from "react";
import Link from "next/link";

type Provider = {
  id: string;
  name: string;
  defaultModel: string;
  configured: boolean;
};

type Meta = {
  original_tokens?: number;
  optimized_tokens?: number;
  token_reduction_percent?: number;
  tokens_saved?: number;
  expanded?: boolean;
  provider?: string;
  model?: string;
  optimization_profile?: string;
  secrets_masked?: boolean;
  notes?: string[];
  optimize_only?: boolean;
};

type ChatMessage = {
  id: string;
  role: "user" | "assistant" | "system";
  content: string;
  meta?: Meta;
  optimizedPrompt?: string;
  error?: boolean;
};

const PROFILES = [
  { id: "general", label: "General" },
  { id: "developer", label: "Developer" },
  { id: "security-review", label: "Security review" },
  { id: "log-analysis", label: "Log analysis" },
  { id: "documentation", label: "Documentation" },
  { id: "executive-summary", label: "Executive summary" },
];

function uid() {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

export function ChatClient() {
  const [providers, setProviders] = useState<Provider[]>([]);
  const [provider, setProvider] = useState("openai");
  const [profile, setProfile] = useState("general");
  const [context, setContext] = useState("");
  const [showContext, setShowContext] = useState(false);
  const [optimizeOnly, setOptimizeOnly] = useState(false);
  const [input, setInput] = useState("");
  const [messages, setMessages] = useState<ChatMessage[]>([
    {
      id: "welcome",
      role: "system",
      content:
        "Chat through PromptParle in your browser. Pick a configured AI, type normally, and we’ll optimize context before it hits the model. Savings show under each reply — full history is on the Usage page.",
    },
  ]);
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const bottomRef = useRef<HTMLDivElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const res = await fetch("/api/chat");
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || "Failed to load providers");
        if (cancelled) return;
        const list: Provider[] = data.providers || [];
        setProviders(list);
        const first = list.find((p) => p.configured) || list[0];
        if (first) setProvider(first.id);
      } catch (e) {
        if (!cancelled) {
          setLoadError(e instanceof Error ? e.message : "Load failed");
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, loading]);

  const configured = providers.filter((p) => p.configured);
  const selectedConfigured = providers.some(
    (p) => p.id === provider && p.configured
  );

  async function send(e?: FormEvent) {
    e?.preventDefault();
    const prompt = input.trim();
    if (!prompt || loading) return;
    if (!selectedConfigured && !optimizeOnly) {
      setMessages((m) => [
        ...m,
        {
          id: uid(),
          role: "system",
          content:
            "That provider has no key yet. Add one under Providers, or enable “Optimize only”.",
          error: true,
        },
      ]);
      return;
    }

    const userMsg: ChatMessage = { id: uid(), role: "user", content: prompt };
    setMessages((m) => [...m, userMsg]);
    setInput("");
    setLoading(true);

    try {
      const res = await fetch("/api/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          provider,
          prompt,
          context: context.trim() || undefined,
          profile,
          optimizeOnly,
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        setMessages((m) => [
          ...m,
          {
            id: uid(),
            role: "assistant",
            content: data.error || "Request failed",
            meta: data.metadata,
            error: true,
          },
        ]);
        return;
      }

      const content = optimizeOnly
        ? data.optimized_prompt || "(empty optimized prompt)"
        : data.response || "(empty response)";

      setMessages((m) => [
        ...m,
        {
          id: uid(),
          role: "assistant",
          content,
          meta: data.metadata,
          optimizedPrompt: data.optimized_prompt,
        },
      ]);
    } catch {
      setMessages((m) => [
        ...m,
        {
          id: uid(),
          role: "assistant",
          content: "Network error talking to PromptParle.",
          error: true,
        },
      ]);
    } finally {
      setLoading(false);
      textareaRef.current?.focus();
    }
  }

  function onKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      void send();
    }
  }

  return (
    <div className="flex min-h-[calc(100vh-8rem)] flex-col gap-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="page-title">Chat</h1>
          <p className="page-sub">
            Browser chat through PromptParle — pick a provider, type normally.
            Attach noisy logs/context below to see real token savings.
          </p>
        </div>
        <Link href="/app/usage" className="btn btn-secondary text-sm">
          View usage / before-after
        </Link>
      </div>

      {loadError && <div className="alert alert-error">{loadError}</div>}

      {configured.length === 0 && (
        <div className="alert alert-error">
          No provider keys yet.{" "}
          <Link href="/app/providers" className="underline">
            Add OpenAI / Claude / Gemini / Grok
          </Link>{" "}
          first — or use Optimize only to preview compression.
        </div>
      )}

      <div className="card grid gap-3 p-4 sm:grid-cols-2 lg:grid-cols-4">
        <div className="field">
          <label className="label" htmlFor="provider">
            AI provider
          </label>
          <select
            id="provider"
            className="select"
            value={provider}
            onChange={(e) => setProvider(e.target.value)}
          >
            {providers.map((p) => (
              <option key={p.id} value={p.id} disabled={!p.configured && !optimizeOnly}>
                {p.name}
                {p.configured ? "" : " (not configured)"}
              </option>
            ))}
          </select>
        </div>
        <div className="field">
          <label className="label" htmlFor="profile">
            Optimization profile
          </label>
          <select
            id="profile"
            className="select"
            value={profile}
            onChange={(e) => setProfile(e.target.value)}
          >
            {PROFILES.map((p) => (
              <option key={p.id} value={p.id}>
                {p.label}
              </option>
            ))}
          </select>
        </div>
        <div className="field sm:col-span-2 lg:col-span-2">
          <label className="label flex items-center justify-between">
            <span>Extra context (optional)</span>
            <button
              type="button"
              className="btn btn-ghost text-xs"
              onClick={() => setShowContext((v) => !v)}
            >
              {showContext ? "Hide" : "Show"}
            </button>
          </label>
          {showContext && (
            <textarea
              className="input min-h-[100px] font-mono text-xs"
              placeholder="Paste logs, code, firewall rules… this is where savings come from"
              value={context}
              onChange={(e) => setContext(e.target.value)}
            />
          )}
          {!showContext && (
            <p className="text-xs text-[var(--text-dim)]">
              {context.trim()
                ? `${context.trim().length.toLocaleString()} characters attached`
                : "No context attached — short chats often show 0% reduction"}
            </p>
          )}
        </div>
      </div>

      <div className="card flex min-h-[420px] flex-1 flex-col overflow-hidden">
        <div className="flex-1 space-y-4 overflow-y-auto p-4 sm:p-6">
          {messages.map((m) => (
            <MessageBubble key={m.id} message={m} />
          ))}
          {loading && (
            <div className="text-sm text-[var(--text-dim)]">Thinking…</div>
          )}
          <div ref={bottomRef} />
        </div>

        <form
          onSubmit={send}
          className="border-t border-[var(--border)] bg-black/20 p-4"
        >
          <label className="mb-2 flex items-center gap-2 text-sm text-[var(--text-muted)]">
            <input
              type="checkbox"
              checked={optimizeOnly}
              onChange={(e) => setOptimizeOnly(e.target.checked)}
            />
            Optimize only (no AI spend — show compressed prompt)
          </label>
          <div className="flex flex-col gap-3 sm:flex-row sm:items-end">
            <textarea
              ref={textareaRef}
              className="input min-h-[88px] flex-1 resize-y"
              placeholder="Message PromptParle… (Enter to send, Shift+Enter for newline)"
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={onKeyDown}
              disabled={loading}
            />
            <button
              type="submit"
              className="btn btn-primary shrink-0"
              disabled={loading || !input.trim()}
            >
              {loading ? "Sending…" : "Send"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

function MessageBubble({ message }: { message: ChatMessage }) {
  if (message.role === "system") {
    return (
      <div
        className={`rounded-xl border px-4 py-3 text-sm ${
          message.error
            ? "border-[var(--danger)]/40 bg-[var(--danger-soft)] text-[var(--danger)]"
            : "border-[var(--border)] bg-[var(--bg)]/40 text-[var(--text-muted)]"
        }`}
      >
        {message.content}
      </div>
    );
  }

  const isUser = message.role === "user";
  return (
    <div className={`flex ${isUser ? "justify-end" : "justify-start"}`}>
      <div
        className={`max-w-[min(100%,42rem)] rounded-2xl px-4 py-3 ${
          isUser
            ? "bg-[var(--accent-soft)] text-[var(--text)]"
            : message.error
              ? "border border-[var(--danger)]/40 bg-[var(--danger-soft)]"
              : "border border-[var(--border)] bg-[var(--bg-soft)]"
        }`}
      >
        <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-[var(--text-dim)]">
          {isUser ? "You" : message.meta?.optimize_only ? "Optimized prompt" : "PromptParle"}
        </div>
        <div className="whitespace-pre-wrap text-sm leading-relaxed">
          {message.content}
        </div>
        {message.meta && !isUser && (
          <div className="mt-3 border-t border-[var(--border)] pt-2 text-xs text-[var(--text-dim)]">
            <SavingsLine meta={message.meta} />
            {message.optimizedPrompt && !message.meta.optimize_only && (
              <details className="mt-2">
                <summary className="cursor-pointer text-[var(--accent-strong)]">
                  Show optimized prompt sent to model
                </summary>
                <pre className="mt-2 max-h-48 overflow-auto whitespace-pre-wrap rounded-lg bg-black/30 p-2 font-mono text-[11px]">
                  {message.optimizedPrompt}
                </pre>
              </details>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

function SavingsLine({ meta }: { meta: Meta }) {
  const orig = meta.original_tokens ?? 0;
  const opt = meta.optimized_tokens ?? 0;
  const pct = meta.token_reduction_percent ?? 0;
  const expanded = meta.expanded || opt > orig;

  return (
    <div className="flex flex-wrap gap-x-3 gap-y-1">
      <span>
        {orig} → {opt} tokens
      </span>
      {expanded ? (
        <span className="text-[var(--warning)]">expanded / no savings</span>
      ) : pct > 0 ? (
        <span className="text-[var(--success)]">−{pct}% saved</span>
      ) : (
        <span>0% (already compact)</span>
      )}
      {meta.provider && <span>{meta.provider}</span>}
      {meta.model && <span className="mono">{meta.model}</span>}
      {meta.secrets_masked && (
        <span className="text-[var(--warning)]">secrets masked</span>
      )}
    </div>
  );
}
