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
  originalText: string | null;
  optimizedText: string | null;
  originalTruncated: boolean;
  optimizedTruncated: boolean;
  errorMessage: string | null;
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
};

export function UsageHistory({
  rows,
  planLabel,
  upgradeHint,
  storePrompts,
  retentionPolicy,
}: Props) {
  const [openId, setOpenId] = useState<string | null>(
    rows.find((r) => r.hasCompare)?.id ?? null
  );

  if (rows.length === 0) {
    return (
      <p className="p-6 text-sm text-[var(--text-muted)]">
        No usage yet. Send a request from PowerShell with{" "}
        <span className="mono">Invoke-PromptParle</span>, then refresh this page
        to see before/after text.
      </p>
    );
  }

  return (
    <div>
      {(!storePrompts || retentionPolicy === "none") && (
        <div className="border-b border-[var(--border)] bg-[var(--warning)]/10 px-6 py-3 text-sm text-[var(--warning)]">
          Prompt text storage is off. Token counts still appear, but before/after
          text will not. Enable storage under{" "}
          <a href="/app/settings" className="underline">
            Settings
          </a>
          .
        </div>
      )}
      {upgradeHint && (
        <div className="border-b border-[var(--border)] bg-[var(--accent-soft)] px-6 py-3 text-sm text-[var(--text-muted)]">
          <span className="font-medium text-[var(--text)]">{planLabel} plan.</span>{" "}
          {upgradeHint}
        </div>
      )}

      <div className="divide-y divide-[var(--border)]">
        {rows.map((row) => {
          const open = openId === row.id;
          return (
            <div key={row.id} className="px-4 py-4 sm:px-6">
              <button
                type="button"
                className="flex w-full flex-wrap items-center gap-x-4 gap-y-2 text-left"
                onClick={() => setOpenId(open ? null : row.id)}
                aria-expanded={open}
              >
                <span className="text-sm text-[var(--text-dim)]">
                  {open ? "▾" : "▸"}
                </span>
                <span className="text-sm text-[var(--text-muted)] whitespace-nowrap">
                  {formatDate(row.createdAt)}
                </span>
                <span className="font-medium">
                  {providerLabel(row.provider)}
                </span>
                <span className="mono text-xs text-[var(--text-dim)]">
                  {row.model || "—"}
                </span>
                <span className="badge">{row.optimizationProfile}</span>
                <span className="mono text-sm">
                  {formatNumber(row.originalTokens)} →{" "}
                  {formatNumber(row.optimizedTokens)}
                </span>
                {row.optimizedTokens > row.originalTokens ? (
                  <span className="badge badge-warn" title="Payload grew vs raw input">
                    expanded
                  </span>
                ) : row.reductionPercent > 0 ? (
                  <span className="badge badge-success">
                    −{row.reductionPercent}%
                  </span>
                ) : (
                  <span className="badge" title="No size change">
                    0%
                  </span>
                )}
                <span
                  className={`badge ${
                    row.status === "completed" ? "badge-success" : "badge-warn"
                  }`}
                >
                  {row.status}
                </span>
                {row.hasCompare ? (
                  <span className="text-xs text-[var(--accent-strong)]">
                    before/after
                  </span>
                ) : (
                  <span className="text-xs text-[var(--text-dim)]">
                    metadata only
                  </span>
                )}
              </button>

              {open && (
                <div className="mt-4 grid gap-4 lg:grid-cols-2">
                  <ComparePane
                    title="Before (original)"
                    subtitle={`${formatNumber(row.originalTokens)} tokens`}
                    text={row.originalText}
                    truncated={row.originalTruncated}
                    emptyHint="No original text stored for this request."
                  />
                  <ComparePane
                    title="After (optimized)"
                    subtitle={`${formatNumber(row.optimizedTokens)} tokens · saved ${formatNumber(row.tokensSaved)}`}
                    text={row.optimizedText}
                    truncated={row.optimizedTruncated}
                    emptyHint="No optimized text stored for this request."
                    accent
                  />
                  {row.errorMessage && (
                    <div className="lg:col-span-2 rounded-xl border border-[var(--danger)]/40 bg-[var(--danger-soft)] p-4 text-sm text-[var(--danger)]">
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
}: {
  title: string;
  subtitle: string;
  text: string | null;
  truncated: boolean;
  emptyHint: string;
  accent?: boolean;
}) {
  return (
    <div
      className={`rounded-xl border p-4 ${
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
          <pre className="mt-3 max-h-96 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-black/30 p-3 font-mono text-xs leading-relaxed text-[var(--text)]">
            {text}
          </pre>
          {truncated && (
            <p className="mt-2 text-xs text-[var(--warning)]">
              Truncated by your plan limit. Upgrade to see more of this prompt.
            </p>
          )}
        </>
      ) : (
        <p className="mt-3 text-sm text-[var(--text-muted)]">{emptyHint}</p>
      )}
    </div>
  );
}
