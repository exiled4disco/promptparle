"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";
import Link from "next/link";

export function LoginForm() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [unverifiedEmail, setUnverifiedEmail] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setUnverifiedEmail(null);
    setLoading(true);
    try {
      const res = await fetch("/api/auth/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email, password }),
      });
      const data = await res.json();
      if (!res.ok) {
        if (data.code === "email_unverified") {
          setUnverifiedEmail(data.email || email);
          setError(data.error);
          return;
        }
        setError(data.error || "Login failed");
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
      {unverifiedEmail && (
        <div className="alert alert-info">
          Need a new link?{" "}
          <Link
            href={`/verify-email?email=${encodeURIComponent(unverifiedEmail)}`}
            className="underline"
          >
            Resend verification email
          </Link>
        </div>
      )}
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
      <div className="field">
        <div className="mb-1 flex items-center justify-between gap-2">
          <label className="label !mb-0" htmlFor="password">
            Password
          </label>
          <Link
            href="/forgot-password"
            className="text-xs text-[#93b4ff] hover:underline"
          >
            Forgot password?
          </Link>
        </div>
        <input
          id="password"
          className="input"
          type="password"
          autoComplete="current-password"
          required
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          placeholder="••••••••"
        />
      </div>
      <button className="btn btn-primary mt-1 w-full" disabled={loading}>
        {loading ? "Signing in…" : "Sign in"}
      </button>
    </form>
  );
}
