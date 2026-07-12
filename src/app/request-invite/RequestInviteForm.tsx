"use client";

import { FormEvent, useState } from "react";

export function RequestInviteForm() {
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [company, setCompany] = useState("");
  const [note, setNote] = useState("");
  const [website, setWebsite] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  const [loading, setLoading] = useState(false);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      const res = await fetch("/api/auth/invite/request", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name,
          email,
          company: company || null,
          note: note || null,
          website: website || null,
        }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        setError(data.error || "Request failed");
        return;
      }
      setDone(true);
    } catch {
      setError("Network error. Try again.");
    } finally {
      setLoading(false);
    }
  }

  if (done) {
    return (
      <div className="alert alert-success">
        Thanks. We received your request for <strong>{email}</strong>. If
        approved, you will get a one-time invitation code by email.
      </div>
    );
  }

  return (
    <form onSubmit={onSubmit} className="relative grid gap-4">
      {error && <div className="alert alert-error">{error}</div>}
      <div className="field">
        <label className="label" htmlFor="name">
          Name
        </label>
        <input
          id="name"
          className="input"
          type="text"
          autoComplete="name"
          required
          maxLength={120}
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Your name"
        />
      </div>
      <div className="field">
        <label className="label" htmlFor="email">
          Work email
        </label>
        <input
          id="email"
          className="input"
          type="email"
          autoComplete="email"
          required
          maxLength={255}
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="you@company.com"
        />
      </div>
      <div className="field">
        <label className="label" htmlFor="company">
          Company <span className="text-[var(--text-dim)]">(optional)</span>
        </label>
        <input
          id="company"
          className="input"
          type="text"
          autoComplete="organization"
          maxLength={160}
          value={company}
          onChange={(e) => setCompany(e.target.value)}
          placeholder="Organization"
        />
      </div>
      <div className="field">
        <label className="label" htmlFor="note">
          Why PromptParle?{" "}
          <span className="text-[var(--text-dim)]">(optional)</span>
        </label>
        <textarea
          id="note"
          className="input min-h-[5.5rem] resize-y"
          maxLength={1000}
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="What you want to use it for"
        />
      </div>
      {/* Honeypot */}
      <div className="absolute -left-[9999px] h-0 w-0 overflow-hidden" aria-hidden>
        <label htmlFor="website">Website</label>
        <input
          id="website"
          type="text"
          tabIndex={-1}
          autoComplete="off"
          value={website}
          onChange={(e) => setWebsite(e.target.value)}
        />
      </div>
      <button className="btn btn-primary mt-1 w-full" disabled={loading}>
        {loading ? "Sending…" : "Request invitation"}
      </button>
    </form>
  );
}
