"use client";

import { FormEvent, useState } from "react";
import { useRouter } from "next/navigation";

export function ResetPasswordForm({ token }: { token: string }) {
  const router = useRouter();
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
    if (password.length < 8) {
      setError("Password must be at least 8 characters");
      return;
    }
    setLoading(true);
    try {
      const res = await fetch("/api/auth/password/reset", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token, password }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Reset failed");
        return;
      }
      router.push("/app");
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
        <label className="label" htmlFor="password">
          New password
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
          placeholder="Same password again"
        />
      </div>
      <button className="btn btn-primary mt-1 w-full" disabled={loading}>
        {loading ? "Saving…" : "Set new password"}
      </button>
    </form>
  );
}
