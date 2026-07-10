"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { formatDate, formatNumber, providerLabel } from "@/lib/format";

export type UsageRow = {
  id: string;
  provider: string;
  model: string | null;
  optimizationProfile: string;
  originalTokens: number;
  optimizedTokens: number;
  status: string;
  createdAt: string | Date;
  promptPreview: string | null;
  /** Present only when portal loads with includePromptBodies */
  originalText?: string | null;
  optimizedText?: string | null;
  originalTruncated?: boolean;
  optimizedTruncated?: boolean;
  errorMessage?: string | null;
  reductionPercent: number;
  tokensSaved: number;
  hasCompare: boolean;
};

type Props = {
  rows: UsageRow[];
  planLabel: string;
  planId?: string;
  /** Current plan max chars (for messaging) */
  originalCharsLimit?: number;
  upgradeHint: string | null;
  storePrompts: boolean;
  retentionPolicy: string;
  /** Tighter row density for dual-column Usage layout */
  compact?: boolean;
};

export function UsageHistory({
  rows: initialRows,
  planLabel,
  planId = "free",
  originalCharsLimit = 2000,
  upgradeHint,
  storePrompts,
  retentionPolicy,
  compact = false,
}: Props) {
  const router = useRouter();
  const [rows, setRows] = useState(initialRows);
  const [openId, setOpenId] = useState<string | null>(
    initialRows.find((r) => r.hasCompare)?.id ?? null
  );
  const [busyId, setBusyId] = useState<string | null>(null);
  const [clearing, setClearing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function deleteOne(id: string) {
    if (busyId || clearing) return;
    if (!confirm("Delete this request from history? This cannot be undone.")) {
      return;
    }
    setError(null);
    setBusyId(id);
    try {
      const res = await fetch(`/api/usage/${encodeURIComponent(id)}`, {
        method: "DELETE",
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        setError(data.error || "Failed to delete");
        return;
      }
      setRows((prev) => prev.filter((r) => r.id !== id));
      if (openId === id) setOpenId(null);
      router.refresh();
    } catch {
      setError("Network error deleting request");
    } finally {
      setBusyId(null);
    }
  }

  async function clearAll() {
    if (busyId || clearing || rows.length === 0) return;
    if (
      !confirm(
        `Clear all request history (${rows.length}+ rows shown; deletes every stored request for your account)? This cannot be undone.`
      )
    ) {
      return;
    }
    setError(null);
    setClearing(true);
    try {
      const res = await fetch("/api/usage?all=1", { method: "DELETE" });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        setError(data.error || "Failed to clear history");
        return;
      }
      setRows([]);
      setOpenId(null);
      router.refresh();
    } catch {
      setError("Network error clearing history");
    } finally {
      setClearing(false);
    }
  }

  if (rows.length === 0) {
    return (
      <div>
        {error && (
          <div className="border-b border-[var(--border)] bg-[var(--danger-soft)] px-4 py-2.5 text-xs text-[var(--danger)] sm:px-5">
            {error}
          </div>
        )}
        <p className="p-5 text-sm text-[var(--text-muted)]">
          No request history. Send a request from the desktop client or portal
          chat, then refresh this page to see before/after text.
        </p>
      </div>
    );
  }

  const pad = compact ? "px-3 py-2.5 sm:px-4" : "px-4 py-4 sm:px-6";

  return (
    <div>
      {error && (
        <div className="border-b border-[var(--border)] bg-[var(--danger-soft)] px-4 py-2.5 text-xs text-[var(--danger)] sm:px-5">
          {error}
        </div>
      )}
      {(!storePrompts || retentionPolicy === "none") && (
        <div className="border-b border-[var(--border)] bg-[var(--warning)]/10 px-4 py-2.5 text-xs text-[var(--warning)] sm:px-5">
          Prompt text storage is off. Token counts still appear, but before/after
          text will not. Enable storage under{" "}
          <a href="/app/settings" className="underline">
            Settings
          </a>
          .
        </div>
      )}
      {upgradeHint && (
        <div className="border-b border-[var(--border)] bg-[var(--accent-soft)] px-4 py-2.5 text-xs text-[var(--text-muted)] sm:px-5">
          <span className="font-medium text-[var(--text)]">{planLabel} plan.</span>{" "}
          {upgradeHint}
        </div>
      )}

      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--border)] px-4 py-2 sm:px-5">
        <p className="text-xs text-[var(--text-dim)]">
          {rows.length} listed · click a row for before/after
        </p>
        <button
          type="button"
          className="btn btn-secondary !px-2.5 !py-1 text-xs"
          disabled={clearing || Boolean(busyId)}
          onClick={() => void clearAll()}
        >
          {clearing ? "Clearing…" : "Clear all history"}
        </button>
      </div>

      <div className="divide-y divide-[var(--border)]">
        {rows.map((row) => {
          const open = openId === row.id;
          const busy = busyId === row.id;
          return (
            <div key={row.id} className={pad}>
              <div className="flex w-full flex-wrap items-center gap-x-2 gap-y-1.5">
                <button
                  type="button"
                  className="flex min-w-0 flex-1 flex-wrap items-center gap-x-3 gap-y-1.5 text-left"
                  onClick={() => setOpenId(open ? null : row.id)}
                  aria-expanded={open}
                >
                  <span className="w-3 text-xs text-[var(--text-dim)]">
                    {open ? "▾" : "▸"}
                  </span>
                  <span className="whitespace-nowrap text-xs text-[var(--text-muted)]">
                    {formatDate(row.createdAt)}
                  </span>
                  <span className="text-sm font-medium">
                    {providerLabel(row.provider)}
                  </span>
                  <span className="mono text-[0.7rem] text-[var(--text-dim)]">
                    {row.model || "—"}
                  </span>
                  <span className="badge text-[0.65rem]">
                    {row.optimizationProfile}
                  </span>
                  <span className="mono text-xs sm:text-sm">
                    {formatNumber(row.originalTokens)} →{" "}
                    {formatNumber(row.optimizedTokens)}
                  </span>
                  {row.optimizedTokens > row.originalTokens ? (
                    <span
                      className="badge badge-warn text-[0.65rem]"
                      title="Payload grew vs raw input (should be rare)"
                    >
                      expanded
                    </span>
                  ) : row.reductionPercent > 0 ? (
                    <span className="badge badge-success text-[0.65rem]">
                      −{row.reductionPercent}%
                    </span>
                  ) : (
                    <span
                      className="badge text-[0.65rem]"
                      title="Already compact — unique prose/docs often show 0%. Savings show up on noisy logs, dupes, and filler."
                    >
                      0%
                    </span>
                  )}
                  <span
                    className={`badge text-[0.65rem] ${
                      row.status === "completed" ? "badge-success" : "badge-warn"
                    }`}
                  >
                    {row.status}
                  </span>
                </button>
                <button
                  type="button"
                  className="shrink-0 rounded-md border border-[var(--border)] px-2 py-1 text-[0.7rem] text-[var(--text-muted)] hover:border-[var(--danger)]/50 hover:text-[var(--danger)] disabled:opacity-50"
                  disabled={busy || clearing}
                  title="Delete this request"
                  onClick={(e) => {
                    e.stopPropagation();
                    void deleteOne(row.id);
                  }}
                >
                  {busy ? "…" : "Delete"}
                </button>
              </div>

              {open && (
                <div className="mt-3 grid gap-3 md:grid-cols-2">
                  <ComparePane
                    title="Before"
                    subtitle={`${formatNumber(row.originalTokens)} tok`}
                    text={row.originalText ?? null}
                    truncated={Boolean(row.originalTruncated)}
                    truncNote={truncNoteFor(planId, planLabel, originalCharsLimit)}
                    emptyHint="No original text stored for this request."
                    compact={compact}
                  />
                  <ComparePane
                    title="After"
                    subtitle={`${formatNumber(row.optimizedTokens)} tok · −${formatNumber(row.tokensSaved)}`}
                    text={row.optimizedText ?? null}
                    truncated={Boolean(row.optimizedTruncated)}
                    truncNote={truncNoteFor(planId, planLabel, originalCharsLimit)}
                    emptyHint="No optimized text stored for this request."
                    accent
                    compact={compact}
                  />
                  {row.errorMessage && (
                    <div className="md:col-span-2 rounded-xl border border-[var(--danger)]/40 bg-[var(--danger-soft)] p-3 text-sm text-[var(--danger)]">
                      Error: {row.errorMessage}
                    </div>
                  )}
                  {row.promptPreview && !row.originalText && (
                    <div className="md:col-span-2 text-xs text-[var(--text-dim)]">
                      Preview: {row.promptPreview}
                    </div>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

function truncNoteFor(
  planId: string,
  planLabel: string,
  currentLimit: number
): string {
  // Rows clipped at store-time (e.g. Free 2k) cannot be restored after upgrade
  if (planId === "team" || planId === "pro") {
    return (
      `Stored truncated under a lower plan limit (text is gone permanently). ` +
      `Your ${planLabel} plan keeps up to ${currentLimit.toLocaleString()} characters on new requests.`
    );
  }
  return `Truncated by Free plan (${currentLimit.toLocaleString()} chars). Upgrade to Pro/Team for longer before/after history on new requests.`;
}

function ComparePane({
  title,
  subtitle,
  text,
  truncated,
  truncNote,
  emptyHint,
  accent,
  compact,
}: {
  title: string;
  subtitle: string;
  text: string | null;
  truncated: boolean;
  truncNote?: string;
  emptyHint: string;
  accent?: boolean;
  compact?: boolean;
}) {
  return (
    <div
      className={`rounded-xl border ${compact ? "p-3" : "p-4"} ${
        accent
          ? "border-[var(--success)]/30 bg-[var(--success-soft)]/30"
          : "border-[var(--border)] bg-[var(--bg)]/50"
      }`}
    >
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h3 className="text-sm font-semibold">{title}</h3>
        <span className="text-xs text-[var(--text-dim)]">{subtitle}</span>
      </div>
      {text ? (
        <>
          <pre
            className={`mt-2 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-black/30 p-3 font-mono text-xs leading-relaxed text-[var(--text)] ${
              compact ? "max-h-64" : "max-h-96"
            }`}
          >
            {text}
          </pre>
          {truncated && (
            <p className="mt-2 text-xs text-[var(--warning)]">
              {truncNote ||
                "Truncated by your plan limit. Upgrade to see more of this prompt."}
            </p>
          )}
        </>
      ) : (
        <p className="mt-2 text-sm text-[var(--text-muted)]">{emptyHint}</p>
      )}
    </div>
  );
}
