"use client";

import { FormEvent, useState } from "react";

export function ContactForm() {
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [subject, setSubject] = useState("");
  const [message, setMessage] = useState("");
  const [website, setWebsite] = useState(""); // honeypot
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState(false);
  const [loading, setLoading] = useState(false);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      const res = await fetch("/api/contact", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name, email, subject, message, website }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Could not send your message.");
        return;
      }
      setSent(true);
    } catch {
      setError("Network error. Try again.");
    } finally {
      setLoading(false);
    }
  }

  if (sent) {
    return (
      <div className="alert alert-success">
        Thanks — your message was sent. We&apos;ll reply to{" "}
        <strong>{email}</strong>.
      </div>
    );
  }

  return (
    <form onSubmit={onSubmit} className="grid gap-4">
      {error && <div className="alert alert-error">{error}</div>}
      <div className="field">
        <label className="label" htmlFor="cName">
          Name
        </label>
        <input
          id="cName"
          className="input"
          type="text"
          required
          maxLength={120}
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Your name"
        />
      </div>
      <div className="field">
        <label className="label" htmlFor="cEmail">
          Email
        </label>
        <input
          id="cEmail"
          className="input"
          type="email"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="you@example.com"
        />
      </div>
      <div className="field">
        <label className="label" htmlFor="cSubject">
          Subject <span className="text-[var(--text-dim)]">(optional)</span>
        </label>
        <input
          id="cSubject"
          className="input"
          type="text"
          maxLength={200}
          value={subject}
          onChange={(e) => setSubject(e.target.value)}
          placeholder="What's this about?"
        />
      </div>
      <div className="field">
        <label className="label" htmlFor="cMessage">
          Message
        </label>
        <textarea
          id="cMessage"
          className="input"
          required
          minLength={10}
          maxLength={8000}
          rows={6}
          value={message}
          onChange={(e) => setMessage(e.target.value)}
          placeholder="How can we help?"
        />
      </div>
      {/* Honeypot: visually hidden, off-screen; real users leave it empty. */}
      <div aria-hidden className="absolute left-[-9999px] h-0 w-0 overflow-hidden">
        <label>
          Do not fill this
          <input
            tabIndex={-1}
            autoComplete="off"
            value={website}
            onChange={(e) => setWebsite(e.target.value)}
          />
        </label>
      </div>
      <button className="btn btn-primary mt-1 w-full" disabled={loading}>
        {loading ? "Sending…" : "Send message"}
      </button>
      <p className="text-xs leading-relaxed text-[var(--text-dim)]">
        We only use your email to reply. Prompts and provider keys stay on your
        PC — the portal never sees them.
      </p>
    </form>
  );
}
