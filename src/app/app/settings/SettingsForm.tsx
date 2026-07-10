"use client";

import { FormEvent, useState } from "react";
import { useRouter } from "next/navigation";
import type { SessionUser } from "@/lib/auth";
import { RETENTION_OPTIONS } from "@/lib/constants";
import { getPlanLimits } from "@/lib/plans";

type ActiveClient = {
  clientId: string;
  hostname: string | null;
  platform: string | null;
  appVersion: string | null;
  lastSeenAt: string | Date;
};

export function SettingsForm({
  user,
  activeClients = [],
}: {
  user: SessionUser;
  activeClients?: ActiveClient[];
}) {
  const router = useRouter();
  const limits = getPlanLimits(user.plan);
  const [name, setName] = useState(user.name || "");
  const [retentionPolicy, setRetentionPolicy] = useState(user.retentionPolicy);
  const [storePrompts, setStorePrompts] = useState(user.storePrompts);
  const [featProjectPc, setFeatProjectPc] = useState(user.featProjectPc !== false);
  const [featProjectSsh, setFeatProjectSsh] = useState(
    user.featProjectSsh !== false
  );
  const [featProjectGit, setFeatProjectGit] = useState(
    user.featProjectGit !== false
  );
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
          featProjectPc,
          featProjectSsh,
          featProjectGit,
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

      <div className="grid gap-6">
        <form onSubmit={onSubmit} className="card grid gap-4 p-6">
          <h2 className="text-lg font-semibold">Desktop project connections</h2>
          <p className="text-sm text-[var(--text-muted)]">
            Lock down what the local PromptParle client can use. Changes apply
            on the next desktop heartbeat (~1 min) or UI refresh.
          </p>

          <label className="flex items-start gap-3 rounded-xl border border-[var(--border)] p-4">
            <input
              type="checkbox"
              className="mt-1"
              checked={featProjectPc}
              onChange={(e) => setFeatProjectPc(e.target.checked)}
            />
            <span>
              <span className="font-medium">This PC folder</span>
              <span className="mt-1 block text-sm text-[var(--text-muted)]">
                Browse and attach a local project folder on the desktop client.
              </span>
            </span>
          </label>

          <label className="flex items-start gap-3 rounded-xl border border-[var(--border)] p-4">
            <input
              type="checkbox"
              className="mt-1"
              checked={featProjectSsh}
              onChange={(e) => setFeatProjectSsh(e.target.checked)}
            />
            <span>
              <span className="font-medium">SSH</span>
              <span className="mt-1 block text-sm text-[var(--text-muted)]">
                Connect to remote hosts (keys stay on the PC). Optional remote
                working directory.
              </span>
            </span>
          </label>

          <label className="flex items-start gap-3 rounded-xl border border-[var(--border)] p-4">
            <input
              type="checkbox"
              className="mt-1"
              checked={featProjectGit}
              onChange={(e) => setFeatProjectGit(e.target.checked)}
            />
            <span>
              <span className="font-medium">Git / GitHub</span>
              <span className="mt-1 block text-sm text-[var(--text-muted)]">
                Clone repos and treat a local git folder as the project working
                directory.
              </span>
            </span>
          </label>

          <button className="btn btn-primary w-fit" disabled={loading}>
            {loading ? "Saving…" : "Save desktop settings"}
          </button>
        </form>

        <section className="card p-6">
          <h2 className="text-lg font-semibold">Desktop client seats</h2>
          <p className="mt-2 text-sm text-[var(--text-muted)]">
            Plan{" "}
            <span className="capitalize text-[var(--text)]">{user.plan}</span>
            : up to{" "}
            <strong className="text-[var(--text)]">
              {limits.maxDesktopClients}
            </strong>{" "}
            active desktop client
            {limits.maxDesktopClients === 1 ? "" : "s"} at once
            {limits.id === "free" ? " (Free GTM)" : ""}. A seat frees ~2 minutes
            after the last heartbeat.
          </p>
          <ul className="mt-4 space-y-2 text-sm">
            {activeClients.length === 0 && (
              <li className="text-[var(--text-muted)]">
                No active desktop clients right now.
              </li>
            )}
            {activeClients.map((c) => (
              <li
                key={c.clientId}
                className="rounded-lg border border-[var(--border)] px-3 py-2"
              >
                <span className="font-medium text-[var(--text)]">
                  {c.hostname || "Desktop"}
                </span>
                <span className="text-[var(--text-muted)]">
                  {" "}
                  · {c.platform || "?"}
                  {c.appVersion ? ` · v${c.appVersion}` : ""}
                </span>
                <div className="mt-0.5 font-mono text-xs text-[var(--text-muted)]">
                  {c.clientId.slice(0, 12)}…
                </div>
              </li>
            ))}
          </ul>
        </section>

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
              • SSH and git credentials never leave the desktop — only optimized
              prompt text is sent to the portal.
            </li>
            <li>
              • You can delete provider keys and revoke desktop keys at any time.
            </li>
          </ul>
        </section>
      </div>
    </div>
  );
}
