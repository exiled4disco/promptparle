import { redirect } from "next/navigation";
import { getSessionUser } from "@/lib/auth";
import { getUsageSummary } from "@/lib/usage";
import { formatNumber, providerLabel } from "@/lib/format";
import { UsageHistory } from "./UsageHistory";

export const metadata = { title: "Usage" };

export default async function UsagePage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");

  const usage = await getUsageSummary(user.id, { plan: user.plan });

  return (
    <div className="grid gap-6">
      <div>
        <h1 className="page-title">Usage & before/after</h1>
        <p className="page-sub">
          See original prompts vs optimized context, token savings, and request
          history. Free plans show a shorter preview; paid plans store more.
        </p>
      </div>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <div className="card p-5">
          <div className="text-sm text-[var(--text-dim)]">Total requests</div>
          <div className="stat-value mt-1">{formatNumber(usage.requestCount)}</div>
        </div>
        <div className="card p-5">
          <div className="text-sm text-[var(--text-dim)]">Original tokens</div>
          <div className="stat-value mt-1">
            {formatNumber(usage.originalTokens)}
          </div>
        </div>
        <div className="card p-5">
          <div className="text-sm text-[var(--text-dim)]">Optimized tokens</div>
          <div className="stat-value mt-1">
            {formatNumber(usage.optimizedTokens)}
          </div>
        </div>
        <div className="card p-5">
          <div className="text-sm text-[var(--text-dim)]">Tokens saved</div>
          <div className="stat-value mt-1 text-[var(--success)]">
            {formatNumber(usage.tokensSaved)}{" "}
            <span className="text-base font-semibold text-[var(--text-muted)]">
              ({usage.reductionPercent}%)
            </span>
          </div>
        </div>
      </div>

      <div className="card flex flex-wrap items-center justify-between gap-3 p-4 text-sm">
        <div>
          <span className="capitalize font-medium">{usage.planLimits.label}</span>
          {" plan · "}
          before/after up to{" "}
          <span className="mono">
            {formatNumber(usage.planLimits.originalChars)}
          </span>{" "}
          chars each side · last {usage.planLimits.historyLimit} requests
        </div>
        {usage.planLimits.id === "free" && (
          <span className="badge badge-accent">Upgrade for full history</span>
        )}
      </div>

      {usage.byProvider.length > 0 && (
        <section className="card p-6">
          <h2 className="text-lg font-semibold">By provider</h2>
          <div className="mt-4 grid gap-3 sm:grid-cols-2">
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
                <div
                  key={row.provider}
                  className="rounded-xl border border-[var(--border)] bg-[var(--bg)]/40 p-4"
                >
                  <div className="font-medium">{providerLabel(row.provider)}</div>
                  <div className="mt-1 text-sm text-[var(--text-muted)]">
                    {formatNumber(row.count)} requests · {pct}% reduction ·{" "}
                    {formatNumber(saved)} tokens saved
                  </div>
                </div>
              );
            })}
          </div>
        </section>
      )}

      <section className="card overflow-hidden">
        <div className="border-b border-[var(--border)] px-6 py-4">
          <h2 className="text-lg font-semibold">Request history</h2>
          <p className="mt-1 text-sm text-[var(--text-muted)]">
            Expand a row to compare original input vs optimized prompt sent to
            the model.
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
          upgradeHint={usage.upgradeHint}
          storePrompts={usage.storePrompts}
          retentionPolicy={usage.retentionPolicy}
        />
      </section>
    </div>
  );
}
