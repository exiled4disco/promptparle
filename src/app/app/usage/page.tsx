import { redirect } from "next/navigation";
import { getSessionUser } from "@/lib/auth";
import { getUsageSummary } from "@/lib/usage";
import { formatDate, formatNumber, providerLabel } from "@/lib/format";

export const metadata = { title: "Usage" };

export default async function UsagePage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");

  const usage = await getUsageSummary(user.id);

  return (
    <div className="grid gap-6">
      <div>
        <h1 className="page-title">Usage & token savings</h1>
        <p className="page-sub">
          Metadata from optimized prompt requests. Prompt content is only
          retained when you enable it in Settings.
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
        </div>
        {usage.recent.length === 0 ? (
          <p className="p-6 text-sm text-[var(--text-muted)]">
            No usage yet. Rows appear when desktop clients call{" "}
            <span className="mono">POST /v1/prompt</span>.
          </p>
        ) : (
          <div className="overflow-x-auto">
            <table className="table">
              <thead>
                <tr>
                  <th>When</th>
                  <th>Provider</th>
                  <th>Model</th>
                  <th>Profile</th>
                  <th>Original</th>
                  <th>Optimized</th>
                  <th>Reduction</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {usage.recent.map((row) => {
                  const saved = Math.max(
                    0,
                    row.originalTokens - row.optimizedTokens
                  );
                  const pct =
                    row.originalTokens > 0
                      ? Math.round((saved / row.originalTokens) * 100)
                      : 0;
                  return (
                    <tr key={row.id}>
                      <td className="whitespace-nowrap text-[var(--text-muted)]">
                        {formatDate(row.createdAt)}
                      </td>
                      <td>{providerLabel(row.provider)}</td>
                      <td className="mono text-sm text-[var(--text-muted)]">
                        {row.model || "—"}
                      </td>
                      <td>
                        <span className="badge">{row.optimizationProfile}</span>
                      </td>
                      <td className="mono">{formatNumber(row.originalTokens)}</td>
                      <td className="mono">{formatNumber(row.optimizedTokens)}</td>
                      <td>
                        <span className="badge badge-success">{pct}%</span>
                      </td>
                      <td>
                        <span
                          className={`badge ${
                            row.status === "completed"
                              ? "badge-success"
                              : "badge-warn"
                          }`}
                        >
                          {row.status}
                        </span>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}
