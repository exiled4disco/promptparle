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
  compression_level?: number;
  secrets_masked?: boolean;
  notes?: string[];
  optimize_only?: boolean;
  strategy?: string;
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

const DIAL_META: Record<
  number,
  { label: string; short: string; hint: string }
> = {
  1: {
    label: "Max fidelity",
    short: "1 · Max fidelity",
    hint: "~0–15% fewer tokens · near-full text",
  },
  2: {
    label: "High fidelity",
    short: "2 · High fidelity",
    hint: "~25–40% fewer · coverage + deep keep",
  },
  3: {
    label: "Balanced",
    short: "3 · Balanced",
    hint: "~45–60% fewer · solid coverage",
  },
  4: {
    label: "High savings",
    short: "4 · High savings",
    hint: "~70–85% fewer · map + obligations",
  },
  5: {
    label: "Max savings",
    short: "5 · Max savings",
    hint: "~85%+ fewer · executive crush",
  },
};

function uid() {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

export function ChatClient() {
  const [providers, setProviders] = useState<Provider[]>([]);
  const [provider, setProvider] = useState("openai");
  const [profile, setProfile] = useState("general");
  const [dial, setDial] = useState(3);
  const [context, setContext] = useState("");
  const [optimizeOnly, setOptimizeOnly] = useState(false);
  const [toolsOpen, setToolsOpen] = useState(true);
  const [input, setInput] = useState("");
  const [messages, setMessages] = useState<ChatMessage[]>([
    {
      id: "welcome",
      role: "system",
      content:
        "Chat through PromptParle. Use the left tools rail for provider, profile, and the compression dial (1 fidelity → 5 savings). Paste context below the tools or attach in the composer.",
    },
  ]);
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const bottomRef = useRef<HTMLDivElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    try {
      const saved = localStorage.getItem("pp_dial");
      if (saved && /^[1-5]$/.test(saved)) setDial(Number(saved));
    } catch {
      /* ignore */
    }
  }, []);

  useEffect(() => {
    try {
      localStorage.setItem("pp_dial", String(dial));
    } catch {
      /* ignore */
    }
  }, [dial]);

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
  const dialInfo = DIAL_META[dial] || DIAL_META[3];

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
          compressionLevel: dial,
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
            Tools on the left · message + context at the bottom. Dial trades
            fidelity for token savings.
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            className="btn btn-secondary text-sm lg:hidden"
            onClick={() => setToolsOpen((v) => !v)}
          >
            {toolsOpen ? "Hide tools" : "Show tools"}
          </button>
          <Link href="/app/usage" className="btn btn-secondary text-sm">
            View usage / before-after
          </Link>
        </div>
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

      <div className="grid flex-1 gap-4 lg:grid-cols-[260px_1fr]">
        {/* Left tools rail */}
        <aside
          className={`card flex flex-col gap-4 p-4 ${
            toolsOpen ? "" : "hidden lg:flex"
          }`}
        >
          <div>
            <div className="text-xs font-semibold uppercase tracking-wide text-[var(--text-dim)]">
              Tools
            </div>
            <p className="mt-1 text-xs text-[var(--text-muted)]">
              Profile = domain. Dial = how hard to compress.
            </p>
          </div>

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
                <option
                  key={p.id}
                  value={p.id}
                  disabled={!p.configured && !optimizeOnly}
                >
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

          <div className="field">
            <div className="label flex items-center justify-between">
              <span>Compression dial</span>
              <span className="text-[var(--text-dim)]">1–5</span>
            </div>
            <div className="mb-1 flex justify-between text-[10px] uppercase tracking-wide text-[var(--text-dim)]">
              <span>Fidelity</span>
              <span>Savings</span>
            </div>
            <input
              id="dial"
              type="range"
              min={1}
              max={5}
              step={1}
              value={dial}
              onChange={(e) => setDial(Number(e.target.value))}
              className="w-full accent-[var(--accent)]"
            />
            <div className="mt-2 rounded-lg border border-[var(--border)] bg-black/20 px-3 py-2">
              <div className="text-sm font-semibold text-[var(--accent-strong)]">
                {dialInfo.short}
              </div>
              <div className="mt-0.5 text-xs text-[var(--text-dim)]">
                {dialInfo.hint}
              </div>
            </div>
          </div>

          <label className="flex items-center gap-2 text-sm text-[var(--text-muted)]">
            <input
              type="checkbox"
              checked={optimizeOnly}
              onChange={(e) => setOptimizeOnly(e.target.checked)}
            />
            Optimize only (no AI spend)
          </label>

          <div className="field">
            <label className="label" htmlFor="context">
              Document / context attachment
            </label>
            <textarea
              id="context"
              className="input min-h-[140px] font-mono text-xs"
              placeholder="Paste logs, docs, code, CSV… this is where savings come from"
              value={context}
              onChange={(e) => setContext(e.target.value)}
            />
            <p className="mt-1 text-xs text-[var(--text-dim)]">
              {context.trim()
                ? `${context.trim().length.toLocaleString()} characters attached`
                : "No context yet — short chats often show 0% reduction"}
            </p>
          </div>

          <div className="mt-auto space-y-1 border-t border-[var(--border)] pt-3 text-xs text-[var(--text-dim)]">
            <Link href="/app/providers" className="block text-[var(--accent-strong)] hover:underline">
              Providers
            </Link>
            <Link href="/app/api-keys" className="block text-[var(--accent-strong)] hover:underline">
              API keys
            </Link>
            <Link href="/app/settings" className="block text-[var(--accent-strong)] hover:underline">
              Settings
            </Link>
          </div>
        </aside>

        {/* Chat column */}
        <div className="card flex min-h-[420px] flex-1 flex-col overflow-hidden">
          <div className="flex-1 space-y-4 overflow-y-auto p-4 sm:p-6">
            {messages.map((m) => (
              <MessageBubble key={m.id} message={m} />
            ))}
            {loading && (
              <div className="text-sm text-[var(--text-dim)]">
                Thinking… (dial {dial}/5)
              </div>
            )}
            <div ref={bottomRef} />
          </div>

          <form
            onSubmit={send}
            className="border-t border-[var(--border)] bg-black/20 p-4"
          >
            <div className="mb-2 flex flex-wrap items-center gap-2 text-xs text-[var(--text-dim)]">
              <span className="rounded-full border border-[var(--border)] px-2 py-0.5">
                {dialInfo.short}
              </span>
              <span className="rounded-full border border-[var(--border)] px-2 py-0.5">
                {profile}
              </span>
              {context.trim() ? (
                <span className="rounded-full border border-[var(--border)] px-2 py-0.5 text-[var(--success)]">
                  context attached
                </span>
              ) : null}
            </div>
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
          {isUser
            ? "You"
            : message.meta?.optimize_only
              ? "Optimized prompt"
              : "PromptParle"}
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
  const dial = meta.compression_level;

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
      {dial != null && <span>dial {dial}/5</span>}
      {meta.strategy && <span>{meta.strategy}</span>}
      {meta.provider && <span>{meta.provider}</span>}
      {meta.model && <span className="mono">{meta.model}</span>}
      {meta.secrets_masked && (
        <span className="text-[var(--warning)]">secrets masked</span>
      )}
    </div>
  );
}
