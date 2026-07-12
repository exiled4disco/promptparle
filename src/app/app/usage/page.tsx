import { redirect } from "next/navigation";
import { FreePlanToast } from "@/components/FreePlanToast";
import { PageHeader } from "@/components/PageHeader";
import { getSessionUser } from "@/lib/auth";
import { formatNumber, providerLabel } from "@/lib/format";
import { getUsageSummary } from "@/lib/usage";
import { getToolSavingsSummary } from "@/lib/tool-savings";
import { UsageHistory } from "./UsageHistory";

export const metadata = { title: "Usage" };

const TOOL_LABELS: Record<string, string> = {
  fleet: "Context fleet",
  relevant_slice: "Relevant slice",
  git: "Git (local)",
  ssh_read: "SSH read",
  error_brief: "Error brief",
  chat_memory: "Chat memory",
  budget_cap: "Budget cap",
  framing: "Framing",
};

function toolLabel(id: string): string {
  return TOOL_LABELS[id] ?? id;
}

export default async function UsagePage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");

  const usage = await getUsageSummary(user.id, {
    plan: user.plan,
    includePromptBodies: false,
  });

  const toolSavings = await getToolSavingsSummary(user.id, { sinceDays: 30 });

  const isFree = usage.planLimits.id === "free";

  const toolStats = toolSavings.byTool
    .slice()
    .sort((a, b) => b.tokensSaved - a.tokensSaved)
    .map((row) => ({
      id: row.tool,
      label: toolLabel(row.tool),
      tokensSaved: row.tokensSaved,
      occurrences: row.occurrences,
      pct:
        toolSavings.totalTokensSaved > 0
          ? Math.round((row.tokensSaved / toolSavings.totalTokensSaved) * 100)
          : 0,
    }));

  const providerStats = usage.byProvider.map((row) => {
    const saved = Math.max(0, row.originalTokens - row.optimizedTokens);
    const pct =
      row.originalTokens > 0
        ? Math.round((saved / row.originalTokens) * 100)
        : 0;
    return {
      id: row.provider,
      label: providerLabel(row.provider),
      count: row.count,
      saved,
      pct,
    };
  });

  return (
    <div className={`grid gap-5 ${isFree ? "pb-28 sm:pb-24" : ""}`}>
      <PageHeader
        title="Usage"
        description={
          <>
            Token savings and request history. We store <strong>stats and
            session titles only</strong>, never prompt or context text.
          </>
        }
      />

      {/* Stats + by-provider on one bar; history full width below */}
      <div className="card overflow-hidden">
        <div className="grid grid-cols-2 divide-y divide-[var(--border)] sm:grid-cols-4 sm:divide-x sm:divide-y-0">
          <StatCell label="Requests" value={formatNumber(usage.requestCount)} />
          <StatCell
            label="Original"
            value={formatNumber(usage.originalTokens)}
            hint="tokens"
          />
          <StatCell
            label="Optimized"
            value={formatNumber(usage.optimizedTokens)}
            hint="tokens"
          />
          <StatCell
            label="Saved"
            value={formatNumber(usage.tokensSaved)}
            hint={`${usage.reductionPercent}%`}
            accent
          />
        </div>

        <div className="flex flex-col gap-2 border-t border-[var(--border)] px-4 py-3 sm:flex-row sm:items-center sm:gap-4 sm:px-5">
          <div className="shrink-0 text-[0.7rem] font-medium uppercase tracking-wide text-[var(--text-dim)]">
            By provider
          </div>
          {providerStats.length > 0 ? (
            <div className="flex min-w-0 flex-wrap items-center gap-x-1 gap-y-1.5 text-sm">
              {providerStats.map((p, i) => (
                <span key={p.id} className="inline-flex items-center gap-1.5">
                  {i > 0 && (
                    <span
                      className="mx-1.5 text-[var(--border-strong)]"
                      aria-hidden
                    >
                      |
                    </span>
                  )}
                  <span className="font-medium text-[var(--text)]">
                    {p.label}
                  </span>
                  <span className="font-semibold text-[var(--success)]">
                    −{p.pct}%
                  </span>
                  <span className="text-xs text-[var(--text-dim)]">
                    ({formatNumber(p.count)} req · {formatNumber(p.saved)}{" "}
                    saved)
                  </span>
                </span>
              ))}
            </div>
          ) : (
            <p className="text-sm text-[var(--text-muted)]">
              Appears after your first completed request.
            </p>
          )}
        </div>
      </div>

      {/* Per-tool savings: total stat + one row per tool */}
      <div className="card overflow-hidden">
        <div className="grid grid-cols-2 divide-y divide-[var(--border)] sm:grid-cols-2 sm:divide-x sm:divide-y-0">
          <StatCell
            label="Tokens saved by tools"
            value={formatNumber(toolSavings.totalTokensSaved)}
            hint="tokens"
            accent
          />
          <StatCell
            label="Occurrences"
            value={formatNumber(toolSavings.totalOccurrences)}
            hint={`last ${toolSavings.sinceDays} days`}
          />
        </div>

        <div className="flex flex-col gap-2 border-t border-[var(--border)] px-4 py-3 sm:px-5">
          <div className="shrink-0 text-[0.7rem] font-medium uppercase tracking-wide text-[var(--text-dim)]">
            Savings by tool
          </div>
          {toolStats.length > 0 ? (
            <div className="grid gap-2">
              {toolStats.map((t) => (
                <div key={t.id} className="flex items-center gap-3 text-sm">
                  <span className="w-28 shrink-0 truncate font-medium text-[var(--text)]">
                    {t.label}
                  </span>
                  <span className="relative h-1.5 min-w-0 flex-1 overflow-hidden rounded-full bg-[var(--border)]">
                    <span
                      className="absolute inset-y-0 left-0 rounded-full bg-[var(--success)]"
                      style={{ width: `${Math.max(2, t.pct)}%` }}
                      aria-hidden
                    />
                  </span>
                  <span className="shrink-0 font-semibold text-[var(--success)]">
                    {formatNumber(t.tokensSaved)}
                  </span>
                  <span className="w-20 shrink-0 text-right text-xs text-[var(--text-dim)]">
                    {formatNumber(t.occurrences)} occ
                  </span>
                </div>
              ))}
            </div>
          ) : (
            <p className="text-sm text-[var(--text-muted)]">
              No per-tool savings recorded yet — use the desktop client to start
              tracking.
            </p>
          )}
        </div>
      </div>

      <section className="card min-h-[20rem] overflow-hidden">
        <div className="border-b border-[var(--border)] px-4 py-3 sm:px-5">
          <h2 className="text-sm font-semibold">Request History</h2>
          <p className="mt-0.5 text-xs text-[var(--text-dim)]">
            Session titles and token stats only, no prompt or context text.
            Delete a row or clear all; aggregate stats above stay.
          </p>
        </div>
        <UsageHistory
          rows={usage.recent.map((r) => ({
...r,
            createdAt:
              r.createdAt instanceof Date
                ? r.createdAt.toISOString()
                : String(r.createdAt),
          }))}
          planLabel={usage.planLimits.label}
          planId={usage.planLimits.id}
          originalCharsLimit={usage.planLimits.originalChars}
          upgradeHint={isFree ? usage.upgradeHint : null}
          storePrompts={usage.storePrompts}
          retentionPolicy={usage.retentionPolicy}
          compact
        />
      </section>

      {isFree && (
        <FreePlanToast
          limits={{
            dailyRequests: usage.planLimits.dailyRequests,
            originalChars: usage.planLimits.originalChars,
            maxProviders: usage.planLimits.maxProviders,
          }}
        />
      )}
    </div>
  );
}

function StatCell({
  label,
  value,
  hint,
  accent,
}: {
  label: string;
  value: string;
  hint?: string;
  accent?: boolean;
}) {
  return (
    <div className="px-4 py-3 sm:px-5 sm:py-3.5">
      <div className="text-[0.7rem] font-medium uppercase tracking-wide text-[var(--text-dim)]">
        {label}
      </div>
      <div
        className={`mt-0.5 flex items-baseline gap-1.5 text-xl font-semibold tracking-tight sm:text-2xl ${
          accent ? "text-[var(--success)]" : "text-[var(--text)]"
        }`}
      >
        {value}
        {hint ? (
          <span className="text-xs font-medium text-[var(--text-muted)]">
            {hint}
          </span>
        ) : null}
      </div>
    </div>
  );
}
