"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";

type Invite = {
  id: string;
  email: string;
  code: string;
  status: string;
  note: string | null;
  expiresAt: string;
  createdAt: string;
  acceptedAt: string | null;
  redeemedAt: string | null;
  invitedBy: string;
  acceptedUser: { id: string; email: string; name: string | null } | null;
};

export function InvitationsClient() {
  const [rows, setRows] = useState<Invite[]>([]);
  const [email, setEmail] = useState("");
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [lastUrl, setLastUrl] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [listLoading, setListLoading] = useState(true);

  const load = useCallback(async () => {
    setListLoading(true);
    try {
      const res = await fetch("/api/admin/invitations", { cache: "no-store" });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Failed to load");
        return;
      }
      setRows(data.invitations || []);
    } catch {
      setError("Network error loading invitations");
    } finally {
      setListLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function onCreate(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSuccess(null);
    setLastUrl(null);
    setLoading(true);
    try {
      const res = await fetch("/api/admin/invitations", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email, note: note || null }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Could not send invitation");
        return;
      }
      setSuccess(data.message || "Invitation sent");
      setLastUrl(data.inviteUrl || null);
      setEmail("");
      setNote("");
      await load();
    } catch {
      setError("Network error");
    } finally {
      setLoading(false);
    }
  }

  async function onRevoke(id: string) {
    if (!confirm("Revoke this invitation?")) return;
    setError(null);
    try {
      const res = await fetch(`/api/admin/invitations/${id}`, {
        method: "DELETE",
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Revoke failed");
        return;
      }
      await load();
    } catch {
      setError("Network error");
    }
  }

  return (
    <div className="grid gap-4">
      <form
        onSubmit={onCreate}
        className="card grid gap-3 p-4 sm:grid-cols-[1fr_1fr_auto] sm:items-end"
      >
        <div className="field !mb-0">
          <label className="label" htmlFor="inviteEmail">
            Customer email
          </label>
          <input
            id="inviteEmail"
            className="input"
            type="email"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="customer@company.com"
          />
        </div>
        <div className="field !mb-0">
          <label className="label" htmlFor="inviteNote">
            Note <span className="dim">(optional)</span>
          </label>
          <input
            id="inviteNote"
            className="input"
            type="text"
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="Acme Corp pilot"
          />
        </div>
        <button
          type="submit"
          className="btn btn-primary !px-4 !py-2 text-sm"
          disabled={loading}
        >
          {loading ? "Sending…" : "Send invitation"}
        </button>
      </form>

      {error && <div className="alert alert-error">{error}</div>}
      {success && (
        <div className="alert alert-info">
          {success}
          {lastUrl && (
            <div className="mt-2 break-all text-xs">
              Link (also emailed):{" "}
              <code className="text-[var(--text)]">{lastUrl}</code>
            </div>
          )}
        </div>
      )}

      <div className="card overflow-x-auto p-0">
        <table className="w-full min-w-[720px] text-left text-sm">
          <thead className="border-b border-[var(--border)] text-xs text-[var(--text-muted)]">
            <tr>
              <th className="px-3 py-2 font-medium">Email</th>
              <th className="px-3 py-2 font-medium">Code</th>
              <th className="px-3 py-2 font-medium">Status</th>
              <th className="px-3 py-2 font-medium">Created</th>
              <th className="px-3 py-2 font-medium">Note</th>
              <th className="px-3 py-2 font-medium" />
            </tr>
          </thead>
          <tbody>
            {listLoading && (
              <tr>
                <td colSpan={6} className="px-3 py-6 text-[var(--text-muted)]">
                  Loading…
                </td>
              </tr>
            )}
            {!listLoading && rows.length === 0 && (
              <tr>
                <td colSpan={6} className="px-3 py-6 text-[var(--text-muted)]">
                  No invitations yet. Enter a customer email above.
                </td>
              </tr>
            )}
            {rows.map((r) => (
              <tr
                key={r.id}
                className="border-b border-[var(--border)]/60 last:border-0"
              >
                <td className="px-3 py-2">
                  <div className="font-medium">{r.email}</div>
                  {r.acceptedUser && (
                    <div className="text-xs text-[var(--text-dim)]">
                      user: {r.acceptedUser.name || r.acceptedUser.email}
                    </div>
                  )}
                </td>
                <td className="px-3 py-2 font-mono text-xs tracking-wide">
                  {r.code}
                </td>
                <td className="px-3 py-2">
                  <StatusBadge status={r.status} />
                </td>
                <td className="px-3 py-2 text-xs text-[var(--text-muted)]">
                  {new Date(r.createdAt).toLocaleString()}
                </td>
                <td className="px-3 py-2 text-xs text-[var(--text-muted)]">
                  {r.note || "-"}
                </td>
                <td className="px-3 py-2 text-right">
                  {(r.status === "pending" || r.status === "accepted") && (
                    <button
                      type="button"
                      className="text-xs text-[var(--danger)] hover:underline"
                      onClick={() => void onRevoke(r.id)}
                    >
                      Revoke
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="rounded-lg border border-[var(--border)] px-3 py-2.5 text-xs leading-relaxed text-[var(--text-muted)]">
        <strong className="text-[var(--text)]">Customer flow:</strong> email
        with invitation code + link →{" "}
        <code className="text-[10px]">/register</code> (code first) or accept
        link → set password → portal Providers + API Keys →{" "}
        <code className="text-[10px]">irm https://promptparle.com/install.ps1 | iex</code>{" "}
        → same code → paste <code className="text-[10px]">pp_live_…</code>.
      </div>
    </div>
  );
}

function StatusBadge({ status }: { status: string }) {
  const colors: Record<string, string> = {
    pending: "border-amber-500/40 text-amber-300",
    accepted: "border-sky-500/40 text-sky-300",
    redeemed: "border-emerald-500/40 text-emerald-300",
    revoked: "border-red-500/40 text-red-300",
  };
  const c = colors[status] || "border-[var(--border)] text-[var(--text-muted)]";
  return (
    <span
      className={`inline-block rounded-full border px-2 py-0.5 text-[11px] capitalize ${c}`}
    >
      {status}
    </span>
  );
}
