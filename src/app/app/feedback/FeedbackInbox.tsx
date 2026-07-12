"use client";

import { Fragment, useCallback, useEffect, useState } from "react";

type Row = {
  id: string;
  kind: string;
  title: string;
  body: string;
  source: string;
  email: string | null;
  name: string | null;
  ip: string | null;
  country: string | null;
  status: string;
  adminNote: string | null;
  createdAt: string;
  user: { id: string; email: string; name: string | null } | null;
};

export function FeedbackInbox() {
  const [rows, setRows] = useState<Row[]>([]);
  const [filter, setFilter] = useState("all");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [openId, setOpenId] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const q =
        filter === "all" ? "" : `?status=${encodeURIComponent(filter)}`;
      const res = await fetch(`/api/admin/feedback${q}`, { cache: "no-store" });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Failed to load");
        return;
      }
      setRows(data.feedback || []);
    } catch {
      setError("Network error");
    } finally {
      setLoading(false);
    }
  }, [filter]);

  useEffect(() => {
    void load();
  }, [load]);

  async function setStatus(id: string, status: string) {
    const res = await fetch(`/api/admin/feedback/${id}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ status }),
    });
    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      setError(data.error || "Update failed");
      return;
    }
    await load();
  }

  async function onDelete(id: string) {
    if (!confirm("Delete this feedback item?")) return;
    const res = await fetch(`/api/admin/feedback/${id}`, { method: "DELETE" });
    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      setError(data.error || "Delete failed");
      return;
    }
    await load();
  }

  return (
    <div className="grid gap-3">
      <div className="flex flex-wrap gap-1">
        {(
          [
            ["all", "All"],
            ["new", "New"],
            ["read", "Read"],
            ["closed", "Closed"],
          ] as const
        ).map(([id, label]) => (
          <button
            key={id}
            type="button"
            onClick={() => setFilter(id)}
            className={
              filter === id
                ? "rounded-lg border border-[var(--accent)] bg-[var(--accent-soft)] px-3 py-1.5 text-xs font-medium text-[var(--accent-strong)]"
                : "rounded-lg border border-[var(--border)] px-3 py-1.5 text-xs text-[var(--text-muted)]"
            }
          >
            {label}
          </button>
        ))}
        <button
          type="button"
          className="btn btn-secondary !py-1.5 !text-xs"
          onClick={() => void load()}
        >
          Refresh
        </button>
      </div>

      {error && (
        <div className="rounded-lg border border-[var(--danger)]/40 px-3 py-2 text-sm text-[var(--danger)]">
          {error}
        </div>
      )}

      <div className="card overflow-x-auto p-0">
        <table className="w-full min-w-[800px] text-left text-sm">
          <thead className="border-b border-[var(--border)] text-xs text-[var(--text-muted)]">
            <tr>
              <th className="px-3 py-2 font-medium">When</th>
              <th className="px-3 py-2 font-medium">Type</th>
              <th className="px-3 py-2 font-medium">Title</th>
              <th className="px-3 py-2 font-medium">From</th>
              <th className="px-3 py-2 font-medium">Source</th>
              <th className="px-3 py-2 font-medium">Status</th>
              <th className="px-3 py-2 font-medium" />
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr>
                <td colSpan={7} className="px-3 py-6 text-[var(--text-muted)]">
                  Loading…
                </td>
              </tr>
            )}
            {!loading && rows.length === 0 && (
              <tr>
                <td colSpan={7} className="px-3 py-6 text-[var(--text-muted)]">
                  No feedback yet.
                </td>
              </tr>
            )}
            {rows.map((r) => (
              <Fragment key={r.id}>
                <tr
                  className="border-b border-[var(--border)]/60 cursor-pointer hover:bg-white/[0.02]"
                  onClick={() => setOpenId(openId === r.id ? null : r.id)}
                >
                  <td className="px-3 py-2 text-xs text-[var(--text-muted)]">
                    {new Date(r.createdAt).toLocaleString()}
                  </td>
                  <td className="px-3 py-2">
                    <span
                      className={
                        r.kind === "bug"
                          ? "rounded-full border border-red-500/40 px-2 py-0.5 text-[11px] text-red-300"
                          : "rounded-full border border-sky-500/40 px-2 py-0.5 text-[11px] text-sky-300"
                      }
                    >
                      {r.kind}
                    </span>
                  </td>
                  <td className="px-3 py-2 font-medium">{r.title}</td>
                  <td className="px-3 py-2 text-xs text-[var(--text-muted)]">
                    {r.user?.email || r.email || " - "}
                    {r.country && (
                      <div className="text-[var(--text-dim)]">{r.country}</div>
                    )}
                  </td>
                  <td className="px-3 py-2 text-xs capitalize text-[var(--text-muted)]">
                    {r.source}
                  </td>
                  <td className="px-3 py-2 text-xs capitalize">{r.status}</td>
                  <td className="px-3 py-2 text-right text-xs text-[var(--text-dim)]">
                    {openId === r.id ? "▾" : "▸"}
                  </td>
                </tr>
                {openId === r.id && (
                  <tr className="border-b border-[var(--border)]/60">
                    <td colSpan={7} className="bg-[var(--bg-soft)] px-4 py-3">
                      <p className="whitespace-pre-wrap text-sm text-[var(--text)]">
                        {r.body}
                      </p>
                      <div className="mt-2 text-xs text-[var(--text-dim)]">
                        IP {r.ip || " - "}
                        {r.name ? ` · ${r.name}` : ""}
                      </div>
                      <div className="mt-3 flex flex-wrap gap-2">
                        {r.status !== "read" && (
                          <button
                            type="button"
                            className="btn btn-secondary !py-1 !text-xs"
                            onClick={(e) => {
                              e.stopPropagation();
                              void setStatus(r.id, "read");
                            }}
                          >
                            Mark read
                          </button>
                        )}
                        {r.status !== "closed" && (
                          <button
                            type="button"
                            className="btn btn-secondary !py-1 !text-xs"
                            onClick={(e) => {
                              e.stopPropagation();
                              void setStatus(r.id, "closed");
                            }}
                          >
                            Close
                          </button>
                        )}
                        {r.status !== "new" && (
                          <button
                            type="button"
                            className="btn btn-secondary !py-1 !text-xs"
                            onClick={(e) => {
                              e.stopPropagation();
                              void setStatus(r.id, "new");
                            }}
                          >
                            Reopen
                          </button>
                        )}
                        <button
                          type="button"
                          className="text-xs text-[var(--danger)] hover:underline"
                          onClick={(e) => {
                            e.stopPropagation();
                            void onDelete(r.id);
                          }}
                        >
                          Delete
                        </button>
                      </div>
                    </td>
                  </tr>
                )}
              </Fragment>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
