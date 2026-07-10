"use client";

import { FormEvent, useState } from "react";
import { useRouter } from "next/navigation";
import type { SessionUser } from "@/lib/auth";
import { RETENTION_OPTIONS } from "@/lib/constants";

export function SettingsForm({ user }: { user: SessionUser }) {
  const router = useRouter();
  const [name, setName] = useState(user.name || "");
  const [retentionPolicy, setRetentionPolicy] = useState(user.retentionPolicy);
  const [storePrompts, setStorePrompts] = useState(user.storePrompts);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSuccess(null);
    setLoading(true);
    try {
      const res = await fetch("/api/settings", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name,
          retentionPolicy,
          storePrompts: retentionPolicy === "none" ? false : storePrompts,
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Failed to save");
        return;
      }
      setSuccess("Settings saved.");
      router.refresh();
    } catch {
      setError("Network error");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="grid gap-6 lg:grid-cols-2">
      <form onSubmit={onSubmit} className="card grid gap-4 p-6">
        <h2 className="text-lg font-semibold">Profile</h2>
        {error && <div className="alert alert-error">{error}</div>}
        {success && <div className="alert alert-success">{success}</div>}

        <div className="field">
          <label className="label">Email</label>
          <input className="input" value={user.email} disabled />
        </div>

        <div className="field">
          <label className="label" htmlFor="name">
            Display name
          </label>
          <input
            id="name"
            className="input"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Your name"
          />
        </div>

        <div className="field">
          <label className="label" htmlFor="retention">
            Prompt retention
          </label>
          <select
            id="retention"
            className="select"
            value={retentionPolicy}
            onChange={(e) => setRetentionPolicy(e.target.value)}
          >
            {RETENTION_OPTIONS.map((opt) => (
              <option key={opt.id} value={opt.id}>
                {opt.label}
              </option>
            ))}
          </select>
        </div>

        <label className="flex items-start gap-3 rounded-xl border border-[var(--border)] p-4">
          <input
            type="checkbox"
            className="mt-1"
            checked={storePrompts && retentionPolicy !== "none"}
            disabled={retentionPolicy === "none"}
            onChange={(e) => setStorePrompts(e.target.checked)}
          />
          <span>
            <span className="font-medium">Store before/after prompt text</span>
            <span className="mt-1 block text-sm text-[var(--text-muted)]">
              When enabled, the portal Usage page shows original vs optimized
              text so you can verify savings. Length is capped by plan (Free:
              2,000 chars/side; Pro: 50,000). Secrets detected by the optimizer
              are masked before storage. Turn off for metadata-only history.
            </span>
          </span>
        </label>

        <button className="btn btn-primary w-fit" disabled={loading}>
          {loading ? "Saving…" : "Save settings"}
        </button>
      </form>

      <section className="card p-6">
        <h2 className="text-lg font-semibold">Security notes</h2>
        <ul className="mt-4 space-y-3 text-sm leading-relaxed text-[var(--text-muted)]">
          <li>
            • Provider API keys are encrypted at rest with AES-256-GCM and a
            server-side master key.
          </li>
          <li>
            • Desktop API keys use a one-way SHA-256 hash. The full{" "}
            <span className="mono">pp_live_</span> secret is only shown once.
          </li>
          <li>
            • Application logs never include plaintext provider keys or full
            prompt bodies by default.
          </li>
          <li>
            • You can delete provider keys and revoke desktop keys at any time.
          </li>
          <li>
            • Plan: <span className="capitalize text-[var(--text)]">{user.plan}</span>
          </li>
        </ul>
      </section>
    </div>
  );
}
