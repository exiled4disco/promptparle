"use client";

import { useCallback, useEffect, useMemo, useState } from "react";

type AccountRow = {
  id: string;
  email: string;
  name: string | null;
  plan: string;
  isAdmin: boolean;
  verified: boolean;
  disabled: boolean;
  disabledAt: string | null;
  disabledReason: string | null;
  emailVerifiedAt: string | null;
  createdAt: string;
  lastActiveAt: string | null;
  lastIp: string | null;
  lastCountry: string | null;
  lastCountryCode: string | null;
  lastIpAt: string | null;
  lastDesktop: {
    hostname: string | null;
    platform: string | null;
    lastSeenAt: string;
  } | null;
  preferredProvider: string | null;
  counts: {
    apiKeys: number;
    providers: number;
    sessions: number;
    desktopClients: number;
    promptRequests: number;
  };
};

type Summary = {
  total: number;
  active: number;
  disabled: number;
  admins: number;
};

type Filter = "all" | "active" | "disabled" | "unverified" | "admin";

export function AccountsClient() {
  const [rows, setRows] = useState<AccountRow[]>([]);
  const [summary, setSummary] = useState<Summary | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState<Filter>("active");
  const [q, setQ] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await fetch("/api/admin/users", { cache: "no-store" });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Failed to load accounts");
        return;
      }
      setRows(data.users || []);
      setSummary(data.summary || null);
    } catch {
      setError("Network error loading accounts");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const filtered = useMemo(() => {
    const needle = q.trim().toLowerCase();
    return rows.filter((r) => {
      if (filter === "active" && (!r.verified || r.disabled)) return false;
      if (filter === "disabled" && !r.disabled) return false;
      if (filter === "unverified" && r.verified) return false;
      if (filter === "admin" && !r.isAdmin) return false;
      if (!needle) return true;
      const hay =
        `${r.email} ${r.name || ""} ${r.plan} ${r.lastIp || ""} ${r.lastCountry || ""} ${r.lastCountryCode || ""}`.toLowerCase();
      return hay.includes(needle);
    });
  }, [rows, filter, q]);

  async function onDisable(r: AccountRow) {
    const reason =
      window.prompt(
        `Disable ${r.email}? Optional reason (shown in admin only):`,
        r.disabledReason || ""
      ) ?? null;
    if (reason === null) return;
    setBusyId(r.id);
    setError(null);
    try {
      const res = await fetch(`/api/admin/users/${r.id}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "disable",
          reason: reason.trim() || null,
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Could not disable account");
        return;
      }
      await load();
    } catch {
      setError("Network error");
    } finally {
      setBusyId(null);
    }
  }

  async function onEnable(r: AccountRow) {
    if (!window.confirm(`Re-enable ${r.email}?`)) return;
    setBusyId(r.id);
    setError(null);
    try {
      const res = await fetch(`/api/admin/users/${r.id}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "enable" }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Could not enable account");
        return;
      }
      await load();
    } catch {
      setError("Network error");
    } finally {
      setBusyId(null);
    }
  }

  async function onDelete(r: AccountRow) {
    const typed = window.prompt(
      `Permanently delete ${r.email} and all related data (keys, usage, sessions)?\n\nType DELETE to confirm:`
    );
    if (typed !== "DELETE") return;
    setBusyId(r.id);
    setError(null);
    try {
      const res = await fetch(`/api/admin/users/${r.id}`, { method: "DELETE" });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Could not delete account");
        return;
      }
      await load();
    } catch {
      setError("Network error");
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="grid gap-3">
      {summary && (
        <div className="grid gap-2 sm:grid-cols-4">
          <Stat label="Registered" value={summary.total} />
          <Stat label="Active" value={summary.active} />
          <Stat label="Disabled" value={summary.disabled} />
          <Stat label="Admins" value={summary.admins} />
        </div>
      )}

      <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex flex-wrap gap-1">
          {(
            [
              ["active", "Active"],
              ["all", "All"],
              ["disabled", "Disabled"],
              ["unverified", "Unverified"],
              ["admin", "Admins"],
            ] as const
          ).map(([id, label]) => (
            <button
              key={id}
              type="button"
              onClick={() => setFilter(id)}
              className={
                filter === id
                  ? "rounded-lg border border-[var(--accent)] bg-[var(--accent-soft)] px-3 py-1.5 text-xs font-medium text-[var(--accent-strong)]"
                  : "rounded-lg border border-[var(--border)] px-3 py-1.5 text-xs text-[var(--text-muted)] hover:bg-white/5"
              }
            >
              {label}
            </button>
          ))}
        </div>
        <div className="flex items-center gap-2">
          <input
            type="search"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Search name, email, IP, country…"
            className="input !py-1.5 text-sm sm:w-56"
          />
          <button
            type="button"
            className="btn btn-secondary !py-1.5 !text-sm"
            onClick={() => void load()}
            disabled={loading}
          >
            Refresh
          </button>
        </div>
      </div>

      {error && (
        <div className="rounded-lg border border-[var(--danger)]/40 bg-[rgba(248,113,113,0.08)] px-3 py-2 text-sm text-[var(--danger)]">
          {error}
        </div>
      )}

      <div className="card overflow-x-auto p-0">
        <table className="w-full min-w-[1040px] text-left text-sm">
          <thead className="border-b border-[var(--border)] text-xs text-[var(--text-muted)]">
            <tr>
              <th className="px-3 py-2 font-medium">User</th>
              <th className="px-3 py-2 font-medium">Plan</th>
              <th className="px-3 py-2 font-medium">Status</th>
              <th className="px-3 py-2 font-medium">IP / country</th>
              <th className="px-3 py-2 font-medium">Usage</th>
              <th className="px-3 py-2 font-medium">Last active</th>
              <th className="px-3 py-2 font-medium">Joined</th>
              <th className="px-3 py-2 font-medium">Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td colSpan={8} className="px-3 py-6 text-[var(--text-muted)]">
                  Loading…
                </td>
              </tr>
            )}
            {!loading && filtered.length === 0 && (
              <tr>
                <td colSpan={8} className="px-3 py-6 text-[var(--text-muted)]">
                  No accounts match this filter.
                </td>
              </tr>
            )}
            {filtered.map((r) => {
              const busy = busyId === r.id;
              return (
                <tr
                  key={r.id}
                  className="border-b border-[var(--border)]/60 last:border-0"
                >
                  <td className="px-3 py-2.5">
                    <div className="font-medium">{r.name || " - "}</div>
                    <div className="text-xs text-[var(--text-muted)]">
                      {r.email}
                    </div>
                    {r.isAdmin && (
                      <span className="mt-1 inline-block rounded-full border border-[var(--accent)]/40 bg-[var(--accent-soft)] px-2 py-0.5 text-[10px] font-medium text-[var(--accent-strong)]">
                        admin
                      </span>
                    )}
                  </td>
                  <td className="px-3 py-2.5 capitalize text-[var(--text-muted)]">
                    {r.plan}
                  </td>
                  <td className="px-3 py-2.5">
                    <StatusBadge
                      verified={r.verified}
                      disabled={r.disabled}
                      reason={r.disabledReason}
                    />
                  </td>
                  <td className="px-3 py-2.5 text-xs text-[var(--text-muted)]">
                    {r.lastIp ? (
                      <>
                        <div className="font-mono text-[11px]">{r.lastIp}</div>
                        <div className="text-[var(--text-dim)]">
                          {r.lastCountry ||
                            (r.lastCountryCode
                              ? r.lastCountryCode
                              : "Country unknown")}
                          {r.lastCountryCode && r.lastCountry
                            ? ` (${r.lastCountryCode})`
                            : ""}
                        </div>
                        {r.lastIpAt && (
                          <div className="text-[10px] text-[var(--text-dim)]">
                            seen {new Date(r.lastIpAt).toLocaleString()}
                          </div>
                        )}
                      </>
                    ) : (
                      <span className="text-[var(--text-dim)]"> - </span>
                    )}
                  </td>
                  <td className="px-3 py-2.5 text-xs text-[var(--text-muted)]">
                    <div>
                      {r.counts.providers} provider
                      {r.counts.providers === 1 ? "" : "s"} · {r.counts.apiKeys}{" "}
                      key{r.counts.apiKeys === 1 ? "" : "s"}
                    </div>
                    <div className="text-[var(--text-dim)]">
                      {r.counts.promptRequests} prompt
                      {r.counts.promptRequests === 1 ? "" : "s"} ·{" "}
                      {r.counts.desktopClients} desktop
                    </div>
                  </td>
                  <td className="px-3 py-2.5 text-xs text-[var(--text-muted)]">
                    {r.lastActiveAt ? (
                      <>
                        <div>{new Date(r.lastActiveAt).toLocaleString()}</div>
                        {r.lastDesktop?.hostname && (
                          <div className="text-[var(--text-dim)]">
                            {r.lastDesktop.hostname}
                            {r.lastDesktop.platform
                              ? ` · ${r.lastDesktop.platform}`
                              : ""}
                          </div>
                        )}
                      </>
                    ) : (
                      <span className="text-[var(--text-dim)]">Never</span>
                    )}
                  </td>
                  <td className="px-3 py-2.5 text-xs text-[var(--text-muted)]">
                    {new Date(r.createdAt).toLocaleString()}
                  </td>
                  <td className="px-3 py-2.5">
                    <div className="flex flex-col items-start gap-1">
                      {r.disabled ? (
                        <button
                          type="button"
                          disabled={busy}
                          className="text-xs text-emerald-300 hover:underline disabled:opacity-50"
                          onClick={() => void onEnable(r)}
                        >
                          Enable
                        </button>
                      ) : (
                        <button
                          type="button"
                          disabled={busy}
                          className="text-xs text-amber-300 hover:underline disabled:opacity-50"
                          onClick={() => void onDisable(r)}
                        >
                          Disable
                        </button>
                      )}
                      <button
                        type="button"
                        disabled={busy}
                        className="text-xs text-[var(--danger)] hover:underline disabled:opacity-50"
                        onClick={() => void onDelete(r)}
                      >
                        Delete
                      </button>
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <p className="text-xs text-[var(--text-dim)]">
        Showing {filtered.length} of {rows.length} accounts. IP/country updates
        on portal login and desktop API use. Disable ends sessions and blocks
        API keys; delete is permanent.
      </p>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: number }) {
  return (
    <div className="card px-4 py-3">
      <div className="text-xs text-[var(--text-muted)]">{label}</div>
      <div className="mt-0.5 text-2xl font-semibold tracking-tight">{value}</div>
    </div>
  );
}

function StatusBadge({
  verified,
  disabled,
  reason,
}: {
  verified: boolean;
  disabled: boolean;
  reason: string | null;
}) {
  if (disabled) {
    return (
      <div>
        <span className="inline-block rounded-full border border-red-500/40 px-2 py-0.5 text-[11px] text-red-300">
          Disabled
        </span>
        {reason && (
          <div className="mt-1 max-w-[10rem] truncate text-[10px] text-[var(--text-dim)]">
            {reason}
          </div>
        )}
      </div>
    );
  }
  if (verified) {
    return (
      <span className="inline-block rounded-full border border-emerald-500/40 px-2 py-0.5 text-[11px] text-emerald-300">
        Active
      </span>
    );
  }
  return (
    <span className="inline-block rounded-full border border-amber-500/40 px-2 py-0.5 text-[11px] text-amber-300">
      Unverified
    </span>
  );
}
