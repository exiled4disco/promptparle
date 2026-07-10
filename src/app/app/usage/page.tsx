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

  const metrics = [
    {
      label: "Requests",
      value: formatNumber(usage.requestCount),
    },
    {
      label: "Original",
      value: formatNumber(usage.originalTokens),
      hint: "tokens",
    },
    {
      label: "Optimized",
      value: formatNumber(usage.optimizedTokens),
      hint: "tokens",
    },
    {
      label: "Saved",
      value: formatNumber(usage.tokensSaved),
      hint: `${usage.reductionPercent}%`,
      accent: true,
    },
  ] as const;

  return (
    <div className={`grid gap-5 ${isFree ? "pb-28 sm:pb-24" : ""}`}>
      <div className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 className="page-title !text-left">Usage</h1>
          <p className="page-sub !mx-0 !text-left max-w-xl">
            Token savings and request history — expand a row for before/after.
          </p>
        </div>
        {usage.reductionPercent > 0 && (
          <div className="shrink-0 rounded-xl border border-[var(--success)]/25 bg-[var(--success-soft)]/40 px-4 py-2 text-sm">
            <span className="text-[var(--text-dim)]">Avg reduction </span>
            <span className="font-semibold text-[var(--success)]">
              {usage.reductionPercent}%
            </span>
          </div>
        )}
      </div>

      {/* Compact KPI strip — one bar, not a card grid */}
      <div className="card overflow-hidden">
        <div className="grid grid-cols-2 divide-y divide-[var(--border)] sm:grid-cols-4 sm:divide-x sm:divide-y-0">
          {metrics.map((m) => (
            <div key={m.label} className="px-4 py-3 sm:px-5 sm:py-3.5">
              <div className="text-[0.7rem] font-medium uppercase tracking-wide text-[var(--text-dim)]">
                {m.label}
              </div>
              <div
                className={`mt-0.5 flex items-baseline gap-1.5 text-xl font-semibold tracking-tight sm:text-2xl ${
                  "accent" in m && m.accent
                    ? "text-[var(--success)]"
                    : "text-[var(--text)]"
                }`}
              >
                {m.value}
                {"hint" in m && m.hint ? (
                  <span className="text-xs font-medium text-[var(--text-muted)]">
                    {m.hint}
                  </span>
                ) : null}
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Dual column: providers (narrow) · history (wide) */}
      <div className="grid gap-5 lg:grid-cols-[minmax(0,15rem)_minmax(0,1fr)] xl:grid-cols-[minmax(0,17rem)_minmax(0,1fr)] lg:items-start">
        <aside className="card p-4">
          <h2 className="text-sm font-semibold text-[var(--text)]">
            By provider
          </h2>
          {usage.byProvider.length > 0 ? (
            <ul className="mt-3 space-y-2">
              {usage.byProvider.map((row) => {
                const saved = Math.max(
                  0,
                  row.originalTokens - row.optimizedTokens
                );
                const pct =
                  row.originalTokens > 0
                    ? Math.round((saved / row.originalTokens) * 100)
                    : 0;
                return (
                  <li
                    key={row.provider}
                    className="rounded-lg border border-[var(--border)] bg-[var(--bg)]/40 px-3 py-2.5"
                  >
                    <div className="flex items-center justify-between gap-2">
                      <span className="text-sm font-medium">
                        {providerLabel(row.provider)}
                      </span>
                      <span className="badge badge-success text-[0.65rem]">
                        −{pct}%
                      </span>
                    </div>
                    <div className="mt-1 text-xs text-[var(--text-muted)]">
                      {formatNumber(row.count)} req ·{" "}
                      {formatNumber(saved)} saved
                    </div>
                  </li>
                );
              })}
            </ul>
          ) : (
            <p className="mt-2 text-xs leading-relaxed text-[var(--text-muted)]">
              Breakdown appears after your first completed request.
            </p>
          )}
        </aside>

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
            upgradeHint={isFree ? null : usage.upgradeHint}
            storePrompts={usage.storePrompts}
            retentionPolicy={usage.retentionPolicy}
            compact
          />
        </section>
      </div>

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
