"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useEffect, useState } from "react";

export function VerifyEmailClient({
  token,
  email: initialEmail,
  initialError,
  justSent,
  notice,
}: {
  token: string;
  email: string;
  initialError: string;
  justSent: boolean;
  notice: string;
}) {
  const router = useRouter();
  const [email, setEmail] = useState(initialEmail);
  const [status, setStatus] = useState<
    "idle" | "verifying" | "success" | "error" | "resending"
  >(token ? "verifying" : "idle");
  const [message, setMessage] = useState<string | null>(
    initialError ||
      (justSent
        ? "We sent a verification link to your inbox. Click it to continue."
        : notice === "exists"
          ? "That email is registered but not verified yet. Resend the link below."
          : null)
  );
  const [error, setError] = useState<string | null>(initialError || null);

  useEffect(() => {
    if (!token) return;
    let cancelled = false;

    async function verify() {
      try {
        const res = await fetch("/api/auth/verify-email", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ token }),
        });
        const data = await res.json();
        if (cancelled) return;
        if (!res.ok) {
          setStatus("error");
          setError(data.error || "Verification failed");
          return;
        }
        setStatus("success");
        setMessage("Email verified. Taking you to your dashboard…");
        setTimeout(() => {
          router.push("/app");
          router.refresh();
        }, 800);
      } catch {
        if (!cancelled) {
          setStatus("error");
          setError("Network error while verifying.");
        }
      }
    }

    verify();
    return () => {
      cancelled = true;
    };
  }, [token, router]);

  async function onResend(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setMessage(null);
    setStatus("resending");
    try {
      const res = await fetch("/api/auth/resend-verification", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email }),
      });
      const data = await res.json();
      if (!res.ok) {
        setStatus("error");
        setError(data.error || "Could not resend");
        return;
      }
      setStatus("idle");
      setMessage(
        data.message ||
          "If an unverified account exists for that email, a new link has been sent."
      );
    } catch {
      setStatus("error");
      setError("Network error");
    }
  }

  if (status === "verifying") {
    return (
      <div className="alert alert-info">
        Verifying your email…
      </div>
    );
  }

  if (status === "success") {
    return <div className="alert alert-success">{message}</div>;
  }

  return (
    <div className="grid gap-4">
      {error && <div className="alert alert-error">{error}</div>}
      {message && !error && <div className="alert alert-success">{message}</div>}

      <form onSubmit={onResend} className="grid gap-4">
        <div className="field">
          <label className="label" htmlFor="email">
            Email
          </label>
          <input
            id="email"
            className="input"
            type="email"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="you@company.com"
          />
        </div>
        <button
          className="btn btn-primary w-full"
          disabled={status === "resending" || !email}
        >
          {status === "resending" ? "Sending…" : "Resend verification email"}
        </button>
      </form>

      <p className="text-center text-sm text-[var(--text-muted)]">
        Already verified?{" "}
        <Link href="/login" className="text-[#93b4ff] hover:underline">
          Sign in
        </Link>
      </p>
    </div>
  );
}
