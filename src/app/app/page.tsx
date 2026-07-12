import Link from "next/link";
import { getSessionUser } from "@/lib/auth";
import { listApiKeys } from "@/lib/api-keys";
import { getUsageSummary } from "@/lib/usage";
import { formatDate, formatNumber, providerLabel } from "@/lib/format";
import { redirect } from "next/navigation";
import { PageHeader } from "@/components/PageHeader";

export const metadata = { title: "Dashboard" };

export default async function DashboardPage({
  searchParams,
}: {
  searchParams: Promise<{ welcome?: string; code?: string }>;
}) {
  const user = await getSessionUser();
  if (!user) redirect("/login");
  const sp = await searchParams;
  const showWelcome = sp.welcome === "1";
  const inviteCode = sp.code || "";

  const [usage, keys] = await Promise.all([
    // Dashboard glance only. skip prompt body columns to cut DB read I/O
    getUsageSummary(user.id, {
      recentLimit: 8,
      includePromptBodies: false,
    }),
    listApiKeys(user.id),
  ]);

  const activeKeys = keys.filter((k) => k.status === "active");

  const steps = [
    {
      done: activeKeys.length > 0,
      title: "Create a desktop license key",
      href: "/app/api-keys",
      body: "Copy the pp_live_… key (shown once) into the desktop installer. Model keys go on the PC after install.",
    },
    {
      done: false,
      title: "Install desktop + set provider keys on this PC",
      href: "/install",
      body: "Run the installer, then pp → ⋯ → Providers (or Set-PromptParleProviderKey). Model keys stay on the PC.",
    },
    {
      done: usage.requestCount > 0,
      title: "Chat locally",
      href: "/install",
      body: "Local UI on 127.0.0.1. Optimize and model calls run on your machine (0.25+).",
    },
  ];

  return (
    <div className="grid gap-8">
      <PageHeader
        title={user.name ? `Hello, ${user.name}` : "Dashboard"}
        description="Account overview, token savings, and setup status."
      />

      {showWelcome && (
        <div className="alert alert-info text-sm leading-relaxed">
          <strong className="text-[var(--text)]">Account created.</strong> Check
          your email for install steps
          {inviteCode ? (
            <>
              {" "}
              and code{" "}
              <code className="rounded bg-black/30 px-1.5 py-0.5 font-mono tracking-wider text-[#93b4ff]">
                {inviteCode}
              </code>
            </>
          ) : null}
. Next: create a desktop license key (pp_live_…), run the installer,
          then set OpenAI/Claude/Gemini/Grok keys in the local UI (⋯ → Providers).
        </div>
      )}

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard
          label="Requests"
          value={formatNumber(usage.requestCount)}
        />
        <StatCard
          label="Tokens saved"
          value={formatNumber(usage.tokensSaved)}
          accent
        />
        <StatCard
          label="Avg reduction"
          value={`${usage.reductionPercent}%`}
        />
        <StatCard
          label="Desktop keys"
          value={String(activeKeys.length)}
        />
      </div>

      <div className="grid gap-6 lg:grid-cols-5">
        <section className="card p-6 lg:col-span-3">
          <div className="flex items-center justify-between gap-3">
            <h2 className="text-lg font-semibold">Setup checklist</h2>
            <span className="badge badge-accent">MVP portal</span>
          </div>
          <ul className="mt-5 grid gap-3">
            {steps.map((step, i) => (
              <li
                key={step.title}
                className="flex items-start gap-3 rounded-xl border border-[var(--border)] bg-[var(--bg)]/40 p-4"
              >
                <span
                  className={`mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-bold ${
                    step.done
                      ? "bg-[var(--success-soft)] text-[var(--success)]"
                      : "bg-[var(--bg-soft)] text-[var(--text-dim)]"
                  }`}
                >
                  {step.done ? "✓" : i + 1}
                </span>
                <div className="min-w-0 flex-1">
                  <div className="font-medium">{step.title}</div>
                  <p className="mt-0.5 text-sm text-[var(--text-muted)]">
                    {step.body}
                  </p>
                </div>
                <Link href={step.href} className="btn btn-secondary text-sm">
                  {step.done ? "View" : "Set up"}
                </Link>
              </li>
            ))}
          </ul>
        </section>

        <section className="card p-6 lg:col-span-2">
          <h2 className="text-lg font-semibold">Quick links</h2>
          <div className="mt-4 grid gap-2">
            <Link href="/app/providers" className="btn btn-secondary justify-start">
              Manage provider keys
            </Link>
            <Link href="/app/api-keys" className="btn btn-secondary justify-start">
              Create desktop API key
            </Link>
            <Link href="/app/usage" className="btn btn-secondary justify-start">
              View usage history
            </Link>
            <Link href="/app/settings" className="btn btn-secondary justify-start">
              Retention settings
            </Link>
          </div>
          <div className="mt-6 rounded-xl border border-[var(--border)] bg-[var(--accent-soft)] p-4 text-sm text-[#bfdbfe]">
            Usage appears when clients call{" "}
            <span className="mono">POST /api/v1/prompt</span> with a desktop
            API key. Optimize-only and full provider routing are both live.
          </div>
        </section>
      </div>

      <section className="card overflow-hidden">
        <div className="flex items-center justify-between border-b border-[var(--border)] px-6 py-4">
          <h2 className="text-lg font-semibold">Recent activity</h2>
          <Link href="/app/usage" className="text-sm text-[#93b4ff] hover:underline">
            View all
          </Link>
        </div>
        {usage.recent.length === 0 ? (
          <p className="p-6 text-sm text-[var(--text-muted)]">
            No prompts yet. Activity appears after desktop clients call the API.
          </p>
        ) : (
          <div className="overflow-x-auto">
            <table className="table">
              <thead>
                <tr>
                  <th>When</th>
                  <th>Provider</th>
                  <th>Profile</th>
                  <th>Original</th>
                  <th>Optimized</th>
                  <th>Saved</th>
                </tr>
              </thead>
              <tbody>
                {usage.recent.slice(0, 8).map((row) => {
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
                      <td>
                        <span className="badge">{row.optimizationProfile}</span>
                      </td>
                      <td className="mono">{formatNumber(row.originalTokens)}</td>
                      <td className="mono">{formatNumber(row.optimizedTokens)}</td>
                      <td>
                        <span className="badge badge-success">
                          {pct}% · {formatNumber(saved)}
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

function StatCard({
  label,
  value,
  accent,
}: {
  label: string;
  value: string;
  accent?: boolean;
}) {
  return (
    <div className="card p-5">
      <div className="text-sm text-[var(--text-dim)]">{label}</div>
      <div
        className={`stat-value mt-1 ${accent ? "text-[var(--success)]" : ""}`}
      >
        {value}
      </div>
    </div>
  );
}
