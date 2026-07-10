"use client";

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
  upgradeHint: string | null;
  storePrompts: boolean;
  retentionPolicy: string;
  /** Tighter row density for dual-column Usage layout */
  compact?: boolean;
};

export function UsageHistory({
  rows,
  planLabel,
  upgradeHint,
  storePrompts,
  retentionPolicy,
  compact = false,
}: Props) {
  const [openId, setOpenId] = useState<string | null>(
    rows.find((r) => r.hasCompare)?.id ?? null
  );

  if (rows.length === 0) {
    return (
      <p className="p-5 text-sm text-[var(--text-muted)]">
        No usage yet. Send a request from PowerShell with{" "}
        <span className="mono">Invoke-PromptParle</span>, then refresh this page
        to see before/after text.
      </p>
    );
  }

  const pad = compact ? "px-3 py-2.5 sm:px-4" : "px-4 py-4 sm:px-6";

  return (
    <div>
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

      <div className="divide-y divide-[var(--border)]">
        {rows.map((row) => {
          const open = openId === row.id;
          return (
            <div key={row.id} className={pad}>
              <button
                type="button"
                className="flex w-full flex-wrap items-center gap-x-3 gap-y-1.5 text-left"
                onClick={() => setOpenId(open ? null : row.id)}
                aria-expanded={open}
              >
                <span className="w-3 text-xs text-[var(--text-dim)]">
                  {open ? "▾" : "▸"}
                </span>
                <span className="text-xs text-[var(--text-muted)] whitespace-nowrap">
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

              {open && (
                <div className="mt-3 grid gap-3 md:grid-cols-2">
                  <ComparePane
                    title="Before"
                    subtitle={`${formatNumber(row.originalTokens)} tok`}
                    text={row.originalText ?? null}
                    truncated={Boolean(row.originalTruncated)}
                    emptyHint="No original text stored for this request."
                    compact={compact}
                  />
                  <ComparePane
                    title="After"
                    subtitle={`${formatNumber(row.optimizedTokens)} tok · −${formatNumber(row.tokensSaved)}`}
                    text={row.optimizedText ?? null}
                    truncated={Boolean(row.optimizedTruncated)}
                    emptyHint="No optimized text stored for this request."
                    accent
                    compact={compact}
                  />
                  {row.errorMessage && (
                    <div className="md:col-span-2 rounded-xl border border-[var(--danger)]/40 bg-[var(--danger-soft)] p-3 text-sm text-[var(--danger)]">
                      Error: {row.errorMessage}
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

function ComparePane({
  title,
  subtitle,
  text,
  truncated,
  emptyHint,
  accent,
  compact,
}: {
  title: string;
  subtitle: string;
  text: string | null;
  truncated: boolean;
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
              Truncated by your plan limit. Upgrade to see more of this prompt.
            </p>
          )}
        </>
      ) : (
        <p className="mt-2 text-sm text-[var(--text-muted)]">{emptyHint}</p>
      )}
    </div>
  );
}
