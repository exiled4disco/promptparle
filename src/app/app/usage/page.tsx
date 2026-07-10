import { redirect } from "next/navigation";
import { FreePlanToast } from "@/components/FreePlanToast";
import { getSessionUser } from "@/lib/auth";
import { formatNumber, providerLabel } from "@/lib/format";
import { getUsageSummary } from "@/lib/usage";
import { UsageHistory } from "./UsageHistory";

export const metadata = { title: "Usage" };

export default async function UsagePage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");

  const usage = await getUsageSummary(user.id, {
    plan: user.plan,
    includePromptBodies: true,
  });

  const isFree = usage.planLimits.id === "free";

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
      <div>
        <h1 className="page-title !text-left">Usage</h1>
        <p className="page-sub !mx-0 !text-left max-w-xl">
          Token savings and request history — expand a row for before/after.
        </p>
      </div>

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

      <section className="card min-h-[20rem] overflow-hidden">
        <div className="flex flex-wrap items-baseline justify-between gap-2 border-b border-[var(--border)] px-4 py-3 sm:px-5">
          <h2 className="text-sm font-semibold">Request history</h2>
          <p className="text-xs text-[var(--text-dim)]">
            Click a row for before/after
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
