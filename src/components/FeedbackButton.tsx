"use client";

import { FormEvent, useEffect, useId, useState } from "react";
import { createPortal } from "react-dom";

/**
 * Floating Bug / Suggest control (portal app).
 * Modal is portaled to document.body so sticky headers never clip it.
 */
export function FeedbackButton({
  /** @deprecated header compact style removed, always floating FAB */
  compact: _compact = false,
}: {
  compact?: boolean;
} = {}) {
  const titleId = useId();
  const [mounted, setMounted] = useState(false);
  const [open, setOpen] = useState(false);
  const [kind, setKind] = useState<"bug" | "suggest">("suggest");
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [website, setWebsite] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("keydown", onKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = prev;
    };
  }, [open]);

  function close() {
    setOpen(false);
  }

  function openModal() {
    setOpen(true);
    setDone(false);
    setError(null);
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);
    try {
      const res = await fetch("/api/feedback", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ kind, title, body, website }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        setError(data.error || "Could not send");
        return;
      }
      setDone(true);
      setTitle("");
      setBody("");
    } catch {
      setError("Network error");
    } finally {
      setLoading(false);
    }
  }

  const fab = (
    <button
      type="button"
      onClick={openModal}
      className="fixed bottom-5 left-5 z-[60] flex items-center gap-2 rounded-full border border-[var(--accent)]/40 bg-[var(--bg-elevated,rgba(22,31,46,0.95))] px-4 py-2.5 text-sm font-medium text-[var(--text)] shadow-[0_12px_40px_rgba(0,0,0,0.45)] backdrop-blur-md transition hover:border-[var(--accent)] hover:bg-[var(--accent-soft)] hover:text-[var(--accent-strong)] focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent)]"
      aria-haspopup="dialog"
      aria-expanded={open}
    >
      <span
        className="flex h-6 w-6 items-center justify-center rounded-full bg-[var(--accent)] text-xs font-bold text-white"
        aria-hidden
      >
        ?
      </span>
      Bug / Suggest
    </button>
  );

  const modal =
    open && mounted
      ? createPortal(
          <div
            className="fixed inset-0 z-[100] flex items-center justify-center bg-black/65 p-4 backdrop-blur-[2px]"
            role="presentation"
            onClick={close}
          >
            <div
              role="dialog"
              aria-modal="true"
              aria-labelledby={titleId}
              className="card flex max-h-[min(92vh,640px)] w-full max-w-md flex-col overflow-hidden p-0 shadow-[0_24px_60px_rgba(0,0,0,0.55)]"
              onClick={(e) => e.stopPropagation()}
            >
              {/* Sticky header with always-visible close */}
              <div className="flex shrink-0 items-start justify-between gap-3 border-b border-[var(--border)] px-5 py-4">
                <div className="min-w-0">
                  <h2 id={titleId} className="text-lg font-semibold">
                    Bug / Suggest
                  </h2>
                  <p className="mt-0.5 text-xs text-[var(--text-muted)]">
                    Tell us what broke or what would help. We email the team when
                    you send this.
                  </p>
                </div>
                <button
                  type="button"
                  onClick={close}
                  className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg border border-[var(--border)] text-lg leading-none text-[var(--text-muted)] hover:bg-white/5 hover:text-[var(--text)]"
                  aria-label="Close"
                >
                  ×
                </button>
              </div>

              <div className="min-h-0 flex-1 overflow-y-auto px-5 py-4">
                {done ? (
                  <div className="rounded-lg border border-emerald-500/30 bg-emerald-500/10 px-3 py-3 text-sm text-emerald-200">
                    Thanks, we got it. You can close this window.
                  </div>
                ) : (
                  <form className="grid gap-3" onSubmit={onSubmit}>
                    <div className="flex gap-2">
                      {(
                        [
                          ["suggest", "Suggestion"],
                          ["bug", "Bug"],
                        ] as const
                      ).map(([id, label]) => (
                        <button
                          key={id}
                          type="button"
                          onClick={() => setKind(id)}
                          className={
                            kind === id
                              ? "rounded-lg border border-[var(--accent)] bg-[var(--accent-soft)] px-3 py-1.5 text-xs font-medium text-[var(--accent-strong)]"
                              : "rounded-lg border border-[var(--border)] px-3 py-1.5 text-xs text-[var(--text-muted)]"
                          }
                        >
                          {label}
                        </button>
                      ))}
                    </div>
                    <div>
                      <label className="label" htmlFor="fb-title">
                        Title
                      </label>
                      <input
                        id="fb-title"
                        className="input"
                        value={title}
                        onChange={(e) => setTitle(e.target.value)}
                        required
                        maxLength={200}
                        placeholder={
                          kind === "bug"
                            ? "What went wrong?"
                            : "What should we add?"
                        }
                        autoFocus
                      />
                    </div>
                    <div>
                      <label className="label" htmlFor="fb-body">
                        Details
                      </label>
                      <textarea
                        id="fb-body"
                        className="input min-h-[100px] max-h-[40vh]"
                        value={body}
                        onChange={(e) => setBody(e.target.value)}
                        required
                        maxLength={8000}
                        placeholder="Steps, expected vs actual, or your idea…"
                      />
                    </div>
                    {/* honeypot */}
                    <input
                      type="text"
                      name="website"
                      value={website}
                      onChange={(e) => setWebsite(e.target.value)}
                      className="hidden"
                      tabIndex={-1}
                      autoComplete="off"
                      aria-hidden
                    />
                    {error && (
                      <p className="text-sm text-[var(--danger)]">{error}</p>
                    )}
                    <div className="flex flex-wrap items-center justify-end gap-2 pt-1">
                      <button
                        type="button"
                        className="btn btn-secondary"
                        onClick={close}
                      >
                        Cancel
                      </button>
                      <button
                        type="submit"
                        className="btn btn-primary"
                        disabled={loading}
                      >
                        {loading ? "Sending…" : "Submit"}
                      </button>
                    </div>
                  </form>
                )}
                {done && (
                  <div className="mt-4 flex justify-end">
                    <button
                      type="button"
                      className="btn btn-primary"
                      onClick={close}
                    >
                      Close
                    </button>
                  </div>
                )}
              </div>
            </div>
          </div>,
          document.body
        )
      : null;

  if (!mounted) return null;

  return (
    <>
      {fab}
      {modal}
    </>
  );
}
