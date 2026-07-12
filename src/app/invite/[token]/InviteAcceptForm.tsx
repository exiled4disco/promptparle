"use client";

import { FormEvent, useState } from "react";
import { useRouter } from "next/navigation";

export function InviteAcceptForm({
  token,
  email,
  emailMasked,
}: {
  token: string;
  email: string;
  emailMasked: string;
}) {
  const router = useRouter();
  const [name, setName] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    if (password !== confirm) {
      setError("Passwords do not match");
      return;
    }
    setLoading(true);
    try {
      const res = await fetch("/api/auth/invite/accept", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          token,
          name: name.trim() || null,
          password,
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Could not create account");
        return;
      }
      router.push(
        `/app?welcome=1&code=${encodeURIComponent(data.code || "")}`
      );
      router.refresh();
    } catch {
      setError("Network error. Try again.");
    } finally {
      setLoading(false);
    }
  }

  return (
    <form onSubmit={onSubmit} className="grid gap-4">
      {error && <div className="alert alert-error">{error}</div>}
      <div className="field">
        <label className="label">Email (from invitation)</label>
        <input
          className="input"
          type="email"
          value={email}
          readOnly
          disabled
          title={emailMasked}
        />
      </div>
      <div className="field">
        <label className="label" htmlFor="name">
          Name <span className="dim">(optional)</span>
        </label>
        <input
          id="name"
          className="input"
          type="text"
          autoComplete="name"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="How we should greet you"
        />
      </div>
      <div className="field">
        <label className="label" htmlFor="password">
          Password
        </label>
        <input
          id="password"
          className="input"
          type="password"
          autoComplete="new-password"
          required
          minLength={8}
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          placeholder="At least 8 characters"
        />
      </div>
      <div className="field">
        <label className="label" htmlFor="confirm">
          Confirm password
        </label>
        <input
          id="confirm"
          className="input"
          type="password"
          autoComplete="new-password"
          required
          minLength={8}
          value={confirm}
          onChange={(e) => setConfirm(e.target.value)}
        />
      </div>
      <button className="btn btn-primary mt-1 w-full" disabled={loading}>
        {loading ? "Creating account…" : "Create account"}
      </button>
      <p className="text-xs leading-relaxed text-[var(--text-dim)]">
        After this, check your email for your invitation code and desktop install
        instructions. Then open Providers and API Keys in the portal.
      </p>
    </form>
  );
}
