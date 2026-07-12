"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";

type Row = {
  id: string;
  kind: string;
  title: string;
  body: string;
  status: string;
  adminNote: string | null;
  createdAt: string;
};

const STATUS_LABEL: Record<string, string> = {
  new: "New",
  open: "Open",
  triaged: "Triaged",
  "in-progress": "In progress",
  resolved: "Resolved",
  closed: "Closed",
  wontfix: "Won't fix",
};

function statusClass(status: string) {
  switch (status) {
    case "resolved":
    case "closed":
      return "border-emerald-400/40 text-emerald-300";
    case "in-progress":
    case "triaged":
      return "border-[var(--accent)]/50 text-[var(--accent-strong)]";
    case "wontfix":
      return "border-[var(--border-strong)] text-[var(--text-dim)]";
    default:
      return "border-[var(--border-strong)] text-[var(--text-muted)]";
  }
}

export function BugTracker() {
  const [rows, setRows] = useState<Row[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [kind, setKind] = useState<"bug" | "suggest">("bug");
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [website, setWebsite] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await fetch("/api/feedback", { cache: "no-store" });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        setError(data.error || "Failed to load your submissions.");
        return;
      }
      setRows(data.feedback || []);
    } catch {
      setError("Network error.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const res = await fetch("/api/feedback", { cache: "no-store" }).catch(
        () => null
      );
      if (cancelled) return;
      if (!res) {
        setError("Network error.");
        setLoading(false);
        return;
      }
      const data = await res.json().catch(() => ({}));
      if (cancelled) return;
      if (!res.ok) {
        setError(data.error || "Failed to load your submissions.");
      } else {
        setRows(data.feedback || []);
      }
      setLoading(false);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setSubmitting(true);
    setSubmitError(null);
    setDone(false);
    try {
      const res = await fetch("/api/feedback", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ kind, title, body, website }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        setSubmitError(data.error || "Could not submit.");
        return;
      }
      setDone(true);
      setTitle("");
      setBody("");
      await load();
    } catch {
      setSubmitError("Network error.");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="grid gap-6">
      <section className="card grid gap-3 p-5">
        <div>
          <h2 className="text-lg font-semibold">Submit a report</h2>
          <p className="mt-0.5 text-sm text-[var(--text-muted)]">
            Tell us what broke or what would help. It goes to the maintainers and
            appears in your list below.
          </p>
        </div>
        <form className="grid gap-3" onSubmit={onSubmit}>
          {/* Honeypot */}
          <input
            type="text"
            name="website"
            value={website}
            onChange={(e) => setWebsite(e.target.value)}
            className="hidden"
            tabIndex={-1}
            autoComplete="off"
            aria-hidden
          />
          <div className="flex gap-2">
            {(["bug", "suggest"] as const).map((k) => (
              <button
                key={k}
                type="button"
                onClick={() => setKind(k)}
                className={`btn ${kind === k ? "btn-primary" : "btn-ghost"} px-4 py-2 text-sm`}
                aria-pressed={kind === k}
              >
                {k === "bug" ? "Bug" : "Suggestion"}
              </button>
            ))}
          </div>
          <label className="grid gap-1 text-sm">
            <span className="text-[var(--text-dim)]">Title</span>
            <input
              type="text"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              minLength={3}
              maxLength={200}
              required
              className="input"
              placeholder="Short summary"
            />
          </label>
          <label className="grid gap-1 text-sm">
            <span className="text-[var(--text-dim)]">Details</span>
            <textarea
              value={body}
              onChange={(e) => setBody(e.target.value)}
              minLength={10}
              maxLength={8000}
              required
              rows={5}
              className="input"
              placeholder="What happened, and what did you expect?"
            />
          </label>
          {submitError ? (
            <p className="text-sm text-red-400">{submitError}</p>
          ) : null}
          {done ? (
            <p className="text-sm text-emerald-300">
              Thanks. We received your report.
            </p>
          ) : null}
          <div>
            <button
              type="submit"
              disabled={submitting}
              className="btn btn-primary px-5 py-2.5 text-sm disabled:opacity-60"
            >
              {submitting ? "Sending…" : "Submit"}
            </button>
          </div>
        </form>
      </section>

      <section className="grid gap-3">
        <h2 className="text-lg font-semibold">Your submissions</h2>
        {loading ? (
          <p className="text-sm text-[var(--text-muted)]">Loading…</p>
        ) : error ? (
          <p className="text-sm text-red-400">{error}</p>
        ) : rows.length === 0 ? (
          <p className="text-sm text-[var(--text-muted)]">
            You haven&apos;t submitted anything yet.
          </p>
        ) : (
          <ul className="grid gap-3">
            {rows.map((r) => (
              <li key={r.id} className="card grid gap-2 p-4">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="rounded-full border border-[var(--border-strong)] px-2 py-0.5 text-xs uppercase tracking-wide text-[var(--text-dim)]">
                    {r.kind === "bug" ? "Bug" : "Suggestion"}
                  </span>
                  <span
                    className={`rounded-full border px-2 py-0.5 text-xs ${statusClass(r.status)}`}
                  >
                    {STATUS_LABEL[r.status] || r.status}
                  </span>
                  <span className="ml-auto text-xs text-[var(--text-muted)]">
                    {new Date(r.createdAt).toLocaleDateString()}
                  </span>
                </div>
                <div className="font-medium">{r.title}</div>
                <p className="whitespace-pre-wrap text-sm text-[var(--text-muted)]">
                  {r.body}
                </p>
                {r.adminNote ? (
                  <p className="rounded-lg border border-[var(--accent)]/30 bg-[var(--accent-soft)] px-3 py-2 text-sm text-[var(--text)]">
                    <span className="font-semibold text-[var(--accent-strong)]">
                      Reply:{" "}
                    </span>
                    {r.adminNote}
                  </p>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
