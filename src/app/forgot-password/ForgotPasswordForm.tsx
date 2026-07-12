"use client";

import { FormEvent, useState } from "react";

export function ForgotPasswordForm() {
  const [email, setEmail] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  const [loading, setLoading] = useState(false);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      const res = await fetch("/api/auth/password/forgot", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email }),
      });
      const data = await res.json();
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
      <div className="alert alert-info">
        If an account exists for <strong>{email}</strong>, we sent a reset link.
        Check your inbox and spam folder. The link expires in 1 hour.
      </div>
    );
  }

  return (
    <form onSubmit={onSubmit} className="grid gap-4">
      {error && <div className="alert alert-error">{error}</div>}
      <div className="field">
        <label className="label" htmlFor="email">
          Email
        </label>
        <input
          id="email"
          className="input"
          type="email"
          autoComplete="email"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="you@company.com"
        />
      </div>
      <button className="btn btn-primary mt-1 w-full" disabled={loading}>
        {loading ? "Sending…" : "Send reset link"}
      </button>
    </form>
  );
}
