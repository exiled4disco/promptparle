"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";

type LookupOk = {
  email: string;
  email_masked: string;
  code: string;
};

/**
 * Step 1: invitation code (required).
 * Step 2: name + password for the invited email.
 */
export function RegisterInviteForm({
  initialCode = "",
}: {
  initialCode?: string;
}) {
  const router = useRouter();
  const [step, setStep] = useState<"code" | "account">("code");
  const [code, setCode] = useState(initialCode);
  const [lookup, setLookup] = useState<LookupOk | null>(null);
  const [name, setName] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const validateCode = useCallback(async (raw: string) => {
    setError(null);
    setLoading(true);
    try {
      const res = await fetch("/api/auth/invite/code-lookup", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code: raw.trim() }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Invalid invitation code");
        setLookup(null);
        setStep("code");
        return;
      }
      setLookup({
        email: data.email,
        email_masked: data.email_masked,
        code: data.code,
      });
      setCode(data.code);
      setStep("account");
    } catch {
      setError("Network error. Try again.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (initialCode && initialCode.length >= 6) {
      void validateCode(initialCode);
    }
  }, [initialCode, validateCode]);

  async function onValidateCode(e: FormEvent) {
    e.preventDefault();
    await validateCode(code);
  }

  async function onCreateAccount(e: FormEvent) {
    e.preventDefault();
    setError(null);
    if (!lookup) {
      setError("Enter your invitation code first");
      setStep("code");
      return;
    }
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
          code: lookup.code,
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
        `/app?welcome=1&code=${encodeURIComponent(data.code || lookup.code)}`
      );
      router.refresh();
    } catch {
      setError("Network error. Try again.");
    } finally {
      setLoading(false);
    }
  }

  if (step === "code" || !lookup) {
    return (
      <form onSubmit={onValidateCode} className="grid gap-4">
        {error && <div className="alert alert-error">{error}</div>}
        <div className="field">
          <label className="label" htmlFor="inviteCode">
            Invitation code
          </label>
          <input
            id="inviteCode"
            className="input mono tracking-wider uppercase"
            type="text"
            required
            autoComplete="off"
            spellCheck={false}
            value={code}
            onChange={(e) => setCode(e.target.value.toUpperCase())}
            placeholder="PP-XXXX-XXXX"
          />
          <p className="mt-1.5 text-xs text-[var(--text-dim)]">
            From your invitation email. Accounts cannot be created without a
            valid code.
          </p>
        </div>
        <button className="btn btn-primary w-full" disabled={loading}>
          {loading ? "Checking…" : "Continue"}
        </button>
        <p className="text-center text-sm text-[var(--text-muted)]">
          Already have an account?{" "}
          <Link href="/login" className="text-[#93b4ff] hover:underline">
            Sign in
          </Link>
        </p>
      </form>
    );
  }

  return (
    <form onSubmit={onCreateAccount} className="grid gap-4">
      {error && <div className="alert alert-error">{error}</div>}
      <div className="rounded-lg border border-[var(--border)] bg-[var(--bg-soft)] px-3 py-2 text-sm">
        <div className="text-xs text-[var(--text-dim)]">Invitation code</div>
        <div className="mono font-semibold tracking-wider text-[#93b4ff]">
          {lookup.code}
        </div>
        <div className="mt-1 text-xs text-[var(--text-muted)]">
          Account email: <strong className="text-[var(--text)]">{lookup.email}</strong>
        </div>
        <button
          type="button"
          className="mt-2 text-xs text-[#93b4ff] hover:underline"
          onClick={() => {
            setStep("code");
            setLookup(null);
            setError(null);
          }}
        >
          Use a different code
        </button>
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
      <button className="btn btn-primary w-full" disabled={loading}>
        {loading ? "Creating account…" : "Create account"}
      </button>
      <p className="text-xs leading-relaxed text-[var(--text-dim)]">
        Next you&apos;ll get an email with desktop install steps. Use the same
        invitation code in the installer, then paste your{" "}
        <span className="mono">pp_live_…</span> key.
      </p>
    </form>
  );
}
