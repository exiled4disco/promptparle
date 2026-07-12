"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";

type Invite = {
  id: string;
  email: string;
  status: string;
  expiresAt: string;
  createdAt: string;
  acceptedAt: string | null;
  acceptedUser: { email: string; name: string | null } | null;
};

export function InviteFriends() {
  const [rows, setRows] = useState<Invite[]>([]);
  const [email, setEmail] = useState("");
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [sending, setSending] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await fetch("/api/invite", { cache: "no-store" });
      const data = await res.json();
      if (res.ok) setRows(data.invitations || []);
    } catch {
      /* non-fatal: list just stays empty */
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setNotice(null);
    setSending(true);
    try {
      const res = await fetch("/api/invite", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email, note: note || null }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Could not send invitation");
        return;
      }
      setNotice(data.message || `Invitation sent to ${email}`);
      setEmail("");
      setNote("");
      void load();
    } catch {
      setError("Network error. Try again.");
    } finally {
      setSending(false);
    }
  }

  return (
    <div className="grid gap-5">
      <form onSubmit={onSubmit} className="card grid gap-3 p-5">
        {error && <div className="alert alert-error">{error}</div>}
        {notice && <div className="alert alert-success">{notice}</div>}
        <div className="field">
          <label className="label" htmlFor="inviteEmail">
            Friend&apos;s email
          </label>
          <input
            id="inviteEmail"
            className="input"
            type="email"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="friend@example.com"
          />
        </div>
        <div className="field">
          <label className="label" htmlFor="inviteNote">
            Optional note
          </label>
          <input
            id="inviteNote"
            className="input"
            type="text"
            maxLength={500}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="Thought you'd like this — it trims your prompts."
          />
        </div>
        <button className="btn btn-primary w-fit" disabled={sending}>
          {sending ? "Sending…" : "Send invitation"}
        </button>
        <p className="text-xs text-[var(--text-dim)]">
          They&apos;ll get an email with a link to create a free account. The
          invite link is emailed directly — it isn&apos;t shown here.
        </p>
      </form>

      <div className="grid gap-2">
        <h2 className="text-sm font-semibold text-[var(--text-muted)]">
          Invitations you&apos;ve sent
        </h2>
        {loading ? (
          <p className="text-sm text-[var(--text-dim)]">Loading…</p>
        ) : rows.length === 0 ? (
          <p className="text-sm text-[var(--text-dim)]">
            None yet. Invite someone above.
          </p>
        ) : (
          <div className="grid gap-2">
            {rows.map((r) => (
              <div
                key={r.id}
                className="flex items-center justify-between gap-3 rounded-lg border border-[var(--border)] bg-[var(--card)] px-4 py-2.5 text-sm"
              >
                <div className="min-w-0">
                  <div className="truncate font-medium">{r.email}</div>
                  <div className="text-xs text-[var(--text-dim)]">
                    Sent {new Date(r.createdAt).toLocaleDateString()}
                    {r.acceptedUser ? " · joined" : ""}
                  </div>
                </div>
                <span
                  className={
                    "shrink-0 rounded-full px-2.5 py-0.5 text-xs font-medium " +
                    (r.status === "accepted" || r.status === "redeemed"
                      ? "bg-[rgba(16,185,129,0.15)] text-[#34d399]"
                      : r.status === "revoked"
                        ? "bg-[rgba(248,113,113,0.12)] text-[#fca5a5]"
                        : "bg-[rgba(148,163,184,0.12)] text-[var(--text-muted)]")
                  }
                >
                  {r.status}
                </span>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
