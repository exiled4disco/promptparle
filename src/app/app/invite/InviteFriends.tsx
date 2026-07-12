"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";

type Invite = {
  id: string;
  email: string;
  status: string;
  message: string | null;
  createdAt: string;
  acceptedAt: string | null;
  acceptedUser: { email: string; name: string | null } | null;
};

export function InviteFriends() {
  const [rows, setRows] = useState<Invite[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);

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
    let cancelled = false;
    (async () => {
      try {
        const res = await fetch("/api/invite", { cache: "no-store" });
        const data = await res.json();
        if (!cancelled && res.ok) setRows(data.invitations || []);
      } catch {
        /* non-fatal */
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <div className="grid gap-4">
      <div className="flex items-center justify-between gap-3">
        <p className="text-sm text-[var(--text-muted)]">
          PromptParle is free — invite someone and they&apos;ll get an email with
          a link to create their account.
        </p>
        <button
          type="button"
          className="btn btn-primary shrink-0"
          onClick={() => setOpen(true)}
        >
          Invite someone
        </button>
      </div>

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
                className="rounded-lg border border-[var(--border)] bg-[var(--card)] px-4 py-3 text-sm"
              >
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="truncate font-medium">{r.email}</div>
                    <div className="text-xs text-[var(--text-dim)]">
                      Sent {new Date(r.createdAt).toLocaleDateString()}
                      {r.acceptedUser ? " · joined ✓" : ""}
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
                {r.message ? (
                  <p className="mt-2 border-l-2 border-[var(--border)] pl-3 text-xs italic text-[var(--text-muted)]">
                    “{r.message}”
                  </p>
                ) : null}
              </div>
            ))}
          </div>
        )}
      </div>

      {open && (
        <InviteModal
          onClose={() => setOpen(false)}
          onSent={() => {
            setOpen(false);
            void load();
          }}
        />
      )}
    </div>
  );
}

/** Reusable invite modal: email + personal message → POST /api/invite. */
export function InviteModal({
  onClose,
  onSent,
}: {
  onClose: () => void;
  onSent: () => void;
}) {
  const [email, setEmail] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [sending, setSending] = useState(false);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSending(true);
    try {
      const res = await fetch("/api/invite", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email, note: message || null }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Could not send invitation");
        return;
      }
      onSent();
    } catch {
      setError("Network error. Try again.");
    } finally {
      setSending(false);
    }
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/55 p-4"
      role="dialog"
      aria-modal="true"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="w-full max-w-md rounded-2xl border border-[var(--border)] bg-[var(--card)] p-6 shadow-2xl">
        <div className="mb-4 flex items-center justify-between">
          <h2 className="text-lg font-semibold">Invite someone</h2>
          <button
            type="button"
            className="text-[var(--text-dim)] hover:text-[var(--text)]"
            onClick={onClose}
            aria-label="Close"
          >
            ✕
          </button>
        </div>
        <form onSubmit={onSubmit} className="grid gap-4">
          {error && <div className="alert alert-error">{error}</div>}
          <div className="field !mb-0">
            <label className="label !mb-1 text-xs" htmlFor="inviteEmail">
              Their email
            </label>
            <input
              id="inviteEmail"
              className="input"
              type="email"
              required
              autoFocus
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="friend@example.com"
            />
          </div>
          <div className="field !mb-0">
            <label className="label !mb-1 text-xs" htmlFor="inviteMessage">
              Message <span className="text-[var(--text-dim)]">(optional)</span>
            </label>
            <textarea
              id="inviteMessage"
              className="input"
              rows={3}
              maxLength={500}
              value={message}
              onChange={(e) => setMessage(e.target.value)}
              placeholder="Thought you'd like this — it trims your prompts and cuts token cost."
            />
          </div>
          <div className="flex items-center justify-end gap-2">
            <button
              type="button"
              className="btn btn-secondary"
              onClick={onClose}
            >
              Cancel
            </button>
            <button className="btn btn-primary" disabled={sending}>
              {sending ? "Sending…" : "Send invite"}
            </button>
          </div>
          <p className="text-xs text-[var(--text-dim)]">
            They get an email from you with a link to create a free account. No
            code needed — signup is open.
          </p>
        </form>
      </div>
    </div>
  );
}
